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
