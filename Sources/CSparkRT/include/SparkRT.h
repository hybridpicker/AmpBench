#ifndef SPARK_RT_H
#define SPARK_RT_H

// Realtime audio code. Functions marked [RT] run on the audio thread and never lock, allocate or block.
// Everything else belongs on a normal thread.

#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

CF_ASSUME_NONNULL_BEGIN

// MARK: - Input clock

/// Where the input device's frames lie in host time. The capture callback publishes every block, and the click
/// reads it to place its beats on input frames, so the two devices cannot drift apart even with separate clocks.
typedef struct SparkClock SparkClock;

SparkClock *spark_clock_create(double sample_rate);
void spark_clock_destroy(SparkClock *clock);
/// Records that input frame `frame` reached the driver at `host_time`. [RT]
void spark_clock_publish(SparkClock *clock, int64_t frame, uint64_t host_time);
/// The host time of an input frame, extrapolated from the latest block. False before the first block. [RT]
bool spark_clock_host_time_of_frame(const SparkClock *clock, double frame, double *host_time);
/// The input frame at a host time. False before the first block. [RT]
bool spark_clock_frame_at_host_time(const SparkClock *clock, double host_time, double *frame);
double spark_clock_sample_rate(const SparkClock *clock);

// MARK: - Capture

typedef struct SparkCapture SparkCapture;

/// Peak value that counts as clipping. A full-scale 16-bit sample is 0.99997.
#define SPARK_CLIP_THRESHOLD 0.999f

/// `retro_frames` of 0 disables the in-memory ring buffer. The buffer is touched up front so the audio thread
/// never takes a page fault on it.
/// `clock` may be NULL. When given, every block is published to it, counted in the frames this capture received.
SparkCapture *spark_capture_create(uint32_t channels, uint32_t capacity_frames, double sample_rate,
                                   uint64_t retro_frames, uint64_t retro_margin_frames, uint32_t overview_bin_frames,
                                   SparkClock *_Nullable clock);
/// Zeroes the ring buffer before releasing it, so nothing heard stays readable in freed memory.
void spark_capture_destroy(SparkCapture *capture);
void spark_capture_set_unit(SparkCapture *capture, AudioUnit unit);

/// Input callback for an AUHAL unit. Pass the SparkCapture as its reference pointer. [RT]
extern const AURenderCallback spark_capture_input_callback;

/// The processing behind the input callback, callable with synthetic samples from tests. [RT]
void spark_capture_process(SparkCapture *capture, const float *interleaved, uint32_t frames, uint64_t host_time);

/// Means "start with the next block" for `spark_capture_attach_file`.
#define SPARK_GATE_NONE (-1)

/// Starts writing to `file` at input frame `gate_frame`, or with the next block for SPARK_GATE_NONE. A gate that has
/// already passed starts with the next block too. The file must already have its client format set and its async
/// buffers prepared.
void spark_capture_attach_file(SparkCapture *capture, ExtAudioFileRef file, int64_t gate_frame);
/// Stops writing and waits for a callback in progress to finish. Returns false when the callback did not finish in
/// time, in which case the file must not be disposed.
bool spark_capture_detach_file(SparkCapture *capture);

/// Peak since the previous call.
float spark_capture_take_level(SparkCapture *capture);
/// True when a block reached the clipping threshold since the previous call.
bool spark_capture_take_clip(SparkCapture *capture);
uint64_t spark_capture_callback_count(const SparkCapture *capture);
OSStatus spark_capture_render_status(const SparkCapture *capture);

float spark_capture_file_peak(const SparkCapture *capture);
int64_t spark_capture_file_frames(const SparkCapture *capture);
/// The input frame, counted like the clock, that became the first frame of the file. -1 before the first write.
int64_t spark_capture_file_first_frame(const SparkCapture *capture);
/// Input frames received since the capture was created.
int64_t spark_capture_frames_received(const SparkCapture *capture);
int64_t spark_capture_dropped_frames(const SparkCapture *capture);
OSStatus spark_capture_write_status(const SparkCapture *capture);
uint32_t spark_capture_clipped_blocks(const SparkCapture *capture);
uint64_t spark_capture_dropped_bins(const SparkCapture *capture);

