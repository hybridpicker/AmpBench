#include "SparkRT.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct SparkTap {
    float *buffer;
    uint32_t capacity;
    uint32_t mask;
    /// Frames written and read so far. Each index has one writer: the audio thread writes `head`, the reader `tail`.
    _Atomic uint64_t head;
    _Atomic uint64_t tail;
    _Atomic uint64_t overruns;
    _Atomic uint64_t sample_rate_bits;
    _Atomic uint32_t epoch;
};

static uint32_t next_power_of_two(uint32_t value) {
    uint32_t power = 1;
    while (power < value && power < (1u << 30)) power <<= 1;
    return power;
}

SparkTap *spark_tap_create(uint32_t capacity_frames) {
    SparkTap *tap = calloc(1, sizeof(SparkTap));
    tap->capacity = next_power_of_two(capacity_frames < 1024 ? 1024 : capacity_frames);
    tap->mask = tap->capacity - 1;
    size_t bytes = (size_t)tap->capacity * sizeof(float);
    tap->buffer = malloc(bytes);
    // Writing every page makes it resident, so the audio thread never faults one in.
    memset(tap->buffer, 0, bytes);
    return tap;
}

void spark_tap_destroy(SparkTap *tap) {
    size_t bytes = (size_t)tap->capacity * sizeof(float);
    // Nothing heard stays readable in freed memory.
    memset_s(tap->buffer, bytes, 0, bytes);
    free(tap->buffer);
    free(tap);
}

uint32_t spark_tap_capacity(const SparkTap *tap) {
    return tap->capacity;
}

void spark_tap_begin(SparkTap *tap, double sample_rate) {
    uint64_t bits;
    memcpy(&bits, &sample_rate, sizeof(bits));
    atomic_store_explicit(&tap->sample_rate_bits, bits, memory_order_relaxed);
    atomic_fetch_add_explicit(&tap->epoch, 1, memory_order_release);
}

double spark_tap_sample_rate(const SparkTap *tap) {
    uint64_t bits = atomic_load_explicit(&tap->sample_rate_bits, memory_order_relaxed);
    double rate;
    memcpy(&rate, &bits, sizeof(rate));
    return rate;
}

uint32_t spark_tap_epoch(const SparkTap *tap) {
    return atomic_load_explicit(&tap->epoch, memory_order_acquire);
}

void spark_tap_write(SparkTap *tap, const float *interleaved, uint32_t frames, uint32_t channels) {
    if (channels == 0 || frames == 0) return;
    uint64_t head = atomic_load_explicit(&tap->head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&tap->tail, memory_order_acquire);
    uint64_t free_frames = tap->capacity - (head - tail);
    uint32_t count = frames;
    if (count > free_frames) {
        // The reader fell behind. The newest frames are dropped rather than waiting or overwriting what it reads.
        atomic_fetch_add_explicit(&tap->overruns, count - free_frames, memory_order_relaxed);
        count = (uint32_t)free_frames;
    }
    float scale = 1.0f / (float)channels;
    for (uint32_t frame = 0; frame < count; frame++) {
        float sum = 0;
        for (uint32_t channel = 0; channel < channels; channel++) sum += interleaved[frame * channels + channel];
        tap->buffer[(head + frame) & tap->mask] = sum * scale;
    }
    atomic_store_explicit(&tap->head, head + count, memory_order_release);
}

uint32_t spark_tap_read(SparkTap *tap, float *destination, uint32_t max_frames) {
    uint64_t tail = atomic_load_explicit(&tap->tail, memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&tap->head, memory_order_acquire);
    uint64_t available = head - tail;
    uint32_t count = available < max_frames ? (uint32_t)available : max_frames;
    for (uint32_t index = 0; index < count; index++) destination[index] = tap->buffer[(tail + index) & tap->mask];
    atomic_store_explicit(&tap->tail, tail + count, memory_order_release);
    return count;
}

void spark_tap_skip(SparkTap *tap) {
    atomic_store_explicit(&tap->tail, atomic_load_explicit(&tap->head, memory_order_acquire), memory_order_release);
}

uint64_t spark_tap_overruns(const SparkTap *tap) {
    return atomic_load_explicit(&tap->overruns, memory_order_relaxed);
}
