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

**Timing review**:
The look at a finished take, recorded with the click on throughout, that shows each onset's offset, the placement and the spread. It exists only for takes recorded after the click latency of that setup was measured.
_Avoid_: Timing analysis, score, grading

**Review accuracy**:
The uncertainty a timing review states for its offsets, such as ±1 ms. Onsets found too unsure are shown but not counted.
_Avoid_: Confidence, precision score

**Live timing**:
The early-or-late signal shown right after each note while playing. It is planned after the timing review.
_Avoid_: Timing meter
