#include "SparkRT.h"
#include "hosttime.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// The practice metronome. Everything that decides when a pulse sounds runs here, on the audio thread, against the
// output's own sample clock: no timer, no main thread, nothing that can be late.
//
// Timing: a pulse lies at `anchor + k * interval` output frames, a product and never a running sum, so rounding
// cannot add up over hours. A new anchor is set only where the interval changes (a new tempo from the window or the
// trainer, a new subdivision), at the exact position of that pulse. Each sound starts at the pulse's fraction of a
// frame: its oscillator and envelope begin already advanced by the part of a frame that lies before the first
// sample, so a pulse is placed to well below a sample, not rounded to the next one.

#define VOICES 8
#define RING 256
#define END_LEVEL 0.0005f

typedef struct {
    bool active;
    uint32_t start;
    double phase;
    double step;
    double phase2;
    double step2;
    float amp;
    float amp2;
    float env;
    float decay;
    float env2;
    float decay2;
} Voice;

typedef struct {
    double accent;
    double beat;
    double sub;
    double tau;
    /// A second, inharmonic partial for the wood sound: ratio, level, own decay. Ratio 0 is none.
    double ratio2;
    float level2;
    double tau2;
} Sound;

static const Sound SOUNDS[3] = {
    {1760.0, 1175.0, 1175.0, 0.012, 0.0, 0.0f, 0.0},   // classic: the recorder's click
    {1650.0, 1250.0, 1250.0, 0.006, 2.76, 0.45f, 0.003}, // wood: short, with an inharmonic overtone
    {1000.0, 800.0, 800.0, 0.045, 0.0, 0.0f, 0.0},     // beep: longer and lower
};

static const float LEVELS[4] = {0.0f, 0.4f, 0.7f, 1.0f};

struct SparkMetronome {
    double sample_rate;
    double ticks_per_frame;

    // The window writes a config here; the audio thread takes it when the sequence is even and new (a seqlock).
    _Atomic uint32_t seq;
    SparkMetronomeConfig pending;

    _Atomic uint64_t latency_ticks;
    _Atomic uint64_t bpm_bits;
    _Atomic uint64_t frames_done;

    // Events for the window: written by the audio thread, read by one reader.
    SparkMetronomeEvent ring[RING];
    _Atomic uint32_t head;
    _Atomic uint32_t tail;

