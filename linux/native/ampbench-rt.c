// ampbench-rt: records a Spark's USB input and plays the click, in one PipeWire client.
//
// The Linux app first recorded with `pw-record` and played the metronome with `pw-cat`, two processes that know
// nothing of each other's timing. The bars of a take need more: the frame of the input at which the click's first
// beat was handed to the output. This helper is the Linux form of Sources/CSparkRT/clock.c and click.c: the capture
// stream publishes (input frame, time) pairs, the click places its beats on input frames through them, so the click
// and the input may run on different devices with different clocks for any length of time without drifting apart.
//
//   ampbench-rt --target <serial or node name> --rate <Hz> --channels <n>
//
// stdout: the input, raw interleaved signed 32-bit little-endian frames, exactly what `pw-record --format s32 --raw`
//         gave, so the app counts input frames by counting what it reads.
// stdin:  one command per line:
//           click <id> <bpm> <beats per bar> <volume 0…1> <first muted beat or -1> <output serial, node name or ->
//           tempo <bpm> <beats per bar> <volume>
//           mute <first muted beat or -1>
//           stop                (the click only; the input keeps running)
//         End of input ends the helper.
// stderr: event lines that start with "@", everything else is PipeWire's own log:
//           @format <rate> <channels>          the input's negotiated format
//           @latency <input s> <output s>      what the devices report, when it changes
//           @anchor <id> <input frame>         the input frame of the click's beat 0
//           @beats <id> <started> <late>       beats the click has started and beats skipped as too late
//         The id is the one of the click command, so a line about a click already stopped is never taken for the
//         next one.
//           @state <capture|click> <state> [error]
//           @lost <frames>                     input frames dropped because the app did not read them in time
//
// Times are CLOCK_MONOTONIC nanoseconds, the clock PipeWire stamps every cycle with (pw_time.now). Like Core Audio's
// time stamps on the Mac, they mark the cycle, not the moment the sound leaves or enters the device: the devices'
// own delays are reported separately (@latency) and added by the app (ClickTiming in SparkCore, click_timing.py).

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <semaphore.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/utils/ringbuffer.h>

// ---------------------------------------------------------------------------------------------------------------
// The input's clock (clock.c): one writer, the capture callback; readers on the audio threads. A sequence lock lets
// a reader see a consistent pair without ever blocking the writer.

typedef struct {
    double sample_rate;
    double ns_per_frame;
    _Atomic uint64_t sequence;
    _Atomic int64_t frame;
    _Atomic uint64_t host_time;
} InputClock;

static void clock_init(InputClock *clock, double sample_rate) {
    clock->sample_rate = sample_rate;
    clock->ns_per_frame = 1e9 / sample_rate;
    atomic_store(&clock->sequence, 0);
}

static void clock_publish(InputClock *clock, int64_t frame, uint64_t host_time) {
    if (host_time == 0) return;
    uint64_t sequence = atomic_load_explicit(&clock->sequence, memory_order_relaxed);
    atomic_store_explicit(&clock->sequence, sequence + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&clock->frame, frame, memory_order_relaxed);
    atomic_store_explicit(&clock->host_time, host_time, memory_order_relaxed);
    atomic_store_explicit(&clock->sequence, sequence + 2, memory_order_release);
}

