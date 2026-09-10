// Types only. The provisional mpv backend is loaded explicitly at runtime;
// importing this module does not link a second FrameEngine/MLX runtime.
#include "../../vendor/mpv/include/mpv/client.h"
#include "../../vendor/mpv/include/mpv/hdr_frame.h"
#include <IOKit/IOMessage.h>

// Swift cannot import the function-like iokit_common_msg macros. Keep these
// observer constants tied to the active SDK rather than duplicating ABI values.
static inline uint32_t hdr_player_power_can_sleep(void) { return kIOMessageCanSystemSleep; }
static inline uint32_t hdr_player_power_will_sleep(void) { return kIOMessageSystemWillSleep; }
static inline uint32_t hdr_player_power_will_not_sleep(void) { return kIOMessageSystemWillNotSleep; }
static inline uint32_t hdr_player_power_has_powered_on(void) { return kIOMessageSystemHasPoweredOn; }
