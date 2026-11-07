#include "SparkRT.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define CLICK_DECAY_SECONDS 0.012
#define CLICK_END_LEVEL 0.001f
#define ACCENT_FREQUENCY 1760.0
#define BEAT_FREQUENCY 1175.0

struct SparkClick {
    double sample_rate;

    _Atomic uint64_t interval_bits;
    _Atomic uint32_t beats_per_bar;
    _Atomic uint32_t volume_bits;
    _Atomic int64_t mute_from;
    _Atomic uint64_t first_host_time;
    _Atomic uint64_t beat_count;

    // Audio thread only.
    uint64_t frame;
    double next_beat;
    float phase;
    float phase_step;
    float envelope;
    float decay;
    float amplitude;
};

SparkClick *spark_click_create(double sample_rate) {
    SparkClick *click = calloc(1, sizeof(SparkClick));
    click->sample_rate = sample_rate;
    click->decay = (float)exp(-1.0 / (CLICK_DECAY_SECONDS * sample_rate));
    atomic_store(&click->mute_from, -1);
    spark_click_set_tempo(click, 120, 4, 0.5f);
    return click;
}

void spark_click_destroy(SparkClick *click) {
    free(click);
}

void spark_click_set_tempo(SparkClick *click, double bpm, uint32_t beats_per_bar, float volume) {
    double interval = click->sample_rate * 60.0 / bpm;
    uint64_t interval_bits;
    memcpy(&interval_bits, &interval, sizeof(interval_bits));
    uint32_t volume_bits;
    memcpy(&volume_bits, &volume, sizeof(volume_bits));
    atomic_store_explicit(&click->interval_bits, interval_bits, memory_order_relaxed);
    atomic_store_explicit(&click->beats_per_bar, beats_per_bar > 0 ? beats_per_bar : 1, memory_order_relaxed);
    atomic_store_explicit(&click->volume_bits, volume_bits, memory_order_relaxed);
}

void spark_click_set_mute_from(SparkClick *click, int64_t frame) {
    atomic_store_explicit(&click->mute_from, frame, memory_order_relaxed);
}

void spark_click_render(SparkClick *click, float *mono, uint32_t frames) {
    uint64_t interval_bits = atomic_load_explicit(&click->interval_bits, memory_order_relaxed);
    double interval;
    memcpy(&interval, &interval_bits, sizeof(interval));
    uint32_t beats_per_bar = atomic_load_explicit(&click->beats_per_bar, memory_order_relaxed);
    uint32_t volume_bits = atomic_load_explicit(&click->volume_bits, memory_order_relaxed);
    float volume;
    memcpy(&volume, &volume_bits, sizeof(volume));
    int64_t mute_from = atomic_load_explicit(&click->mute_from, memory_order_relaxed);

    for (uint32_t index = 0; index < frames; index++) {
        if ((double)click->frame >= click->next_beat) {
            uint64_t beat = atomic_load_explicit(&click->beat_count, memory_order_relaxed);
            bool accent = beat % beats_per_bar == 0;
            double frequency = accent ? ACCENT_FREQUENCY : BEAT_FREQUENCY;
            click->phase = 0;
            click->phase_step = (float)(2.0 * M_PI * frequency / click->sample_rate);
            click->envelope = 1;
            click->amplitude = volume * (accent ? 1.0f : 0.7f);
            click->next_beat += interval;
            atomic_store_explicit(&click->beat_count, beat + 1, memory_order_relaxed);
        }
        float sample = 0;
        if (click->envelope > CLICK_END_LEVEL) {
            sample = sinf(click->phase) * click->envelope * click->amplitude;
            click->phase += click->phase_step;
            if (click->phase > (float)(2.0 * M_PI)) click->phase -= (float)(2.0 * M_PI);
            click->envelope *= click->decay;
        }
        if (mute_from >= 0 && (int64_t)click->frame >= mute_from) sample = 0;
        mono[index] = sample;
        click->frame++;
    }
}

static OSStatus output_callback(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time_stamp,
                                UInt32 bus, UInt32 frames, AudioBufferList *_Nullable data) {
    (void)flags;
    (void)bus;
    SparkClick *click = ref;
    if (!data || data->mNumberBuffers == 0) return noErr;

    uint64_t expected = 0;
    if ((time_stamp->mFlags & kAudioTimeStampHostTimeValid) && time_stamp->mHostTime != 0) {
        atomic_compare_exchange_strong_explicit(&click->first_host_time, &expected, time_stamp->mHostTime,
                                                memory_order_relaxed, memory_order_relaxed);
    }
    float *first = data->mBuffers[0].mData;
    spark_click_render(click, first, frames);
    for (UInt32 buffer = 1; buffer < data->mNumberBuffers; buffer++) {
        memcpy(data->mBuffers[buffer].mData, first, frames * sizeof(float));
    }
    return noErr;
}

const AURenderCallback spark_click_output_callback = output_callback;

uint64_t spark_click_first_host_time(const SparkClick *click) {
    return atomic_load_explicit(&click->first_host_time, memory_order_relaxed);
}

uint64_t spark_click_beat_count(const SparkClick *click) {
    return atomic_load_explicit(&click->beat_count, memory_order_relaxed);
}
