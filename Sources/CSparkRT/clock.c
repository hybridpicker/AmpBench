#include "SparkRT.h"

#include "hosttime.h"
#include <stdatomic.h>
#include <stdlib.h>

// One writer (the input callback) and any number of readers on other audio threads. A sequence lock lets readers
// see a consistent pair without ever blocking the writer.
struct SparkClock {
    double sample_rate;
    double ticks_per_frame;
    _Atomic uint64_t sequence;
    _Atomic int64_t frame;
    _Atomic uint64_t host_time;
};

SparkClock *spark_clock_create(double sample_rate) {
    SparkClock *clock = calloc(1, sizeof(SparkClock));
    clock->sample_rate = sample_rate;
    clock->ticks_per_frame = spark_host_clock_frequency() / sample_rate;
    return clock;
}

void spark_clock_destroy(SparkClock *clock) {
    free(clock);
}

double spark_clock_sample_rate(const SparkClock *clock) {
    return clock->sample_rate;
}

void spark_clock_publish(SparkClock *clock, int64_t frame, uint64_t host_time) {
    if (host_time == 0) return;
    uint64_t sequence = atomic_load_explicit(&clock->sequence, memory_order_relaxed);
    atomic_store_explicit(&clock->sequence, sequence + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&clock->frame, frame, memory_order_relaxed);
    atomic_store_explicit(&clock->host_time, host_time, memory_order_relaxed);
    atomic_store_explicit(&clock->sequence, sequence + 2, memory_order_release);
}

/// The latest published pair. Gives up after a few tries rather than spin on the audio thread; the writer holds the
/// lock for two stores, so that only happens when the threads are being preempted at exactly that moment.
static bool latest(const SparkClock *clock, int64_t *frame, uint64_t *host_time) {
    for (int attempt = 0; attempt < 8; attempt++) {
        uint64_t before = atomic_load_explicit(&clock->sequence, memory_order_acquire);
        if (before == 0) return false;
        if (before & 1) continue;
        int64_t f = atomic_load_explicit(&clock->frame, memory_order_relaxed);
        uint64_t h = atomic_load_explicit(&clock->host_time, memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&clock->sequence, memory_order_relaxed) == before) {
            *frame = f;
            *host_time = h;
            return true;
        }
    }
    return false;
}

bool spark_clock_host_time_of_frame(const SparkClock *clock, double frame, double *host_time) {
    int64_t reference_frame;
    uint64_t reference_host;
    if (!latest(clock, &reference_frame, &reference_host)) return false;
    // Extrapolation reaches only a few tens of milliseconds past the latest block, so the nominal rate is enough:
    // even a clock 1000 ppm off moves a beat by less than 40 microseconds.
    *host_time = (double)reference_host + (frame - (double)reference_frame) * clock->ticks_per_frame;
    return true;
}

bool spark_clock_frame_at_host_time(const SparkClock *clock, double host_time, double *frame) {
    int64_t reference_frame;
    uint64_t reference_host;
    if (!latest(clock, &reference_frame, &reference_host)) return false;
    *frame = (double)reference_frame + (host_time - (double)reference_host) / clock->ticks_per_frame;
    return true;
}
