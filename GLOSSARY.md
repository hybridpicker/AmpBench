# AmpBench

AmpBench records, shapes and checks a guitarist's playing through a modelling amp: takes, sounds, tuning and time.

## Recording and time

**Take**:
One recording, from pressing record to stopping it. Takes are the originals and are never rewritten.
_Avoid_: Recording file, clip

**Bars**:
The grid of bars and beats a take knows because it was recorded with a count-in or the click on.
_Avoid_: Beat grid, timeline

**Click latency**:
The delay from a click leaving its output to a played note arriving in the take. It is the output's reported part plus the amp's part, which no device reports and only a measurement knows; the amp's part holds for every wired output of that computer.
_Avoid_: Round trip, amp delay

**Amp's part**:
The part of the click latency that no device reports: the delay inside the amp, from the strings to what it sends to the computer. It belongs to the amp, is measured once or set by hand, and only a measured one allows a timing review.
_Avoid_: Correction, compensation, amp latency

**Check take**:
A short take of muted strums on the click that shows whether the bars sit where the notes were played.
_Avoid_: Test recording, calibration take

**Laid back**:
Playing deliberately behind the beat, so onsets land later than the click on purpose. A timing review shows it as placement, never as an error.
_Avoid_: Dragging, late

**Onset**:
The moment a played note or strum begins; for a strummed chord, its first string.
_Avoid_: Transient, hit, peak

**Grid point**:
A beat or subdivision of the bars (quarter, eighth, sixteenth or triplet) that an onset is matched to. An onset belongs to it only within its catch window, and only the first onset in that window counts, so echoes and later strings do not.
_Avoid_: Tick, slot

**Grid resolution**:
Which grid points a timing review matches onsets to: quarters, eighths, triplets or sixteenths. It starts at quarters, the beats the click plays, and a piece keeps the one chosen for it.
_Avoid_: Subdivision (the metronome's pattern), quantize

**Catch window**:
The stretch around a grid point, 35 % of the grid spacing to either side, in which an onset belongs to that grid point.
_Avoid_: Snap range, tolerance

**Offset**:
How far an onset lies from its grid point, in milliseconds; positive means later than the click.
_Avoid_: Deviation, error, percentage of a beat

**Placement**:
The average offset of the counted onsets in a take or a bar: where the player sits against the click.
_Avoid_: Pocket, average, lag

**Spread**:
How tightly the counted onsets lie around their own placement. It is the main measure of good timing.
_Avoid_: Consistency, jitter, tightness

**Unsteady bar**:
A bar whose spread stands out against the take's: in a timing review it is colored apart from the steady bars, as a weak spot to practise. A bar with fewer than two counted onsets is neither.
_Avoid_: Bad bar, error, wrong bar

**Timing review**:
The look at a finished take, recorded with the click on throughout, that shows each onset's offset, the placement and the spread. It exists only for takes recorded after the click latency of that setup was measured.
_Avoid_: Timing analysis, score, grading

**Timing stamp**:
What a take remembers of its click when it is recorded: whether the click was on throughout, the click latency its bars rest on and whether its amp's part was measured, and whether the click went to a wired output. A take without one gets no timing review.
_Avoid_: Click info, timing metadata

**Review accuracy**:
The uncertainty a timing review states for its offsets, such as ±1 ms. Onsets found too unsure are shown but not counted.
_Avoid_: Confidence, precision score

**Timing band**:
The strip below a take's waveform that shows its timing review two bars at a time, each grid point magnified: the click lines stand still with their beat numbers and the onsets lie beside them.
_Avoid_: Timing graph, zoom view

**Hint**:
Something a timing review says about a take that does not stop the review, such as a delay in the sound whose echoes may count as notes.
_Avoid_: Warning, error

**Live timing**:
The early-or-late signal shown right after each note while playing. It is planned after the timing review.
_Avoid_: Timing meter
