#ifndef CEIKONSESSION_H
#define CEIKONSESSION_H

#include <stdbool.h>
#include <stdint.h>

/* System zlib, for Swift: detection inflates XP3 indexes; tests build zlib fixtures. */
#include <zlib.h>

/* ---- Render gate (in-flight guard) ------------------------------------------------------
   A render thread calls enter before encoding a frame and leave after committing it. The
   host closes the gate, then waits for in_flight to reach 0. enter increments before it
   reads the closed flag, so a frame that is entering is never missed. */

typedef struct eikon_render_gate eikon_render_gate; /* opaque; defined in the .c */

eikon_render_gate *eikon_render_gate_create(void);     /* starts open, in-flight 0; NULL on OOM */
void eikon_render_gate_destroy(eikon_render_gate *gate);
bool eikon_render_gate_enter(eikon_render_gate *gate); /* false when closed; frame is skipped */
void eikon_render_gate_leave(eikon_render_gate *gate);
void eikon_render_gate_set_closed(eikon_render_gate *gate, bool closed);
int32_t eikon_render_gate_in_flight(const eikon_render_gate *gate);

/* ---- Breadcrumb slot writer --------------------------------------------------------------
   A ring of EIKON_BREADCRUMB_SLOTS fixed slots. Event seq goes to slot seq % SLOTS.
   Slot layout, all little-endian:
     0   uint64 seq
     8   int64  time
     16  int64  a
     24  int64  b
     32  uint16 event
     34  6 bytes, zero
     40  uint64 check: FNV-1a 64 over bytes 0..<40
   A slot whose check does not match is torn or empty and must be ignored. */

#define EIKON_BREADCRUMB_SLOTS 64
/* Size in bytes of one fixed slot; the Swift reader uses the same constant. */
#define EIKON_BREADCRUMB_SLOT_SIZE 48

/* One pwrite of a full slot at offset (seq % EIKON_BREADCRUMB_SLOTS) * SLOT_SIZE.
   Async-signal-safe. No fsync. Returns 0 or errno. */
int eikon_breadcrumb_write(int fd, uint64_t seq, int64_t time,
                           uint16_t event, int64_t a, int64_t b);

/* ---- Fault hook ---------------------------------------------------------------------------
   Nothing here installs a signal handler. FEX and Wine use SIGSEGV/SIGBUS in normal operation.
   The hook is for later runtimes to call from their own fault paths, only for faults they
   really cannot handle.

   File layout, all little-endian:
     header  0  4 bytes magic "EKFT"
             4  uint32 layout version (EIKON_FAULT_VERSION)
             8  16 bytes session id
     then zero or more records of EIKON_FAULT_RECORD_SIZE bytes:
             0  int32  signal
             4  4 bytes, zero
             8  uint64 pc
             16 uint64 address
   A trailing remainder shorter than a record is a torn write; readers ignore it.

   open and close must run only while no runtime can call record: a closed fd number may be
   reused by an unrelated open. open truncates, so read the previous session's file first. */

#define EIKON_FAULT_MAGIC "EKFT"
#define EIKON_FAULT_VERSION 1
#define EIKON_FAULT_HEADER_SIZE 24
#define EIKON_FAULT_RECORD_SIZE 24

/* Opens (creates/truncates) the fault file ahead of time and writes a header
   carrying the 16-byte session id. Keeps the fd in a static. Returns 0 or errno. */
int eikon_session_fault_open(const char *path, const uint8_t session_id[16]);

/* One write(2) of a fixed-size record {signal, pc, address}. Async-signal-safe.
   No-op when no file is open. */
void eikon_session_fault_record(int signal, uintptr_t pc, uintptr_t address);

/* Closes the fd, if open. Called when a session ends. */
void eikon_session_fault_close(void);

#endif /* CEIKONSESSION_H */
