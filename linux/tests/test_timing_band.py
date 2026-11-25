"""What the timing band shows for a review: which bars, where click lines and strokes sit. Ported from
Tests/SparkCoreTests/TimingBandTests.swift; the view only draws this."""
import pytest

from ampbench import i18n, timing_review as tr_
from ampbench.beat_grid import BeatGrid
from ampbench.timing_band import TimingBand, pair_at, pair_showing

GRID = BeatGrid(120, 4, 0.15)  # a beat every 0.5 s, bar 1 at 0.15 s


def beat(number, bar, grid=GRID):
    return grid.time_of_bar(bar) + (number - 1) * grid.seconds_per_beat


def review(times, grid=GRID, duration=20, resolution=tr_.QUARTERS, bars=()):
    onsets = tr_.match(times, tr_.GridPoints(grid, resolution, duration))
    counted = sum(o.is_counted for o in onsets)
    return tr_.TimingReview(resolution, onsets, 0, 0, counted, [], 0.001, list(bars))


def test_the_click_lines_stand_in_the_middle_of_each_beat_with_their_numbers():
    band = TimingBand(review([]), GRID, (1, 2), 800)
    assert [p.number for p in band.points] == [1, 2, 3, 4, 1, 2, 3, 4]
    assert [p.bar for p in band.points] == [1, 1, 1, 1, 2, 2, 2, 2]
    assert [p.x for p in band.points] == [50, 150, 250, 350, 450, 550, 650, 750]


def test_onsets_are_strokes_beside_their_click_with_their_offset_in_milliseconds():
    band = TimingBand(review([beat(2, 1) + 0.018, beat(1, 2) - 0.010, beat(1, 3) + 0.005]), GRID, (1, 2), 800)
    assert len(band.strokes) == 2, "only the onsets of the bars shown"
    assert band.strokes[0].x == pytest.approx(165, abs=0.01) and band.strokes[0].label == "+18 ms"
    assert band.strokes[1].x == pytest.approx(450 - 50 / 6, abs=0.01) and band.strokes[1].label == "-10 ms"
    assert [band.points[s.point].number for s in band.strokes] == [2, 1]


def test_onsets_that_do_not_count_are_faint_and_carry_no_offset():
    band = TimingBand(review([beat(1, 1) + 0.004, beat(1, 1) + 0.034, beat(3, 1) + 0.25]), GRID, (1, 2), 800)
    assert [s.is_counted for s in band.strokes] == [True, False, False]
    assert [s.label for s in band.strokes] == ["+4 ms", None, None]
    assert band.strokes[1].x == pytest.approx(50 + 50 * 0.034 / 0.06, abs=0.01)


def test_an_onset_further_off_than_the_cell_stays_at_its_edge_with_its_true_offset():
    band = TimingBand(review([beat(2, 2) + 0.120]), GRID, (1, 2), 800)
    assert band.strokes[0].x == pytest.approx(600, abs=0.01) and band.strokes[0].is_past_the_cell
    assert band.strokes[0].label == "+120 ms"


def test_on_eighths_every_eighth_has_a_click_and_the_beats_their_numbers():
    band = TimingBand(review([], resolution=tr_.EIGHTHS), GRID, (1, 2), 800)
    assert len(band.points) == 16
    assert [p.number for p in band.points[:8]] == [1, None, 2, None, 3, None, 4, None]
    assert [p.x for p in band.points[:3]] == [25, 75, 125]


def test_the_band_reads_each_counted_note_by_its_place():
    band = TimingBand(review([beat(2, 1) + 0.018, beat(1, 2) - 0.007]), GRID, (1, 2), 800)
    assert band.spoken == "Bars 1–2: bar 1 beat 2 +18 ms, bar 2 beat 1 -7 ms"
    try:
        i18n.set_language(i18n.GERMAN)
        assert TimingBand(review([]), GRID, (3, 3), 800).spoken == "Takt 3, keine gezählten Töne"
    finally:
        i18n.set_language(i18n.ENGLISH)


def test_the_band_shows_the_two_bars_around_the_playhead_a_pair_at_a_time():
    assert pair_at(0.0, GRID, 8) == (1, 2)
    assert pair_at(beat(4, 2), GRID, 8) == (1, 2)
    assert pair_at(beat(1, 3), GRID, 8) == (3, 4)
    assert pair_at(beat(1, 7), GRID, 7) == (6, 7), "the last bar of an odd take comes with the bar before it"
    retake = BeatGrid(120, 4, 0.15, first_bar=5)
    assert pair_at(beat(1, 6, retake), retake, 8) == (5, 6)
    assert pair_showing(4, GRID, 8) == (3, 4)


def test_the_playhead_shows_in_the_band_only_near_a_click():
    band = TimingBand(review([]), GRID, (1, 2), 800)
    assert band.x(beat(2, 1)) == pytest.approx(150)
    assert band.x(beat(2, 1) + 0.03) == pytest.approx(175)
    assert band.x(beat(2, 1) + 0.2) is None


def test_each_bar_of_the_band_has_its_share_and_knows_the_review():
    bars = [tr_.Bar(1, 4, 0.01, 0.002, tr_.STEADY), tr_.Bar(2, 4, 0.01, 0.02, tr_.UNSTEADY)]
    band = TimingBand(review([], bars=bars), GRID, (1, 2), 800)
    assert [(s.bar, s.left, s.width) for s in band.bar_spans] == [(1, 0, 400), (2, 400, 400)]
    assert [s.steadiness for s in band.bar_spans] == [tr_.STEADY, tr_.UNSTEADY]
