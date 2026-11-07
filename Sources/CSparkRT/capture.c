#include "SparkRT.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define OVERVIEW_CAPACITY_BINS (1u << 18)

struct SparkCapture {
    AudioUnit _Nullable unit;
    uint32_t channels;
    uint32_t capacity_frames;
    float *scratch;
    SparkClock *_Nullable clock;

    _Atomic(ExtAudioFileRef) file;
    _Atomic int64_t gate_frame;
    /// Frames received so far. Written by the audio thread only.
    _Atomic int64_t frames_received;
    atomic_bool busy;

    _Atomic uint32_t level_bits;
    atomic_bool clip_flag;
    _Atomic uint64_t callback_count;
    _Atomic OSStatus render_status;

    _Atomic uint32_t file_peak_bits;
    _Atomic int64_t file_frames;
    _Atomic int64_t file_first_frame;
    _Atomic int64_t dropped_frames;
    _Atomic OSStatus write_status;
    _Atomic uint32_t clipped_blocks;

    float *retro;
    uint64_t retro_capacity;
    uint64_t retro_margin;
    _Atomic uint64_t retro_written;

    // Waveform overview: one single-producer, single-consumer queue of min/max pairs.
    uint32_t bin_frames;
    uint32_t bin_position;
    float bin_min;
    float bin_max;
    float *overview;
    _Atomic uint32_t overview_head;
    _Atomic uint32_t overview_tail;
    _Atomic uint64_t dropped_bins;
};