    // Audio thread only.
    uint32_t taken_seq;
    bool has_config;
    bool waiting;
    SparkMetronomeConfig config;
    SparkMetronomeConfig next_config;
    double bpm;
    double anchor;
    double interval;
    uint64_t k;
    uint64_t bar;
    uint32_t beat;
    uint32_t sub;
    uint32_t bars_since_step;
    uint64_t frame;
    Voice voices[VOICES];
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

static SparkMetronomeConfig sanitized(SparkMetronomeConfig config) {
    if (!(config.bpm >= 10 && config.bpm <= 600)) config.bpm = config.bpm > 600 ? 600 : (config.bpm >= 10 ? config.bpm : 120);
    if (config.beats_per_bar < 1) config.beats_per_bar = 1;
    if (config.beats_per_bar > SPARK_METRONOME_MAX_BEATS) config.beats_per_bar = SPARK_METRONOME_MAX_BEATS;
    if (config.subdivision < 1) config.subdivision = 1;
    if (config.subdivision > 8) config.subdivision = 8;
    for (int i = 0; i < SPARK_METRONOME_MAX_BEATS; i++) {
        if (config.levels[i] > SPARK_BEAT_ACCENT) config.levels[i] = SPARK_BEAT_NORMAL;
    }
    if (config.sound > 2) config.sound = 0;
    if (!(config.volume >= 0)) config.volume = 0;
    if (config.volume > 1) config.volume = 1;
    if (!(config.subdivision_level >= 0)) config.subdivision_level = 0;
    if (config.subdivision_level > 1) config.subdivision_level = 1;
    if (config.trainer_every_bars < 1) config.trainer_every_bars = 1;
    if (!(config.trainer_target >= 10 && config.trainer_target <= 600)) config.trainer_step = 0;
    return config;
}

SparkMetronome *spark_metronome_create(double sample_rate) {
    SparkMetronome *metronome = calloc(1, sizeof(SparkMetronome));
    metronome->sample_rate = sample_rate > 0 ? sample_rate : 48000;
    metronome->ticks_per_frame = spark_host_clock_frequency() / metronome->sample_rate;
    return metronome;
}

void spark_metronome_destroy(SparkMetronome *metronome) {
    free(metronome);
}

void spark_metronome_configure(SparkMetronome *metronome, const SparkMetronomeConfig *config) {
    uint32_t seq = atomic_load_explicit(&metronome->seq, memory_order_relaxed);
    atomic_store_explicit(&metronome->seq, seq + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    metronome->pending = *config;
    atomic_store_explicit(&metronome->seq, seq + 2, memory_order_release);
}

void spark_metronome_set_output_latency(SparkMetronome *metronome, double seconds) {
    double ticks = seconds > 0 ? seconds * spark_host_clock_frequency() : 0;
    atomic_store_explicit(&metronome->latency_ticks, (uint64_t)llround(ticks), memory_order_relaxed);
}

/// A consistent copy of the latest config, if one came since the last. [RT]
static bool take_config(SparkMetronome *metronome, SparkMetronomeConfig *out) {
    uint32_t before = atomic_load_explicit(&metronome->seq, memory_order_acquire);
    if ((before & 1) || before == metronome->taken_seq) return false;
    SparkMetronomeConfig copy = metronome->pending;
    atomic_thread_fence(memory_order_acquire);
    uint32_t after = atomic_load_explicit(&metronome->seq, memory_order_relaxed);
    if (before != after) return false;
    metronome->taken_seq = before;
    *out = sanitized(copy);
    return true;
}

static void set_tempo(SparkMetronome *metronome, double bpm, double anchor) {
    metronome->bpm = bpm;
    metronome->interval = metronome->sample_rate * 60.0 / bpm / (double)metronome->config.subdivision;
    metronome->anchor = anchor;
    metronome->k = 0;
    atomic_store_explicit(&metronome->bpm_bits, double_bits(bpm), memory_order_relaxed);
}

/// Takes a waiting config at the pulse about to be placed, which lies on a beat. [RT]
static void apply_waiting(SparkMetronome *metronome) {
    double position = metronome->anchor + (double)metronome->k * metronome->interval;
    metronome->config = metronome->next_config;
    metronome->waiting = false;
    metronome->bars_since_step = 0;
    if (metronome->beat >= metronome->config.beats_per_bar) {
        metronome->beat = 0;
        metronome->bar++;
    }
    set_tempo(metronome, metronome->config.bpm, position);
}

static void push_event(SparkMetronome *metronome, double position, uint64_t block_host) {
    uint32_t head = atomic_load_explicit(&metronome->head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&metronome->tail, memory_order_acquire);
    if (head - tail >= RING) return;
    SparkMetronomeEvent *event = &metronome->ring[head % RING];
    event->bar = metronome->bar;
    event->beat = metronome->beat;
    event->sub = metronome->sub;
    event->bpm = metronome->bpm;
    event->frame = position;
    event->host_time = 0;
    if (block_host) {
        double offset = (position - (double)metronome->frame) * metronome->ticks_per_frame;
        double latency = (double)atomic_load_explicit(&metronome->latency_ticks, memory_order_relaxed);
        event->host_time = (uint64_t)llround((double)block_host + offset + latency);
    }
    atomic_store_explicit(&metronome->head, head + 1, memory_order_release);
}

static void start_voice(SparkMetronome *metronome, double position, float amplitude, double frequency) {
    if (amplitude <= 0) return;
    const Sound *sound = &SOUNDS[metronome->config.sound];
    Voice *voice = NULL;
    for (int i = 0; i < VOICES && !voice; i++) {
        if (!metronome->voices[i].active) voice = &metronome->voices[i];
    }
    if (!voice) {
        // All busy, which needs very fast pulses: the quietest makes room.
        voice = &metronome->voices[0];
        for (int i = 1; i < VOICES; i++) {
            if (metronome->voices[i].env * metronome->voices[i].amp < voice->env * voice->amp) voice = &metronome->voices[i];
        }
    }
    double first = ceil(position);
    double before = first - position; // the part of a frame that lies between the pulse and its first sample
    double rate = metronome->sample_rate;
    voice->active = true;
    voice->start = first > (double)metronome->frame ? (uint32_t)(first - (double)metronome->frame) : 0;
    voice->step = 2.0 * M_PI * frequency / rate;
    voice->phase = voice->step * before;
    voice->decay = (float)exp(-1.0 / (sound->tau * rate));
    voice->env = (float)exp(-before / (sound->tau * rate));
    voice->amp = amplitude;
    voice->amp2 = 0;
    if (sound->ratio2 > 0) {
        voice->step2 = voice->step * sound->ratio2;
        voice->phase2 = voice->step2 * before;
        voice->decay2 = (float)exp(-1.0 / (sound->tau2 * rate));
        voice->env2 = (float)exp(-before / (sound->tau2 * rate));
        voice->amp2 = amplitude * sound->level2;
    }
}

/// Places every pulse whose first sample falls in this block. [RT]
static void place_pulses(SparkMetronome *metronome, uint32_t frames, uint64_t host_time) {
    double end = (double)(metronome->frame + frames);
    for (int guard = 0; guard < 64; guard++) {
        if (metronome->waiting && metronome->sub == 0) apply_waiting(metronome);
        double position = metronome->anchor + (double)metronome->k * metronome->interval;
        if (ceil(position) >= end) break;

        const SparkMetronomeConfig *config = &metronome->config;
        const Sound *sound = &SOUNDS[config->sound];
        float amplitude;
        double frequency;
        if (metronome->sub == 0) {
            uint8_t level = config->levels[metronome->beat];
            amplitude = LEVELS[level];
            frequency = level == SPARK_BEAT_ACCENT ? sound->accent : sound->beat;
        } else {
            amplitude = LEVELS[SPARK_BEAT_NORMAL] * config->subdivision_level;
            frequency = sound->sub;
        }
        start_voice(metronome, position, amplitude * config->volume, frequency);
        push_event(metronome, position, host_time);

        // The next pulse.
        metronome->k++;
        metronome->sub++;
        if (metronome->sub < config->subdivision) continue;
        metronome->sub = 0;
        metronome->beat++;
        if (metronome->beat < config->beats_per_bar) continue;
        metronome->beat = 0;
        metronome->bar++;
        metronome->bars_since_step++;
        if (config->trainer_step != 0 && metronome->bars_since_step >= config->trainer_every_bars) {
            metronome->bars_since_step = 0;
            double target = config->trainer_target;
            double next = metronome->bpm + config->trainer_step;
            if (config->trainer_step > 0 ? next > target : next < target) next = target;
            if (next != metronome->bpm) {
                set_tempo(metronome, next, metronome->anchor + (double)metronome->k * metronome->interval);
            }
        }
    }
}

void spark_metronome_render(SparkMetronome *metronome, float *const *channels, uint32_t channel_count,
                            uint32_t frames, uint64_t host_time) {
    if (channel_count == 0) return;
    float *out = channels[0];
    memset(out, 0, frames * sizeof(float));

    SparkMetronomeConfig fresh;
    if (take_config(metronome, &fresh)) {
        if (!metronome->has_config) {
            metronome->config = fresh;
            metronome->has_config = true;
            set_tempo(metronome, fresh.bpm, (double)metronome->frame);
        } else {
            metronome->next_config = fresh;
            metronome->waiting = true;
        }
    }

    if (metronome->has_config) place_pulses(metronome, frames, host_time);

    for (int i = 0; i < VOICES; i++) {
        Voice *voice = &metronome->voices[i];
        if (!voice->active) continue;
        uint32_t index = voice->start < frames ? voice->start : frames;
        for (; index < frames; index++) {
            // Ends on the sample where it fades out, whatever the block size.
            if (voice->env < END_LEVEL && (voice->amp2 <= 0 || voice->env2 < END_LEVEL)) {
                voice->active = false;
                break;
            }
            float sample = (float)sin(voice->phase) * voice->env * voice->amp;
            voice->phase += voice->step;
            voice->env *= voice->decay;
            if (voice->amp2 > 0) {
                sample += (float)sin(voice->phase2) * voice->env2 * voice->amp2;
                voice->phase2 += voice->step2;
                voice->env2 *= voice->decay2;
            }
            out[index] += sample;
        }
        if (voice->phase > 2.0 * M_PI * 64) voice->phase = fmod(voice->phase, 2.0 * M_PI);
        if (voice->phase2 > 2.0 * M_PI * 64) voice->phase2 = fmod(voice->phase2, 2.0 * M_PI);
        voice->start = 0;
    }
    for (uint32_t index = 0; index < frames; index++) {
        if (out[index] > 1) out[index] = 1;
        if (out[index] < -1) out[index] = -1;
    }
    for (uint32_t channel = 1; channel < channel_count; channel++) {
        memcpy(channels[channel], out, frames * sizeof(float));
    }
    metronome->frame += frames;
    atomic_store_explicit(&metronome->frames_done, metronome->frame, memory_order_relaxed);
}

bool spark_metronome_next_event(SparkMetronome *metronome, SparkMetronomeEvent *event) {
    uint32_t tail = atomic_load_explicit(&metronome->tail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&metronome->head, memory_order_acquire);
    if (tail == head) return false;
    *event = metronome->ring[tail % RING];
    atomic_store_explicit(&metronome->tail, tail + 1, memory_order_release);
    return true;
}

double spark_metronome_current_bpm(const SparkMetronome *metronome) {
    return bits_double(atomic_load_explicit(&metronome->bpm_bits, memory_order_relaxed));
}

uint64_t spark_metronome_frames(const SparkMetronome *metronome) {
    return atomic_load_explicit(&metronome->frames_done, memory_order_relaxed);
}

static OSStatus output_callback(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time_stamp,
                                UInt32 bus, UInt32 frames, AudioBufferList *_Nullable data) {
    (void)flags;
    (void)bus;
    if (!data || data->mNumberBuffers == 0) return noErr;
    float *channels[8];
    UInt32 count = data->mNumberBuffers < 8 ? data->mNumberBuffers : 8;
    for (UInt32 index = 0; index < count; index++) channels[index] = data->mBuffers[index].mData;
    uint64_t host = (time_stamp->mFlags & kAudioTimeStampHostTimeValid) ? time_stamp->mHostTime : 0;
    spark_metronome_render(ref, channels, count, frames, host);
    return noErr;
}

const AURenderCallback spark_metronome_output_callback = output_callback;