/// Reads waveform bins as min/max pairs written while a file is attached. Returns the number of bins read.
uint32_t spark_capture_read_overview(SparkCapture *capture, float *min_max_pairs, uint32_t max_bins);

uint64_t spark_capture_retro_available_frames(const SparkCapture *capture);
/// Copies the most recent frames into `destination` and returns how many were copied.
uint64_t spark_capture_retro_copy_latest(const SparkCapture *capture, float *destination, uint64_t frames);

// MARK: - Tap

/// A mono copy of an input for a listener that only reads, such as the tuner. One single-producer, single-consumer
/// ring buffer: the capture callback writes the average of all channels, a normal thread reads. Nothing is kept
/// beyond the ring, and the ring is zeroed when the tap is destroyed.
typedef struct SparkTap SparkTap;

/// The capacity is rounded up to a power of two. The buffer is touched up front, so writing never faults a page in.
SparkTap *spark_tap_create(uint32_t capacity_frames);
void spark_tap_destroy(SparkTap *tap);
uint32_t spark_tap_capacity(const SparkTap *tap);
/// Announces a new stream with its sample rate, before the tap is attached to a capture. The reader sees a new epoch
/// and drops what it had. Not while a capture writes into this tap.
void spark_tap_begin(SparkTap *tap, double sample_rate);
double spark_tap_sample_rate(const SparkTap *tap);
uint32_t spark_tap_epoch(const SparkTap *tap);
/// Writes the average of the channels. When the reader is behind, the newest frames are dropped and counted. [RT]
void spark_tap_write(SparkTap *tap, const float *interleaved, uint32_t frames, uint32_t channels);
/// Reads up to `max_frames` frames, oldest first. Returns how many were read.
uint32_t spark_tap_read(SparkTap *tap, float *destination, uint32_t max_frames);
/// Drops everything written so far, for a reader that starts over.
void spark_tap_skip(SparkTap *tap);
uint64_t spark_tap_overruns(const SparkTap *tap);

/// Lets the capture write every block into `tap` as well. The tap must have been begun with this capture's rate.
void spark_capture_set_tap(SparkCapture *capture, SparkTap *_Nullable tap);
/// Stops writing into the tap and waits for a callback in progress to finish. Returns false when it did not finish
/// in time, in which case the tap must not be destroyed yet.
bool spark_capture_clear_tap(SparkCapture *capture);

// MARK: - Click

typedef struct SparkClick SparkClick;

/// Without a clock the beats follow the output's own frames. With one, they lie on frames of that input: beat 0 on
/// the input frame that matches the first output block, and every further beat a whole interval of input frames
/// later. Each block is placed by its host time, so neither device's clock error moves the beats against the input.
/// The click does not own the clock, which must outlive it.
SparkClick *spark_click_create(double sample_rate, SparkClock *_Nullable clock);
void spark_click_destroy(SparkClick *click);

/// Safe while running. A new tempo takes effect from the next beat.
void spark_click_set_tempo(SparkClick *click, double bpm, uint32_t beats_per_bar, float volume);
/// Silences every beat from the given beat number on, also one still ringing. Pass -1 to never mute.
void spark_click_set_mute_from_beat(SparkClick *click, int64_t beat);

/// Output callback for an AUHAL unit with non-interleaved float buffers. Pass the SparkClick as its reference. [RT]
extern const AURenderCallback spark_click_output_callback;

/// The synthesis behind the output callback, callable from tests. `host_time` is the output time of the first
/// frame. A click with a clock stays silent while the host time or the clock is unknown. [RT]
void spark_click_render(SparkClick *click, float *mono, uint32_t frames, uint64_t host_time);

/// The input frame of beat 0. False until the click has started on a clock.
bool spark_click_anchor_frame(const SparkClick *click, double *frame);
uint64_t spark_click_beat_count(const SparkClick *click);
/// Beats that came too late to sound, for example after the output stalled. They still count.
uint64_t spark_click_late_beats(const SparkClick *click);

CF_ASSUME_NONNULL_END

#endif
