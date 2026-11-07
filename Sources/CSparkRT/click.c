#include "SparkRT.h"

#include <CoreAudio/HostTime.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define CLICK_DECAY_SECONDS 0.012
#define CLICK_END_LEVEL 0.001f
#define ACCENT_FREQUENCY 1760.0
#define BEAT_FREQUENCY 1175.0
/// A beat that should have started this much before the block still sounds, at the block's first frame. Anything
/// later is skipped rather than played off the grid.
#define LATE_TOLERANCE_SECONDS 0.003
#define MAX_TRIGGERS_PER_BLOCK 16

struct SparkClick {
    double sample_rate;
    double ticks_per_frame;
    SparkClock *_Nullable clock;

    _Atomic uint64_t bpm_bits;
    _Atomic uint32_t beats_per_bar;
    _Atomic uint32_t volume_bits;
    _Atomic int64_t mute_from_beat;
    _Atomic uint64_t beat_count;
    _Atomic uint64_t late_beats;
    _Atomic uint64_t anchor_bits;
    atomic_bool anchored;

    // Audio thread only.
    bool started;
    /// Output frames rendered, used without a clock.
    uint64_t frame;
    /// The next beat: an output frame without a clock, an input frame with one.
    double next_beat;
    int64_t sounding_beat;
    float phase;
    float phase_step;
    float envelope;
    float decay;
    float amplitude;
};