static inline uint32_t float_bits(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static inline float bits_float(uint32_t bits) {
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

/// Stores the larger value. A lost race only costs one meter update, so the retries are bounded.
static inline void atomic_store_max(_Atomic uint32_t *target, float value) {
    uint32_t current = atomic_load_explicit(target, memory_order_relaxed);
    for (int attempt = 0; attempt < 4; attempt++) {
        if (value <= bits_float(current)) return;
        if (atomic_compare_exchange_weak_explicit(target, &current, float_bits(value), memory_order_relaxed,
                                                  memory_order_relaxed)) {
            return;
        }
    }
}

SparkCapture *spark_capture_create(uint32_t channels, uint32_t capacity_frames, double sample_rate,
                                   uint64_t retro_frames, uint64_t retro_margin_frames, uint32_t overview_bin_frames,
                                   SparkClock *_Nullable clock) {
    (void)sample_rate;
    SparkCapture *capture = calloc(1, sizeof(SparkCapture));
    capture->channels = channels;
    capture->capacity_frames = capacity_frames;
    capture->scratch = calloc((size_t)capacity_frames * channels, sizeof(float));
    capture->clock = clock;
    atomic_store(&capture->gate_frame, SPARK_GATE_NONE);
    atomic_store(&capture->file_first_frame, -1);
    capture->bin_frames = overview_bin_frames > 0 ? overview_bin_frames : 256;
    capture->bin_min = 1;
    capture->bin_max = -1;
    capture->overview = calloc((size_t)OVERVIEW_CAPACITY_BINS * 2, sizeof(float));

    if (retro_frames > 0) {
        capture->retro_capacity = retro_frames + retro_margin_frames;
        capture->retro_margin = retro_margin_frames;
        size_t bytes = (size_t)capture->retro_capacity * channels * sizeof(float);
        capture->retro = malloc(bytes);
        // Writing every page makes it resident, so the audio thread never faults one in.
        memset(capture->retro, 0, bytes);
    }
    return capture;
}

void spark_capture_destroy(SparkCapture *capture) {
    if (capture->retro) {
        size_t bytes = (size_t)capture->retro_capacity * capture->channels * sizeof(float);
        memset_s(capture->retro, bytes, 0, bytes);
        free(capture->retro);
    }
    free(capture->scratch);
    free(capture->overview);
    free(capture);
}

void spark_capture_set_unit(SparkCapture *capture, AudioUnit unit) {
    capture->unit = unit;
}

static inline void push_bin(SparkCapture *capture) {
    uint32_t head = atomic_load_explicit(&capture->overview_head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&capture->overview_tail, memory_order_acquire);
    uint32_t next = (head + 1) & (OVERVIEW_CAPACITY_BINS - 1);
    if (next == tail) {
        atomic_fetch_add_explicit(&capture->dropped_bins, 1, memory_order_relaxed);
    } else {
        capture->overview[head * 2] = capture->bin_min;
        capture->overview[head * 2 + 1] = capture->bin_max;
        atomic_store_explicit(&capture->overview_head, next, memory_order_release);
    }
    capture->bin_position = 0;
    capture->bin_min = 1;
    capture->bin_max = -1;
}

static inline void write_to_file(SparkCapture *capture, ExtAudioFileRef file, const float *samples, uint32_t frames) {
    uint32_t channels = capture->channels;
    AudioBufferList list;
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = channels;
    list.mBuffers[0].mDataByteSize = frames * channels * (uint32_t)sizeof(float);
    list.mBuffers[0].mData = (void *)samples;

    // ExtAudioFileWriteAsync copies into a queue that a background thread drains.
    OSStatus status = ExtAudioFileWriteAsync(file, frames, &list);
    if (status != noErr) {
        atomic_store_explicit(&capture->write_status, status, memory_order_relaxed);
        atomic_fetch_add_explicit(&capture->dropped_frames, frames, memory_order_relaxed);
        return;
    }

    float peak = 0;
    for (uint32_t frame = 0; frame < frames; frame++) {
        for (uint32_t channel = 0; channel < channels; channel++) {
            float sample = samples[frame * channels + channel];
            float magnitude = fabsf(sample);
            if (magnitude > peak) peak = magnitude;
            if (sample < capture->bin_min) capture->bin_min = sample;
            if (sample > capture->bin_max) capture->bin_max = sample;
        }
        capture->bin_position++;
        if (capture->bin_position >= capture->bin_frames) push_bin(capture);
    }
    atomic_store_max(&capture->file_peak_bits, peak);
    if (peak >= SPARK_CLIP_THRESHOLD) {
        atomic_fetch_add_explicit(&capture->clipped_blocks, 1, memory_order_relaxed);
    }
    atomic_fetch_add_explicit(&capture->file_frames, frames, memory_order_relaxed);
}

void spark_capture_process(SparkCapture *capture, const float *interleaved, uint32_t frames, uint64_t host_time) {
    uint32_t channels = capture->channels;
    atomic_fetch_add_explicit(&capture->callback_count, 1, memory_order_relaxed);
    int64_t block_frame = atomic_load_explicit(&capture->frames_received, memory_order_relaxed);
    // Counted in received frames rather than the device's sample time, because those are what the file holds.
    if (capture->clock) spark_clock_publish(capture->clock, block_frame, host_time);

    float block_peak = 0;
    uint32_t sample_count = frames * channels;
    for (uint32_t index = 0; index < sample_count; index++) {
        float magnitude = fabsf(interleaved[index]);
        if (magnitude > block_peak) block_peak = magnitude;
    }
    atomic_store_max(&capture->level_bits, block_peak);
    if (block_peak >= SPARK_CLIP_THRESHOLD) {
        atomic_store_explicit(&capture->clip_flag, true, memory_order_relaxed);
    }

    if (capture->retro) {
        uint64_t written = atomic_load_explicit(&capture->retro_written, memory_order_relaxed);
        uint64_t position = written % capture->retro_capacity;
        uint64_t first = capture->retro_capacity - position;
        if (first > frames) first = frames;
        memcpy(capture->retro + position * channels, interleaved, (size_t)first * channels * sizeof(float));
        if (first < frames) {
            memcpy(capture->retro, interleaved + first * channels, (size_t)(frames - first) * channels * sizeof(float));
        }
        atomic_store_explicit(&capture->retro_written, written + frames, memory_order_release);
    }

    // Sequentially consistent, so the detaching thread cannot miss a callback that is about to use the file.
    atomic_store(&capture->busy, true);
    ExtAudioFileRef file = atomic_load(&capture->file);
    if (file) {
        uint32_t offset = 0;
        bool write = true;
        int64_t gate = atomic_load_explicit(&capture->gate_frame, memory_order_acquire);
        if (gate != SPARK_GATE_NONE) {
            if (gate >= block_frame + (int64_t)frames) {
                write = false;
            } else if (gate > block_frame) {
                offset = (uint32_t)(gate - block_frame);
            }
            if (write) atomic_store_explicit(&capture->gate_frame, SPARK_GATE_NONE, memory_order_release);
        }
        if (write) {
            if (atomic_load_explicit(&capture->file_first_frame, memory_order_relaxed) < 0) {
                atomic_store_explicit(&capture->file_first_frame, block_frame + offset, memory_order_release);
            }
            write_to_file(capture, file, interleaved + offset * channels, frames - offset);
        }
    }
    atomic_store(&capture->busy, false);
    atomic_store_explicit(&capture->frames_received, block_frame + frames, memory_order_release);
}

static OSStatus input_callback(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time_stamp,
                               UInt32 bus, UInt32 frames, AudioBufferList *_Nullable unused) {
    (void)unused;
    SparkCapture *capture = ref;
    if (frames > capture->capacity_frames) {
        atomic_fetch_add_explicit(&capture->dropped_frames, frames, memory_order_relaxed);
        return kAudioUnitErr_TooManyFramesToProcess;
    }
    AudioBufferList list;
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = capture->channels;
    list.mBuffers[0].mDataByteSize = frames * capture->channels * (uint32_t)sizeof(float);
    list.mBuffers[0].mData = capture->scratch;

    OSStatus status = AudioUnitRender(capture->unit, flags, time_stamp, bus, frames, &list);
    if (status != noErr) {
        atomic_store_explicit(&capture->render_status, status, memory_order_relaxed);
        return status;
    }
    uint64_t host = (time_stamp->mFlags & kAudioTimeStampHostTimeValid) ? time_stamp->mHostTime : 0;
    spark_capture_process(capture, capture->scratch, frames, host);
    return noErr;
}

const AURenderCallback spark_capture_input_callback = input_callback;

void spark_capture_attach_file(SparkCapture *capture, ExtAudioFileRef file, int64_t gate_frame) {
    // No file is attached here, so the audio thread does not touch any of the file state.
    atomic_store(&capture->file_peak_bits, 0);
    atomic_store(&capture->file_frames, 0);
    atomic_store(&capture->file_first_frame, -1);
    atomic_store(&capture->dropped_frames, 0);
    atomic_store(&capture->write_status, noErr);
    atomic_store(&capture->clipped_blocks, 0);
    atomic_store(&capture->dropped_bins, 0);
    capture->bin_position = 0;
    capture->bin_min = 1;
    capture->bin_max = -1;
    atomic_store(&capture->overview_tail, atomic_load(&capture->overview_head));
    atomic_store(&capture->gate_frame, gate_frame < 0 ? SPARK_GATE_NONE : gate_frame);
    atomic_store(&capture->file, file);
}

bool spark_capture_detach_file(SparkCapture *capture) {
    atomic_store(&capture->file, NULL);
    for (int attempt = 0; attempt < 4000; attempt++) {
        if (!atomic_load(&capture->busy)) {
            if (capture->bin_position > 0) push_bin(capture);
            return true;
        }
        usleep(250);
    }
    return false;
}

float spark_capture_take_level(SparkCapture *capture) {
    return bits_float(atomic_exchange_explicit(&capture->level_bits, 0, memory_order_relaxed));
}

bool spark_capture_take_clip(SparkCapture *capture) {
    return atomic_exchange_explicit(&capture->clip_flag, false, memory_order_relaxed);
}

uint64_t spark_capture_callback_count(const SparkCapture *capture) {
    return atomic_load_explicit(&capture->callback_count, memory_order_relaxed);
}

OSStatus spark_capture_render_status(const SparkCapture *capture) {
    return atomic_load_explicit(&capture->render_status, memory_order_relaxed);
}

float spark_capture_file_peak(const SparkCapture *capture) {
    return bits_float(atomic_load_explicit(&capture->file_peak_bits, memory_order_relaxed));
}

int64_t spark_capture_file_frames(const SparkCapture *capture) {
    return atomic_load_explicit(&capture->file_frames, memory_order_relaxed);
}

int64_t spark_capture_dropped_frames(const SparkCapture *capture) {
    return atomic_load_explicit(&capture->dropped_frames, memory_order_relaxed);
}

int64_t spark_capture_file_first_frame(const SparkCapture *capture) {
    return atomic_load_explicit(&capture->file_first_frame, memory_order_acquire);
}

int64_t spark_capture_frames_received(const SparkCapture *capture) {
    return atomic_load_explicit(&capture->frames_received, memory_order_acquire);
}

OSStatus spark_capture_write_status(const SparkCapture *capture) {
    return atomic_load_explicit(&capture->write_status, memory_order_relaxed);
}

uint32_t spark_capture_clipped_blocks(const SparkCapture *capture) {
    return atomic_load_explicit(&capture->clipped_blocks, memory_order_relaxed);
}

uint64_t spark_capture_dropped_bins(const SparkCapture *capture) {
    return atomic_load_explicit(&capture->dropped_bins, memory_order_relaxed);
}

uint32_t spark_capture_read_overview(SparkCapture *capture, float *min_max_pairs, uint32_t max_bins) {
    uint32_t tail = atomic_load_explicit(&capture->overview_tail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&capture->overview_head, memory_order_acquire);
    uint32_t count = 0;
    while (tail != head && count < max_bins) {
        min_max_pairs[count * 2] = capture->overview[tail * 2];
        min_max_pairs[count * 2 + 1] = capture->overview[tail * 2 + 1];
        tail = (tail + 1) & (OVERVIEW_CAPACITY_BINS - 1);
        count++;
    }
    atomic_store_explicit(&capture->overview_tail, tail, memory_order_release);
    return count;
}

uint64_t spark_capture_retro_available_frames(const SparkCapture *capture) {
    if (!capture->retro) return 0;
    uint64_t written = atomic_load_explicit(&capture->retro_written, memory_order_acquire);
    uint64_t usable = capture->retro_capacity - capture->retro_margin;
    return written < usable ? written : usable;
}

uint64_t spark_capture_retro_copy_latest(const SparkCapture *capture, float *destination, uint64_t frames) {
    if (!capture->retro) return 0;
    uint64_t written = atomic_load_explicit(&capture->retro_written, memory_order_acquire);
    uint64_t usable = capture->retro_capacity - capture->retro_margin;
    uint64_t available = written < usable ? written : usable;
    uint64_t count = frames < available ? frames : available;
    uint32_t channels = capture->channels;
    // The margin keeps the writer away from this region while it is copied.
    uint64_t position = (written - count) % capture->retro_capacity;
    uint64_t first = capture->retro_capacity - position;
    if (first > count) first = count;
    memcpy(destination, capture->retro + position * channels, (size_t)first * channels * sizeof(float));
    if (first < count) {
        memcpy(destination + first * channels, capture->retro, (size_t)(count - first) * channels * sizeof(float));
    }
    return count;
}