static bool clock_latest(InputClock *clock, int64_t *frame, uint64_t *host_time) {
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

static bool clock_frame_at(InputClock *clock, double host, double *frame) {
    int64_t f;
    uint64_t h;
    if (!clock_latest(clock, &f, &h)) return false;
    *frame = (double)f + (host - (double)h) / clock->ns_per_frame;
    return true;
}

static bool clock_host_of_frame(InputClock *clock, double frame, double *host) {
    int64_t f;
    uint64_t h;
    if (!clock_latest(clock, &f, &h)) return false;
    *host = (double)h + (frame - (double)f) * clock->ns_per_frame;
    return true;
}

// ---------------------------------------------------------------------------------------------------------------
// The click (click.c): the recorder's click, a decaying sine, higher on the first beat of a bar.

#define CLICK_DECAY_SECONDS 0.012
#define CLICK_END_LEVEL 0.001f
#define ACCENT_FREQUENCY 1760.0
#define BEAT_FREQUENCY 1175.0
// A beat that should have started this much before the block still sounds, at the block's first frame. Anything
// later is skipped rather than played off the grid.
#define LATE_TOLERANCE_SECONDS 0.003
#define MAX_TRIGGERS_PER_BLOCK 16

typedef struct {
    double sample_rate;
    double ns_per_frame;
    InputClock *clock;

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
    double next_beat;  // an input frame
    int64_t sounding_beat;
    float phase;
    float phase_step;
    float envelope;
    float decay;
    float amplitude;
} Click;

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

static void click_set_tempo(Click *click, double bpm, uint32_t beats_per_bar, float volume) {
    uint32_t volume_bits;
    memcpy(&volume_bits, &volume, sizeof(volume_bits));
    atomic_store_explicit(&click->bpm_bits, double_bits(bpm > 0 ? bpm : 120), memory_order_relaxed);
    atomic_store_explicit(&click->beats_per_bar, beats_per_bar > 0 ? beats_per_bar : 1, memory_order_relaxed);
    atomic_store_explicit(&click->volume_bits, volume_bits, memory_order_relaxed);
}

static void click_reset(Click *click, double sample_rate, InputClock *clock) {
    click->sample_rate = sample_rate;
    click->ns_per_frame = 1e9 / sample_rate;
    click->clock = clock;
    click->decay = (float)exp(-1.0 / (CLICK_DECAY_SECONDS * sample_rate));
    click->sounding_beat = -1;
    click->started = false;
    click->envelope = 0;
    atomic_store(&click->mute_from_beat, -1);
    atomic_store(&click->beat_count, 0);
    atomic_store(&click->late_beats, 0);
    atomic_store(&click->anchored, false);
}

static int click_find_triggers(Click *click, uint32_t frames, uint64_t host_time, double bpm, uint32_t *indices,
                               uint64_t *beats) {
    int count = 0;
    if (host_time == 0) return 0;
    double output_host = (double)host_time;
    if (!click->started) {
        double anchor;
        if (!clock_frame_at(click->clock, output_host, &anchor)) return 0;
        click->next_beat = anchor;
        click->started = true;
        atomic_store_explicit(&click->anchor_bits, double_bits(anchor), memory_order_relaxed);
        atomic_store_explicit(&click->anchored, true, memory_order_release);
    }
    double interval = click->clock->sample_rate * 60.0 / bpm;
    double late_limit = -LATE_TOLERANCE_SECONDS * click->sample_rate;
    while (count < MAX_TRIGGERS_PER_BLOCK) {
        double beat_host;
        if (!clock_host_of_frame(click->clock, click->next_beat, &beat_host)) break;
        double position = (beat_host - output_host) / click->ns_per_frame;
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

static void click_render(Click *click, float *mono, uint32_t frames, uint64_t host_time) {
    double bpm = bits_double(atomic_load_explicit(&click->bpm_bits, memory_order_relaxed));
    uint32_t beats_per_bar = atomic_load_explicit(&click->beats_per_bar, memory_order_relaxed);
    uint32_t volume_bits = atomic_load_explicit(&click->volume_bits, memory_order_relaxed);
    float volume;
    memcpy(&volume, &volume_bits, sizeof(volume));
    int64_t mute_from = atomic_load_explicit(&click->mute_from_beat, memory_order_relaxed);

    uint32_t indices[MAX_TRIGGERS_PER_BLOCK];
    uint64_t beats[MAX_TRIGGERS_PER_BLOCK];
    int count = click_find_triggers(click, frames, host_time, bpm, indices, beats);

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
}

// ---------------------------------------------------------------------------------------------------------------
// The client.

#define RING_SECONDS 4

typedef struct {
    struct pw_main_loop *loop;
    struct pw_context *context;
    struct pw_core *core;

    struct pw_stream *capture;
    struct spa_hook capture_listener;
    struct pw_stream *playback;
    struct spa_hook playback_listener;

    const char *target;
    uint32_t rate;
    uint32_t channels;
    uint32_t frame_bytes;

    InputClock clock;
    Click click;
    int64_t captured;  // capture thread only

    struct spa_ringbuffer ring;
    uint8_t *ring_data;
    uint32_t ring_size;
    sem_t ring_ready;
    atomic_bool writer_done;
    _Atomic uint64_t lost;

    _Atomic uint64_t latency_in_ns;
    _Atomic uint64_t latency_out_ns;

    // Main loop only: what was last reported.
    bool format_told;
    bool anchor_told;
    unsigned long click_id;
    uint64_t beats_told, late_told, lost_told, latency_in_told, latency_out_told;
    struct spa_source *timer;
    struct spa_source *input;
    char line[512];
    size_t line_length;
} App;

static void event(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void event(const char *format, ...) {
    va_list args;
    va_start(args, format);
    fputc('@', stderr);
    vfprintf(stderr, format, args);
    fputc('\n', stderr);
    fflush(stderr);
    va_end(args);
}

static uint64_t delay_ns(const struct pw_time *time, uint32_t rate) {
    double seconds = 0;
    if (time->rate.denom > 0) seconds += (double)time->delay * time->rate.num / time->rate.denom;
    if (rate > 0) seconds += (double)time->buffered / rate;
    return seconds > 0 ? (uint64_t)(seconds * 1e9) : 0;
}

static void on_capture_process(void *data) {
    App *app = data;
    struct pw_buffer *buffer = pw_stream_dequeue_buffer(app->capture);
    if (!buffer) return;
    struct spa_data *d = &buffer->buffer->datas[0];
    if (d->data && d->chunk && app->frame_bytes > 0) {
        uint32_t offset = SPA_MIN(d->chunk->offset, d->maxsize);
        uint32_t size = SPA_MIN(d->chunk->size, d->maxsize - offset);
        size -= size % app->frame_bytes;
        struct pw_time time;
        if (pw_stream_get_time_n(app->capture, &time, sizeof(time)) == 0 && time.now > 0) {
            clock_publish(&app->clock, app->captured, (uint64_t)time.now);
            atomic_store_explicit(&app->latency_in_ns, delay_ns(&time, app->rate), memory_order_relaxed);
        }
        uint32_t index;
        int32_t filled = spa_ringbuffer_get_write_index(&app->ring, &index);
        if (filled < 0 || (uint32_t)filled + size > app->ring_size) {
            atomic_fetch_add_explicit(&app->lost, size / app->frame_bytes, memory_order_relaxed);
        } else {
            spa_ringbuffer_write_data(&app->ring, app->ring_data, app->ring_size, index % app->ring_size,
                                      SPA_PTROFF(d->data, offset, void), size);
            spa_ringbuffer_write_update(&app->ring, index + size);
            sem_post(&app->ring_ready);
        }
        app->captured += size / app->frame_bytes;
    }
    pw_stream_queue_buffer(app->capture, buffer);
}

static void on_playback_process(void *data) {
    App *app = data;
    struct pw_buffer *buffer = pw_stream_dequeue_buffer(app->playback);
    if (!buffer) return;
    struct spa_data *d = &buffer->buffer->datas[0];
    if (d->data) {
        uint32_t frames = d->maxsize / sizeof(float);
        if (buffer->requested > 0 && buffer->requested < frames) frames = (uint32_t)buffer->requested;
        struct pw_time time;
        uint64_t host = 0;
        if (pw_stream_get_time_n(app->playback, &time, sizeof(time)) == 0 && time.now > 0) {
            host = (uint64_t)time.now;
            atomic_store_explicit(&app->latency_out_ns, delay_ns(&time, app->rate), memory_order_relaxed);
        }
        click_render(&app->click, d->data, frames, host);
        d->chunk->offset = 0;
        d->chunk->stride = sizeof(float);
        d->chunk->size = frames * sizeof(float);
    }
    pw_stream_queue_buffer(app->playback, buffer);
}

static void on_capture_param(void *data, uint32_t id, const struct spa_pod *param) {
    App *app = data;
    if (param == NULL || id != SPA_PARAM_Format) return;
    struct spa_audio_info_raw info;
    if (spa_format_audio_raw_parse(param, &info) < 0) return;
    app->rate = info.rate;
    app->channels = info.channels;
    app->frame_bytes = 4 * info.channels;
    clock_init(&app->clock, info.rate);
    app->format_told = false;
}

static const char *state_name(enum pw_stream_state state) {
    return pw_stream_state_as_string(state);
}

static void on_capture_state(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error) {
    (void)data;
    (void)old;
    event("state capture %s%s%s", state_name(state), error ? " " : "", error ? error : "");
    if (state == PW_STREAM_STATE_UNCONNECTED || state == PW_STREAM_STATE_ERROR) {
        App *app = data;
        pw_main_loop_quit(app->loop);
    }
}

static void on_playback_state(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error) {
    (void)old;
    App *app = data;
    event("state click %lu %s%s%s", app->click_id, state_name(state), error ? " " : "", error ? error : "");
}

static const struct pw_stream_events capture_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_capture_state,
    .param_changed = on_capture_param,
    .process = on_capture_process,
};

static const struct pw_stream_events playback_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_playback_state,
    .process = on_playback_process,
};

/// The properties both streams share: never fall back to another device, never follow the default. A missing Spark
/// must not turn into a recording from the microphone, and a missing click output not into the amp.
static void pin_to_target(struct pw_properties *props, const char *target) {
    pw_properties_set(props, PW_KEY_TARGET_OBJECT, target);
    pw_properties_set(props, PW_KEY_NODE_DONT_RECONNECT, "true");
    pw_properties_set(props, "node.dont-fallback", "true");
    pw_properties_set(props, "node.dont-move", "true");
}

static int connect_stream(struct pw_stream *stream, enum spa_direction direction, uint32_t rate, uint32_t channels,
                          enum spa_audio_format format) {
    uint8_t buffer[1024];
    struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    struct spa_audio_info_raw info = {.format = format, .rate = rate, .channels = channels};
    const struct spa_pod *params[1];
    params[0] = spa_format_audio_raw_build(&builder, SPA_PARAM_EnumFormat, &info);
    return pw_stream_connect(stream, direction, PW_ID_ANY,
                             PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS,
                             params, 1);
}

static void stop_click(App *app) {
    if (!app->playback) return;
    pw_stream_destroy(app->playback);
    app->playback = NULL;
    click_reset(&app->click, app->rate, &app->clock);
    app->anchor_told = false;
    app->beats_told = app->late_told = 0;
    atomic_store(&app->latency_out_ns, 0);
}

static void start_click(App *app, unsigned long id, double bpm, uint32_t beats, float volume, int64_t mute_from,
                        const char *target) {
    stop_click(app);
    app->click_id = id;
    click_reset(&app->click, app->rate, &app->clock);
    click_set_tempo(&app->click, bpm, beats, volume);
    atomic_store(&app->click.mute_from_beat, mute_from);
    char latency[32];
    snprintf(latency, sizeof(latency), "256/%u", app->rate);
    struct pw_properties *props = pw_properties_new(PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Playback",
                                                    PW_KEY_MEDIA_ROLE, "Music", PW_KEY_NODE_NAME, "ampbench-click",
                                                    PW_KEY_NODE_DESCRIPTION, "AmpBench click", PW_KEY_NODE_LATENCY,
                                                    latency, NULL);
    if (target && strcmp(target, "-") != 0) pin_to_target(props, target);
    app->playback = pw_stream_new(app->core, "ampbench-click", props);
    if (!app->playback) {
        event("state click %lu error cannot-create", id);
        return;
    }
    pw_stream_add_listener(app->playback, &app->playback_listener, &playback_events, app);
    if (connect_stream(app->playback, PW_DIRECTION_OUTPUT, app->rate, 1, SPA_AUDIO_FORMAT_F32) < 0) {
        event("state click %lu error cannot-connect", id);
        stop_click(app);
    }
}

static void handle_line(App *app, char *line) {
    char word[16] = {0};
    if (sscanf(line, "%15s", word) != 1) return;
    if (strcmp(word, "click") == 0) {
        unsigned long id;
        double bpm;
        unsigned beats;
        float volume;
        long long mute_from;
        char target[256];
        if (sscanf(line, "click %lu %lf %u %f %lld %255s", &id, &bpm, &beats, &volume, &mute_from, target) == 6
            && bpm > 0) {
            if (app->rate == 0) {
                event("state click %lu error input-not-ready", id);
                return;
            }
            start_click(app, id, bpm, beats, volume, mute_from, target);
        }
    } else if (strcmp(word, "tempo") == 0) {
        double bpm;
        unsigned beats;
        float volume;
        if (sscanf(line, "tempo %lf %u %f", &bpm, &beats, &volume) == 3) click_set_tempo(&app->click, bpm, beats, volume);
    } else if (strcmp(word, "mute") == 0) {
        long long mute_from;
        if (sscanf(line, "mute %lld", &mute_from) == 1) atomic_store(&app->click.mute_from_beat, mute_from);
    } else if (strcmp(word, "stop") == 0) {
        stop_click(app);
    }
}

static void on_stdin(void *data, int fd, uint32_t mask) {
    App *app = data;
    if (mask & (SPA_IO_ERR | SPA_IO_HUP) && !(mask & SPA_IO_IN)) {
        pw_main_loop_quit(app->loop);
        return;
    }
    char chunk[256];
    ssize_t n = read(fd, chunk, sizeof(chunk));
    if (n <= 0) {
        if (n == 0 || (errno != EAGAIN && errno != EINTR)) pw_main_loop_quit(app->loop);
        return;
    }
    for (ssize_t i = 0; i < n; i++) {
        if (chunk[i] == '\n') {
            app->line[app->line_length] = 0;
            handle_line(app, app->line);
            app->line_length = 0;
        } else if (app->line_length < sizeof(app->line) - 1) {
            app->line[app->line_length++] = chunk[i];
        }
    }
}

static void on_timer(void *data, uint64_t expirations) {
    (void)expirations;
    App *app = data;
    if (!app->format_told && app->rate > 0) {
        event("format %u %u", app->rate, app->channels);
        app->format_told = true;
    }
    uint64_t in = atomic_load(&app->latency_in_ns), out = atomic_load(&app->latency_out_ns);
    // Reported in steps of 10 µs, so the line does not repeat for noise.
    if (in / 10000 != app->latency_in_told / 10000 || out / 10000 != app->latency_out_told / 10000) {
        event("latency %.6f %.6f", in / 1e9, out / 1e9);
        app->latency_in_told = in;
        app->latency_out_told = out;
    }
    if (app->playback) {
        if (!app->anchor_told && atomic_load_explicit(&app->click.anchored, memory_order_acquire)) {
            event("anchor %lu %.4f", app->click_id, bits_double(atomic_load(&app->click.anchor_bits)));
            app->anchor_told = true;
        }
        uint64_t beats = atomic_load(&app->click.beat_count), late = atomic_load(&app->click.late_beats);
        if (beats != app->beats_told || late != app->late_told) {
            event("beats %lu %llu %llu", app->click_id, (unsigned long long)beats, (unsigned long long)late);
            app->beats_told = beats;
            app->late_told = late;
        }
    }
    uint64_t lost = atomic_load(&app->lost);
    if (lost != app->lost_told) {
        event("lost %llu", (unsigned long long)lost);
        app->lost_told = lost;
    }
}

/// Drains the ring to stdout. The capture callback never waits for the app; if the app stalls, the ring and then
/// the pipe buffer it.
static void *writer(void *data) {
    App *app = data;
    while (!atomic_load(&app->writer_done)) {
        sem_wait(&app->ring_ready);
        uint32_t index;
        int32_t filled;
        while ((filled = spa_ringbuffer_get_read_index(&app->ring, &index)) > 0) {
            uint32_t offset = index % app->ring_size;
            uint32_t size = SPA_MIN((uint32_t)filled, app->ring_size - offset);
            ssize_t written = write(STDOUT_FILENO, app->ring_data + offset, size);
            if (written < 0) {
                if (errno == EINTR) continue;
                atomic_store(&app->writer_done, true);
                pw_main_loop_quit(app->loop);
                return NULL;
            }
            spa_ringbuffer_read_update(&app->ring, index + (uint32_t)written);
        }
    }
    return NULL;
}

static void on_signal(void *data, int signal_number) {
    (void)signal_number;
    App *app = data;
    pw_main_loop_quit(app->loop);
}

int main(int argc, char *argv[]) {
    App app = {0};
    for (int i = 1; i + 1 < argc; i += 2) {
        if (strcmp(argv[i], "--target") == 0) app.target = argv[i + 1];
        else if (strcmp(argv[i], "--rate") == 0) app.rate = (uint32_t)strtoul(argv[i + 1], NULL, 10);
        else if (strcmp(argv[i], "--channels") == 0) app.channels = (uint32_t)strtoul(argv[i + 1], NULL, 10);
    }
    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        printf("ampbench-rt 1\n");
        return 0;
    }
    if (!app.target || app.rate == 0 || app.channels == 0) {
        fprintf(stderr, "usage: ampbench-rt --target <serial or node name> --rate <Hz> --channels <n>\n");
        return 64;
    }
    signal(SIGPIPE, SIG_IGN);
    pw_init(&argc, &argv);

    app.frame_bytes = 4 * app.channels;
    clock_init(&app.clock, app.rate);
    click_reset(&app.click, app.rate, &app.clock);
    app.ring_size = 1;
    while (app.ring_size < RING_SECONDS * app.rate * app.frame_bytes) app.ring_size <<= 1;
    app.ring_data = calloc(1, app.ring_size);
    spa_ringbuffer_init(&app.ring);
    sem_init(&app.ring_ready, 0, 0);

    app.loop = pw_main_loop_new(NULL);
    struct pw_loop *loop = pw_main_loop_get_loop(app.loop);
    pw_loop_add_signal(loop, SIGINT, on_signal, &app);
    pw_loop_add_signal(loop, SIGTERM, on_signal, &app);
    app.context = pw_context_new(loop, NULL, 0);
    app.core = app.context ? pw_context_connect(app.context, NULL, 0) : NULL;
    if (!app.core) {
        event("state capture error no-pipewire");
        return 1;
    }

    char latency[32];
    snprintf(latency, sizeof(latency), "256/%u", app.rate);
    struct pw_properties *props = pw_properties_new(PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Capture",
                                                    PW_KEY_MEDIA_ROLE, "Production", PW_KEY_NODE_NAME,
                                                    "ampbench-capture", PW_KEY_NODE_DESCRIPTION, "AmpBench recording",
                                                    PW_KEY_NODE_LATENCY, latency, NULL);
    pin_to_target(props, app.target);
    app.capture = pw_stream_new(app.core, "ampbench-capture", props);
    pw_stream_add_listener(app.capture, &app.capture_listener, &capture_events, &app);
    if (connect_stream(app.capture, PW_DIRECTION_INPUT, app.rate, app.channels, SPA_AUDIO_FORMAT_S32_LE) < 0) {
        event("state capture error cannot-connect");
        return 1;
    }

    fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK);
    app.input = pw_loop_add_io(loop, STDIN_FILENO, SPA_IO_IN | SPA_IO_HUP | SPA_IO_ERR, false, on_stdin, &app);
    app.timer = pw_loop_add_timer(loop, on_timer, &app);
    struct timespec value = {0, 1}, interval = {0, 20 * 1000 * 1000};
    pw_loop_update_timer(loop, app.timer, &value, &interval, false);

    pthread_t writer_thread;
    pthread_create(&writer_thread, NULL, writer, &app);

    pw_main_loop_run(app.loop);

    stop_click(&app);
    pw_stream_destroy(app.capture);
    atomic_store(&app.writer_done, true);
    sem_post(&app.ring_ready);
    pthread_join(writer_thread, NULL);
    pw_core_disconnect(app.core);
    pw_context_destroy(app.context);
    pw_main_loop_destroy(app.loop);
    pw_deinit();
    free(app.ring_data);
    return 0;
}
