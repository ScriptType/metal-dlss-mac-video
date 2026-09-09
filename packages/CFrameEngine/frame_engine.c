#include "frame_engine.h"
#include <libproc.h>
#include <unistd.h>

uint64_t fe_process_resident_bytes(void) {
    struct proc_taskinfo info;
    int size = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, sizeof(info));
    return size == (int)sizeof(info) ? info.pti_resident_size : 0;
}
// The exported functions are implemented in Swift's FrameEngineShared library.
