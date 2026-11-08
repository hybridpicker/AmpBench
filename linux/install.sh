#!/usr/bin/env bash
# Installs Spark Studio for Linux for the current user, without root: the app and its Python environment go to
# ~/.local/share/spark-studio, the launcher to ~/.local/bin/spark-studio, the menu entry to ~/.local/share/applications.
#
#   linux/install.sh <build-id>
#
# Normally started by ../sync.sh on the Mac, which ships the tree and passes the build id, so that the Mac app and this
# one report the same version. The tests run first, headless; a failing test stops the install and leaves the
# installed version as it is.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build_id="${1:?usage: linux/install.sh <build-id>}"
share="$HOME/.local/share/spark-studio"
venv="$share/venv"
new="$share/app.new"
app="$share/app"

command -v python3 >/dev/null || { echo "python3 fehlt" >&2; exit 1; }
mkdir -p "$share" "$HOME/.local/bin" "$HOME/.local/share/applications"

# Python environment, renewed when requirements.txt changed.
wanted="$(sha256sum "$root/linux/requirements.txt" | cut -d' ' -f1)"
if [[ ! -x "$venv/bin/python" || "$(cat "$share/requirements.sha" 2>/dev/null || true)" != "$wanted" ]]; then
    [[ -x "$venv/bin/python" ]] || python3 -m venv "$venv"
    "$venv/bin/pip" install --quiet --upgrade -r "$root/linux/requirements.txt"
    echo "$wanted" > "$share/requirements.sha"
fi

# The new tree next to the old one.
rm -rf "$new"
mkdir -p "$new/spark_studio/data"
cp -R "$root/linux/spark_studio/." "$new/spark_studio/"
find "$new" -name __pycache__ -type d -prune -exec rm -rf {} +
find "$root" -name '._*' -type f -delete
cp "$root/VERSION" "$new/VERSION"
printf '%s\n' "$build_id" > "$new/BUILD"
cp "$root/docs/ai/spark-catalog.json" "$new/spark_studio/data/spark-catalog.json"
cp "$root/Resources/AppIcon.png" "$new/spark_studio/data/AppIcon.png"

# The tests are the gate.
if [[ -d "$root/linux/tests" ]]; then
    (cd "$root/linux" && QT_QPA_PLATFORM=offscreen "$venv/bin/python" -m pytest -q -p no:cacheprovider tests) \
        || { echo "Die Tests sind fehlgeschlagen. Die installierte Version bleibt unverändert." >&2; rm -rf "$new"; exit 1; }
fi

# Swap in.
rm -rf "$share/app.old"
[[ -d "$app" ]] && mv "$app" "$share/app.old"
mv "$new" "$app"
rm -rf "$share/app.old"

cat > "$HOME/.local/bin/spark-studio" <<L
#!/usr/bin/env bash
exec env PYTHONPATH="$app" "$venv/bin/python" -m spark_studio "\$@"
L
chmod +x "$HOME/.local/bin/spark-studio"

icons="$HOME/.local/share/icons/hicolor/1024x1024/apps"
mkdir -p "$icons"
cp "$app/spark_studio/data/AppIcon.png" "$icons/spark-studio.png"
cat > "$HOME/.local/share/applications/spark-studio.desktop" <<D
[Desktop Entry]
Type=Application
Name=Spark Studio
GenericName=Spark Amp Presets
Comment=Presets des Positive Grid Spark bearbeiten, hören und sichern
Exec=$HOME/.local/bin/spark-studio
Icon=spark-studio
Terminal=false
Categories=AudioVideo;Audio;Music;
StartupWMClass=spark-studio
D
command -v update-desktop-database >/dev/null && update-desktop-database "$HOME/.local/share/applications" || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$HOME/.local/share/icons/hicolor" || true

"$HOME/.local/bin/spark-studio" --version
