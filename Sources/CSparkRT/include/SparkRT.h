#ifndef SPARK_RT_H
#define SPARK_RT_H

// Realtime audio code. Functions marked [RT] run on the audio thread and never lock, allocate or block.
// Everything else belongs on a normal thread.

#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

CF_ASSUME_NONNULL_BEGIN

// MARK: - Capture

typedef struct SparkCapture SparkCapture;

/// Peak value that counts as clipping. A full-scale 16-bit sample is 0.99997.
#define SPARK_CLIP_THRESHOLD 0.999f

/// `retro_frames` of 0 disables the in-memory ring buffer. The buffer is touched up front so the audio thread
/// never takes a page fault on it.
SparkCapture *spark_capture_create(uint32_t channels, uint32_t capacity_frames, double sample_rate,
                                   uint64_t retro_frames, uint64_t retro_margin_frames, uint32_t overview_bin_frames);
/// Zeroes the ring buffer before releasing it, so nothing heard stays readable in freed memory.
void spark_capture_destroy(SparkCapture *capture);
void spark_capture_set_unit(SparkCapture *capture, AudioUnit unit);

/// Input callback for an AUHAL unit. Pass the SparkCapture as its reference pointer. [RT]
extern const AURenderCallback spark_capture_input_callback;

/// The processing behind the input callback, callable with synthetic samples from tests. [RT]
void spark_capture_process(SparkCapture *capture, const float *interleaved, uint32_t frames, uint64_t host_time);

/// Starts writing to `file` at `gate_host_time`, or with the next block when it is 0. The file must already have
/// its client format set and its async buffers prepared.
void spark_capture_attach_file(SparkCapture *capture, ExtAudioFileRef file, uint64_t gate_host_time);
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
int64_t spark_capture_dropped_frames(const SparkCapture *capture);
OSStatus spark_capture_write_status(const SparkCapture *capture);
uint32_t spark_capture_clipped_blocks(const SparkCapture *capture);
uint64_t spark_capture_dropped_bins(const SparkCapture *capture);

/// Reads waveform bins as min/max pairs written while a file is attached. Returns the number of bins read.
uint32_t spark_capture_read_overview(SparkCapture *capture, float *min_max_pairs, uint32_t max_bins);

uint64_t spark_capture_retro_available_frames(const SparkCapture *capture);
/// Copies the most recent frames into `destination` and returns how many were copied.
uint64_t spark_capture_retro_copy_latest(const SparkCapture *capture, float *destination, uint64_t frames);

// MARK: - Click

typedef struct SparkClick SparkClick;

SparkClick *spark_click_create(double sample_rate);
void spark_click_destroy(SparkClick *click);

/// Safe while running. A new tempo takes effect from the next beat.
void spark_click_set_tempo(SparkClick *click, double bpm, uint32_t beats_per_bar, float volume);
/// Mutes the click from the given output frame on. Pass -1 to never mute.
void spark_click_set_mute_from(SparkClick *click, int64_t frame);

/// Output callback for an AUHAL unit with non-interleaved float buffers. Pass the SparkClick as its reference. [RT]
extern const AURenderCallback spark_click_output_callback;

/// The synthesis behind the output callback, callable from tests. [RT]
void spark_click_render(SparkClick *click, float *mono, uint32_t frames);

/// Host time of the first rendered block, or 0 before audio started.
uint64_t spark_click_first_host_time(const SparkClick *click);
uint64_t spark_click_beat_count(const SparkClick *click);

CF_ASSUME_NONNULL_END

#endif
