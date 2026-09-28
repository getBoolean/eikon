#ifndef CEIKONJIT_H
#define CEIKONJIT_H

#include <stdint.h>

/* CS_DEBUGGED in the code-signing flags from csops(CS_OPS_STATUS). */
#define EIKON_CS_DEBUGGED 0x10000000u

/* 0 and *flags from csops(getpid(), CS_OPS_STATUS, …); errno otherwise. */
int eikon_cs_flags(uint32_t *flags);

typedef enum {
    EIKON_PROBE_PASSED = 0,
    EIKON_PROBE_ALLOC_FAILED,        /* RW allocation failed */
    EIKON_PROBE_REMAP_FAILED,        /* vm_remap alias failed */
    EIKON_PROBE_PROTECT_FAILED,      /* mprotect(RX) on the execute view failed */
    EIKON_PROBE_PROTECTION_MISMATCH, /* remap cur/max protections cannot give RX + RW */
    EIKON_PROBE_WRONG_RESULT,        /* code ran but did not return 42 */
    EIKON_PROBE_SIGNAL               /* guarded signal while executing */
} eikon_probe_status;

typedef struct {
    eikon_probe_status status;
    int signal;
    int error;
} eikon_probe_result;

/* MUST only be called when JITPolicy.mayProbe is true. */
eikon_probe_result eikon_jit_probe(void);

#endif /* CEIKONJIT_H */
