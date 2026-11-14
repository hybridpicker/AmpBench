// The host clock's ticks per second. macOS has it in CoreAudio; iOS and iPadOS have no such header, so it comes
// from the Mach timebase there. Both count the same clock the audio time stamps use.
#ifndef SPARK_HOSTTIME_H
#define SPARK_HOSTTIME_H

#include <TargetConditionals.h>
#include <stdint.h>

#if TARGET_OS_OSX
#include <CoreAudio/HostTime.h>
static inline double spark_host_clock_frequency(void) {
    return (double)AudioGetHostClockFrequency();
}
#else
#include <mach/mach_time.h>
static inline double spark_host_clock_frequency(void) {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    return 1e9 * (double)info.denom / (double)info.numer;
}
#endif

#endif