static inline uint64_t double_bits(double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static inline double bits_double(uint64_t bits) {
    double value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

SparkClick *spark_click_create(double sample_rate, SparkClock *_Nullable clock) {
    SparkClick *click = calloc(1, sizeof(SparkClick));
    click->sample_rate = sample_rate;
    click->ticks_per_frame = (double)AudioGetHostClockFrequency() / sample_rate;
    click->clock = clock;
    click->decay = (float)exp(-1.0 / (CLICK_DECAY_SECONDS * sample_rate));
    click->sounding_beat = -1;
    atomic_store(&click->mute_from_beat, -1);
    spark_click_set_tempo(click, 120, 4, 0.5f);
    return click;
}

void spark_click_destroy(SparkClick *click) {
    free(click);
}

void spark_click_set_tempo(SparkClick *click, double bpm, uint32_t beats_per_bar, float volume) {
    uint32_t volume_bits;
    memcpy(&volume_bits, &volume, sizeof(volume_bits));
    atomic_store_explicit(&click->bpm_bits, double_bits(bpm > 0 ? bpm : 120), memory_order_relaxed);
    atomic_store_explicit(&click->beats_per_bar, beats_per_bar > 0 ? beats_per_bar : 1, memory_order_relaxed);
    atomic_store_explicit(&click->volume_bits, volume_bits, memory_order_relaxed);
}

void spark_click_set_mute_from_beat(SparkClick *click, int64_t beat) {
    atomic_store_explicit(&click->mute_from_beat, beat, memory_order_relaxed);
}

/// Finds where beats start in this block. Returns how many were found, in order.
static int find_triggers(SparkClick *click, uint32_t frames, uint64_t host_time, double bpm,
                         uint32_t *indices, uint64_t *beats) {
    int count = 0;
    if (!click->clock) {
        double interval = click->sample_rate * 60.0 / bpm;
        double end = (double)(click->frame + frames);
        while (count < MAX_TRIGGERS_PER_BLOCK && click->next_beat < end) {
            // The first frame at or after the beat, so the result does not depend on the block size.
            double position = click->next_beat - (double)click->frame;
            uint32_t index = position <= 0 ? 0 : (uint32_t)ceil(position);
            if (index >= frames) break;
            uint64_t beat = atomic_load_explicit(&click->beat_count, memory_order_relaxed);
            atomic_store_explicit(&click->beat_count, beat + 1, memory_order_relaxed);
            indices[count] = index;
            beats[count] = beat;
            count++;
            click->next_beat += interval;
        }
        return count;
    }

    if (host_time == 0) return 0;
    double output_host = (double)host_time;
    if (!click->started) {
        double anchor;
        if (!spark_clock_frame_at_host_time(click->clock, output_host, &anchor)) return 0;
        click->next_beat = anchor;
        click->started = true;
        atomic_store_explicit(&click->anchor_bits, double_bits(anchor), memory_order_relaxed);
        atomic_store_explicit(&click->anchored, true, memory_order_release);
    }
    double interval = spark_clock_sample_rate(click->clock) * 60.0 / bpm;
    double late_limit = -LATE_TOLERANCE_SECONDS * click->sample_rate;
    while (count < MAX_TRIGGERS_PER_BLOCK) {
        double beat_host;
        if (!spark_clock_host_time_of_frame(click->clock, click->next_beat, &beat_host)) break;
        double position = (beat_host - output_host) / click->ticks_per_frame;
        if (position >= (double)frames - 0.5) break;
        uint64_t beat = atomic_load_explicit(&click->beat_count, memory_order_relaxed);
        atomic_store_explicit(&click->beat_count, beat + 1, memory_order_relaxed);
        click->next_beat += interval;
        if (position < late_limit) {
            atomic_fetch_add_explicit(&click->late_beats, 1, memory_order_relaxed);
            continue;
        }
        indices[count] = position <= 0 ? 0 : (uint32_t)lround(position);
        beats[count] = beat;
        count++;
    }
    return count;
}

void spark_click_render(SparkClick *click, float *mono, uint32_t frames, uint64_t host_time) {
    double bpm = bits_double(atomic_load_explicit(&click->bpm_bits, memory_order_relaxed));
    uint32_t beats_per_bar = atomic_load_explicit(&click->beats_per_bar, memory_order_relaxed);
    uint32_t volume_bits = atomic_load_explicit(&click->volume_bits, memory_order_relaxed);
    float volume;
    memcpy(&volume, &volume_bits, sizeof(volume));
    int64_t mute_from = atomic_load_explicit(&click->mute_from_beat, memory_order_relaxed);

    uint32_t indices[MAX_TRIGGERS_PER_BLOCK];
    uint64_t beats[MAX_TRIGGERS_PER_BLOCK];
    int count = find_triggers(click, frames, host_time, bpm, indices, beats);

    int next = 0;
    for (uint32_t index = 0; index < frames; index++) {
        while (next < count && indices[next] == index) {
            uint64_t beat = beats[next];
            bool accent = beat % beats_per_bar == 0;
            double frequency = accent ? ACCENT_FREQUENCY : BEAT_FREQUENCY;
            click->phase = 0;
            click->phase_step = (float)(2.0 * M_PI * frequency / click->sample_rate);
            click->envelope = 1;
            click->amplitude = volume * (accent ? 1.0f : 0.7f);
            click->sounding_beat = (int64_t)beat;
            next++;
        }
        float sample = 0;
        if (click->envelope > CLICK_END_LEVEL) {
            sample = sinf(click->phase) * click->envelope * click->amplitude;
            click->phase += click->phase_step;
            if (click->phase > (float)(2.0 * M_PI)) click->phase -= (float)(2.0 * M_PI);
            click->envelope *= click->decay;
        }
        if (mute_from >= 0 && click->sounding_beat >= mute_from) sample = 0;
        mono[index] = sample;
    }
    click->frame += frames;
}

static OSStatus output_callback(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time_stamp,
                                UInt32 bus, UInt32 frames, AudioBufferList *_Nullable data) {
    (void)flags;
    (void)bus;
    SparkClick *click = ref;
    if (!data || data->mNumberBuffers == 0) return noErr;

    // The output time of the block's first frame: when it reaches the driver, before the device's own latency.
    uint64_t host = (time_stamp->mFlags & kAudioTimeStampHostTimeValid) ? time_stamp->mHostTime : 0;
    float *first = data->mBuffers[0].mData;
    spark_click_render(click, first, frames, host);
    for (UInt32 buffer = 1; buffer < data->mNumberBuffers; buffer++) {
        memcpy(data->mBuffers[buffer].mData, first, frames * sizeof(float));
    }
    return noErr;
}

const AURenderCallback spark_click_output_callback = output_callback;

bool spark_click_anchor_frame(const SparkClick *click, double *frame) {
    if (!atomic_load_explicit(&click->anchored, memory_order_acquire)) return false;
    *frame = bits_double(atomic_load_explicit(&click->anchor_bits, memory_order_relaxed));
    return true;
}

uint64_t spark_click_beat_count(const SparkClick *click) {
    return atomic_load_explicit(&click->beat_count, memory_order_relaxed);
}

uint64_t spark_click_late_beats(const SparkClick *click) {
    return atomic_load_explicit(&click->late_beats, memory_order_relaxed);
}
