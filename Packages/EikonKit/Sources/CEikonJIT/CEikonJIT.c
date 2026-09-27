#include "CEikonJIT.h"

#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <mach/mach.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <libkern/OSCacheControl.h>

#if defined(__arm64__)
#include <mach/arm/thread_status.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif
#endif

/* Private libsystem call. There is no public header for it. */
#define CS_OPS_STATUS 0
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

static const int kProbeSignals[] = {SIGBUS, SIGSEGV, SIGILL, SIGTRAP};
static const int kProbeSignalCount = (int)(sizeof kProbeSignals / sizeof kProbeSignals[0]);

static pthread_mutex_t probe_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_t probe_owner;
static sigjmp_buf probe_jmp;
static volatile sig_atomic_t probe_armed;
static volatile sig_atomic_t probe_caught;
static vm_address_t probe_rw_base;
static vm_address_t probe_rx_base;
static size_t probe_length;
static struct sigaction probe_previous[sizeof kProbeSignals / sizeof kProbeSignals[0]];

static eikon_probe_result make_probe_result(eikon_probe_status status, int signal_number, int error) {
    eikon_probe_result result;
    result.status = status;
    result.signal = signal_number;
    result.error = error;
    return result;
}

static int probe_address_in_view(uintptr_t address, vm_address_t base, size_t length) {
    uintptr_t start = (uintptr_t)base;
    if (base == 0 || length == 0 || address == 0 || address < start) return 0;
    return (address - start) < length;
}

#if defined(__arm64__)
static uintptr_t probe_program_counter(void *context) {
    ucontext_t *context_record = context;
    if (context_record == NULL || context_record->uc_mcontext == NULL) return 0;
    /* Don't authenticate: a failed auth traps, and this runs inside the handler. */
#if __DARWIN_OPAQUE_ARM_THREAD_STATE64
    void *counter = context_record->uc_mcontext->__ss.__opaque_pc;
#if __has_feature(ptrauth_calls)
    counter = ptrauth_strip(counter, ptrauth_key_process_independent_code);
#endif
    return (uintptr_t)counter;
#else
    return (uintptr_t)context_record->uc_mcontext->__ss.__pc;
#endif
}
#endif

static void probe_chain_or_reraise(int signo, siginfo_t *info, void *context) {
    int index = -1;
    for (int i = 0; i < kProbeSignalCount; i++) {
        if (kProbeSignals[i] == signo) index = i;
    }
    if (index < 0) return;

    struct sigaction previous = probe_previous[index];
    if ((previous.sa_flags & SA_SIGINFO) && previous.sa_sigaction != NULL) {
        previous.sa_sigaction(signo, info, context);
        return;
    }
    if (previous.sa_handler != SIG_DFL && previous.sa_handler != SIG_IGN) {
        previous.sa_handler(signo);
        return;
    }
    if (previous.sa_handler == SIG_IGN) return;

    struct sigaction default_action;
    memset(&default_action, 0, sizeof default_action);
    default_action.sa_handler = SIG_DFL;
    sigaction(signo, &default_action, NULL);
    sigset_t blocked;
    sigemptyset(&blocked);
    sigaddset(&blocked, signo);
    sigprocmask(SIG_UNBLOCK, &blocked, NULL);
    raise(signo);
}

static void probe_signal_handler(int signo, siginfo_t *info, void *context) {
    int on_probe_thread = probe_armed && pthread_equal(pthread_self(), probe_owner);
    uintptr_t fault = (info != NULL) ? (uintptr_t)info->si_addr : 0;
#if defined(__arm64__)
    uintptr_t counter = probe_program_counter(context);
#else
    uintptr_t counter = 0;
    (void)context;
#endif
    int in_probe = probe_address_in_view(fault, probe_rw_base, probe_length) ||
                   probe_address_in_view(fault, probe_rx_base, probe_length) ||
                   probe_address_in_view(counter, probe_rw_base, probe_length) ||
                   probe_address_in_view(counter, probe_rx_base, probe_length);
    if (on_probe_thread && in_probe) {
        probe_caught = signo;
        siglongjmp(probe_jmp, 1);
    }
    probe_chain_or_reraise(signo, info, context);
}

/* Rolls back a partial install. errno from the failing sigaction is preserved. */
static int install_probe_handlers(void) {
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_sigaction = probe_signal_handler;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);

    for (int i = 0; i < kProbeSignalCount; i++) {
        if (sigaction(kProbeSignals[i], &action, &probe_previous[i]) != 0) {
            int saved = errno;
            for (int j = 0; j < i; j++) sigaction(kProbeSignals[j], &probe_previous[j], NULL);
            errno = saved;
            return -1;
        }
    }
    return 0;
}

static void restore_probe_handlers(void) {
    for (int i = 0; i < kProbeSignalCount; i++) {
        sigaction(kProbeSignals[i], &probe_previous[i], NULL);
    }
}

int eikon_cs_flags(uint32_t *flags) {
    if (flags == NULL) return EINVAL;
    if (csops(getpid(), CS_OPS_STATUS, flags, sizeof *flags) != 0) return errno;
    return 0;
}

