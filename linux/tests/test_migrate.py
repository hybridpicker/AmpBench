from ampbench import migrate


def test_old_folder_and_settings_move_to_the_new_name(tmp_path):
    old = tmp_path / "Music" / "Spark Studio" / "Presets"
    old.mkdir(parents=True)
    (old / "Jazz.json").write_text("{}")
    settings = tmp_path / ".config" / "local.sparkstudio" / "Spark Studio.conf"
    settings.parent.mkdir(parents=True)
    settings.write_text("[General]\npiece=1\n")

    assert migrate.carry_over(tmp_path) == ["folder", "settings"]
    assert (tmp_path / "Music" / "AmpBench" / "Presets" / "Jazz.json").read_text() == "{}"
    assert not (tmp_path / "Music" / "Spark Studio").exists()
    assert (tmp_path / ".config" / "local.ampbench" / "AmpBench.conf").read_text() == settings.read_text()
    assert settings.exists()
    assert migrate.carry_over(tmp_path) == []


def test_nothing_is_overwritten_when_both_exist(tmp_path):
    (tmp_path / "Music" / "Spark Studio").mkdir(parents=True)
    (tmp_path / "Music" / "Spark Studio" / "old.txt").write_text("old")
    (tmp_path / "Music" / "AmpBench").mkdir(parents=True)
    (tmp_path / "Music" / "AmpBench" / "new.txt").write_text("new")

    assert migrate.carry_over(tmp_path) == []
    assert (tmp_path / "Music" / "Spark Studio" / "old.txt").read_text() == "old"
    assert (tmp_path / "Music" / "AmpBench" / "new.txt").read_text() == "new"


def test_the_takes_folder_gets_its_english_name_after_the_app_folder(tmp_path):
    old = tmp_path / "Music" / "Spark Studio" / "Aufnahmen"
    old.mkdir(parents=True)
    (old / "Aufnahme_x.wav").write_bytes(b"audio")

    assert migrate.carry_over(tmp_path) == ["folder", "recordings"]
    assert (tmp_path / "Music" / "AmpBench" / "Recordings" / "Aufnahme_x.wav").read_bytes() == b"audio"
    assert not (tmp_path / "Music" / "AmpBench" / "Aufnahmen").exists()
    assert migrate.carry_over(tmp_path) == []


def test_both_takes_folders_stay_when_both_exist(tmp_path):
    root = tmp_path / "Music" / "AmpBench"
    (root / "Aufnahmen").mkdir(parents=True)
    (root / "Aufnahmen" / "old.wav").write_bytes(b"old")
    (root / "Recordings").mkdir()
    (root / "Recordings" / "new.wav").write_bytes(b"new")

    assert migrate.carry_over(tmp_path) == []
    assert (root / "Aufnahmen" / "old.wav").read_bytes() == b"old"
    assert sorted(p.name for p in (root / "Recordings").iterdir()) == ["new.wav"]


def test_a_takes_folder_that_cannot_be_renamed_stays_and_is_still_used(tmp_path, monkeypatch):
    from pathlib import Path

    from ampbench import store
    root = tmp_path / "Music" / "AmpBench"
    (root / "Aufnahmen").mkdir(parents=True)
    (root / "Aufnahmen" / "old.wav").write_bytes(b"old")
    real = Path.rename

    def refuse(self, target):
        if self.name == "Aufnahmen":
            raise PermissionError(13, "Permission denied")
        return real(self, target)
    monkeypatch.setattr(Path, "rename", refuse)
    monkeypatch.setattr(Path, "home", lambda: tmp_path)

    assert migrate.carry_over(tmp_path) == []
    assert (root / "Aufnahmen" / "old.wav").read_bytes() == b"old" and not (root / "Recordings").exists()
    assert store.default_folder() == root / "Aufnahmen"
    monkeypatch.setattr(Path, "rename", real)
    assert migrate.carry_over(tmp_path) == ["recordings"]
    assert store.default_folder() == root / "Recordings"
