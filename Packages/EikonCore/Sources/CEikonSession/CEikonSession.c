#include "CEikonSession.h"

#include <errno.h>
#include <sched.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

/* Everything below the render gate may run on a fault path: no malloc, no locks, no stdio. */

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "fault fd and in-flight count must be lock-free");
_Static_assert(ATOMIC_BOOL_LOCK_FREE == 2, "closed flag must be lock-free");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "breadcrumb seq must be lock-free");

/* ---- Render gate ---- */

struct eikon_render_gate {
    _Atomic int32_t in_flight;
    _Atomic bool closed;
};

eikon_render_gate *eikon_render_gate_create(void) {
    eikon_render_gate *gate = malloc(sizeof *gate);
    if (gate == NULL) return NULL;
    atomic_init(&gate->in_flight, 0);
    atomic_init(&gate->closed, false);
    return gate;
}

void eikon_render_gate_destroy(eikon_render_gate *gate) {
    free(gate);
}

bool eikon_render_gate_enter(eikon_render_gate *gate) {
    /* Count first, then look: a closer that saw in_flight == 0 after closing cannot miss us. */
    atomic_fetch_add(&gate->in_flight, 1);
    if (atomic_load(&gate->closed)) {
        atomic_fetch_sub(&gate->in_flight, 1);
        return false;
    }
    return true;
}

void eikon_render_gate_leave(eikon_render_gate *gate) {
    atomic_fetch_sub(&gate->in_flight, 1);
}

void eikon_render_gate_set_closed(eikon_render_gate *gate, bool closed) {
    atomic_store(&gate->closed, closed);
}

int32_t eikon_render_gate_in_flight(const eikon_render_gate *gate) {
    return atomic_load(&gate->in_flight);
}

/* ---- Little-endian encoding ---- */

static void put_le(uint8_t *out, uint64_t value, int bytes) {
    for (int i = 0; i < bytes; i++) out[i] = (uint8_t)(value >> (8 * i));
}

static uint64_t fnv1a64(const uint8_t *bytes, int count) {
    uint64_t hash = 0xcbf29ce484222325ull;
    for (int i = 0; i < count; i++) {
        hash ^= bytes[i];
        hash *= 0x100000001b3ull;
    }
    return hash;
}

/* ---- Breadcrumbs ---- */

int eikon_breadcrumb_write(int fd, uint64_t seq, int64_t time,
                           uint16_t event, int64_t a, int64_t b) {
    int saved_errno = errno;
    uint8_t slot[EIKON_BREADCRUMB_SLOT_SIZE] = {0};
    put_le(slot + 0, seq, 8);
    put_le(slot + 8, (uint64_t)time, 8);
    put_le(slot + 16, (uint64_t)a, 8);
    put_le(slot + 24, (uint64_t)b, 8);
    put_le(slot + 32, event, 2);
    put_le(slot + 40, fnv1a64(slot, 40), 8);

    off_t offset = (off_t)(seq % EIKON_BREADCRUMB_SLOTS) * EIKON_BREADCRUMB_SLOT_SIZE;
    ssize_t written;
    do {
        written = pwrite(fd, slot, sizeof slot, offset);
    } while (written < 0 && errno == EINTR);
    int result = written < 0 ? errno : (written == (ssize_t)sizeof slot ? 0 : EIO);
    errno = saved_errno;
    return result;
}

static _Atomic int breadcrumb_fd = -1;
static _Atomic uint64_t breadcrumb_seq = 0;
static _Atomic int32_t breadcrumb_in_flight = 0;

/* Swaps the fd out, then waits until no writer that loaded the old fd is still using it,
   so its number can't be reused by another open while a write is pending. */
static void retire_fd(_Atomic int *slot, _Atomic int32_t *in_flight) {
    int fd = atomic_exchange(slot, -1);
    if (fd < 0) return;
    while (atomic_load(in_flight) > 0) sched_yield();
    close(fd);
}

int eikon_breadcrumbs_open(const char *path) {
    eikon_breadcrumbs_close();
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return errno;
    if (ftruncate(fd, (off_t)EIKON_BREADCRUMB_SLOTS * EIKON_BREADCRUMB_SLOT_SIZE) != 0) {
        int error = errno;
        close(fd);
        return error;
    }
    atomic_store(&breadcrumb_seq, 0);
    atomic_store(&breadcrumb_fd, fd);
    return 0;
}

void eikon_breadcrumbs_append(uint16_t event, int64_t a, int64_t b) {
    atomic_fetch_add(&breadcrumb_in_flight, 1);
    int fd = atomic_load(&breadcrumb_fd);
    if (fd < 0) {
        atomic_fetch_sub(&breadcrumb_in_flight, 1);
        return;
    }
    int saved_errno = errno;
    struct timespec now;
    int64_t millis = clock_gettime(CLOCK_REALTIME, &now) == 0
        ? (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000 : 0;
    errno = saved_errno;
    uint64_t seq = atomic_fetch_add(&breadcrumb_seq, 1) + 1;
    (void)eikon_breadcrumb_write(fd, seq, millis, event, a, b);
    atomic_fetch_sub(&breadcrumb_in_flight, 1);
}

void eikon_breadcrumbs_close(void) {
    retire_fd(&breadcrumb_fd, &breadcrumb_in_flight);
}

/* ---- Fault hook ---- */

static _Atomic int fault_fd = -1;
static _Atomic int32_t fault_in_flight = 0;

static int write_all(int fd, const uint8_t *bytes, size_t count) {
    while (count > 0) {
        ssize_t written = write(fd, bytes, count);
        if (written < 0) {
            if (errno == EINTR) continue;
            return errno;
        }
        if (written == 0) return EIO;
        bytes += written;
        count -= (size_t)written;
    }
    return 0;
}

int eikon_session_fault_open(const char *path, const uint8_t session_id[16]) {
    eikon_session_fault_close();

    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0) return errno;

    uint8_t header[EIKON_FAULT_HEADER_SIZE];
    for (int i = 0; i < 4; i++) header[i] = (uint8_t)EIKON_FAULT_MAGIC[i];
    put_le(header + 4, EIKON_FAULT_VERSION, 4);
    for (int i = 0; i < 16; i++) header[8 + i] = session_id[i];

    int error = write_all(fd, header, sizeof header);
    if (error != 0) {
        close(fd);
        return error;
    }
    int replaced = atomic_exchange(&fault_fd, fd);
    if (replaced >= 0) close(replaced);
    return 0;
}

void eikon_session_fault_record(int signal, uintptr_t pc, uintptr_t address) {
    atomic_fetch_add(&fault_in_flight, 1);
    int fd = atomic_load(&fault_fd);
    if (fd < 0) {
        atomic_fetch_sub(&fault_in_flight, 1);
        return;
    }

    int saved_errno = errno;
    uint8_t record[EIKON_FAULT_RECORD_SIZE] = {0};
    put_le(record + 0, (uint32_t)signal, 4);
    put_le(record + 8, (uint64_t)pc, 8);
    put_le(record + 16, (uint64_t)address, 8);
    ssize_t written;
    do {
        written = write(fd, record, sizeof record);
    } while (written < 0 && errno == EINTR);
    errno = saved_errno;
    atomic_fetch_sub(&fault_in_flight, 1);
}

void eikon_session_fault_close(void) {
    retire_fd(&fault_fd, &fault_in_flight);
}