eikon_probe_result eikon_jit_probe(void) {
    pthread_mutex_lock(&probe_lock);

    eikon_probe_result result = make_probe_result(EIKON_PROBE_ALLOC_FAILED, 0, 0);
    vm_address_t rw = 0;
    vm_address_t rx = 0;
    int have_rw = 0;
    int have_rx = 0;
    int have_handlers = 0;
    vm_size_t page = (vm_size_t)getpagesize();
    if (page == 0) {
        result.error = EINVAL;
        goto cleanup;
    }

    /* RW only. MAP_JIT is never used: this is the dual-mapping path. */
    kern_return_t kr = vm_allocate(mach_task_self(), &rw, page, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        result = make_probe_result(EIKON_PROBE_ALLOC_FAILED, 0, (int)kr);
        goto cleanup;
    }
    have_rw = 1;

    vm_prot_t current = VM_PROT_NONE;
    vm_prot_t maximum = VM_PROT_NONE;
    kr = vm_remap(mach_task_self(), &rx, page, 0, VM_FLAGS_ANYWHERE, mach_task_self(), rw, FALSE, &current,
                  &maximum, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        result = make_probe_result(EIKON_PROBE_REMAP_FAILED, 0, (int)kr);
        goto cleanup;
    }
    have_rx = 1;

    vm_prot_t need_rx = VM_PROT_READ | VM_PROT_EXECUTE;
    vm_prot_t need_rw = VM_PROT_READ | VM_PROT_WRITE;
    if ((maximum & need_rx) != need_rx || (maximum & need_rw) != need_rw) {
        result = make_probe_result(EIKON_PROBE_PROTECTION_MISMATCH, 0, (int)maximum);
        goto cleanup;
    }

    /* The execute view becomes RX. The write view stays RW. Neither is RWX. */
    if (mprotect((void *)rx, (size_t)page, PROT_READ | PROT_EXEC) != 0) {
        result = make_probe_result(EIKON_PROBE_PROTECT_FAILED, 0, errno);
        goto cleanup;
    }

    /* mov w0, #42 ; ret */
    static const uint32_t kReturn42[] = {0x52800540u, 0xD65F03C0u};
    memcpy((void *)rw, kReturn42, sizeof kReturn42);
    sys_icache_invalidate((void *)rw, sizeof kReturn42);
    sys_icache_invalidate((void *)rx, sizeof kReturn42);

#if !defined(__arm64__)
    result = make_probe_result(EIKON_PROBE_WRONG_RESULT, 0, ENOTSUP);
    goto cleanup;
#else
    probe_owner = pthread_self();
    probe_rw_base = rw;
    probe_rx_base = rx;
    probe_length = (size_t)page;
    probe_caught = 0;
    probe_armed = 0;

    if (install_probe_handlers() != 0) {
        result = make_probe_result(EIKON_PROBE_SIGNAL, 0, errno);
        goto cleanup;
    }
    have_handlers = 1;

    /*
     Handlers are installed before sigsetjmp, but they only jump once probe_armed is set.
     have_handlers is set before sigsetjmp so a longjmp still restores them.
     */
    if (sigsetjmp(probe_jmp, 1) == 0) {
        probe_armed = 1;
        uint32_t (*function)(void) = (void *)rx;
#if __has_feature(ptrauth_calls)
        function = ptrauth_sign_unauthenticated(function, ptrauth_key_function_pointer, 0);
#endif
        uint32_t value = function();
        probe_armed = 0;
        if (value == 42) {
            result = make_probe_result(EIKON_PROBE_PASSED, 0, 0);
        } else {
            result = make_probe_result(EIKON_PROBE_WRONG_RESULT, 0, (int)value);
        }
    } else {
        probe_armed = 0;
        result = make_probe_result(EIKON_PROBE_SIGNAL, (int)probe_caught, 0);
    }
#endif

cleanup:
    probe_armed = 0;
    if (have_handlers) restore_probe_handlers();
    if (have_rx) vm_deallocate(mach_task_self(), rx, page);
    if (have_rw) vm_deallocate(mach_task_self(), rw, page);
    probe_rw_base = 0;
    probe_rx_base = 0;
    probe_length = 0;
    pthread_mutex_unlock(&probe_lock);
    return result;
}

int eikon_txm_firmware_present(void) {
    DIR *preboot = opendir("/private/preboot");
    if (preboot == NULL) return -1;

    int found = 0;
    int confirmed_absent = 0;
    struct dirent *entry;
    while ((entry = readdir(preboot)) != NULL) {
        if (entry->d_name[0] == '.') continue;

        char directory[PATH_MAX];
        int length = snprintf(directory, sizeof directory, "/private/preboot/%s/usr/standalone/firmware/FUD",
                              entry->d_name);
        if (length < 0 || (size_t)length >= sizeof directory) continue;

        DIR *firmware = opendir(directory);
        if (firmware == NULL) continue;

        int saw_image = 0;
        struct dirent *child;
        while ((child = readdir(firmware)) != NULL) {
            if (strcmp(child->d_name, "Ap,TrustedExecutionMonitor.img4") == 0) {
                saw_image = 1;
                break;
            }
        }
        closedir(firmware);

        if (saw_image) {
            found = 1;
            break;
        }
        confirmed_absent = 1;
    }
    closedir(preboot);

    if (found) return 1;
    if (confirmed_absent) return 0;
    return -1;
}
