#!/bin/zsh
# Puts the same Spark Studio on this Mac and on the Omarchy laptop, and checks that both report the same version.
#
#   ./sync.sh            builds and installs here, then ships the Linux app and installs it there
#   ./sync.sh --check    only compares what is installed on both machines
#
# The version is VERSION plus an id of the files that were built (the commit, and for uncommitted changes a short
# digest), so it is the same string on both sides exactly when both run the same files. The Linux host is the SSH name
# `linux-host`, or $SPARK_LINUX_HOST. Linux needs no root: everything goes to the home folder (linux/install.sh).
set -euo pipefail
cd "$(dirname "$0")"

host="${SPARK_LINUX_HOST:-linux-host}"
mac_app="/Applications/Spark Studio.app/Contents/MacOS/SparkStudio"
linux_bin=".local/bin/spark-studio"
check_only=""
case "${1:-}" in
    "") ;;
    --check) check_only=1 ;;
    *) echo "usage: ./sync.sh [--check]" >&2; exit 64 ;;
esac

compare() {
    local mac linux
    mac="$("$mac_app" --version 2>&1 || echo "nicht installiert")"
    linux="$(ssh -o ConnectTimeout=8 "$host" "$linux_bin --version" 2>&1 || echo "nicht installiert oder nicht erreichbar")"
    printf 'Mac:   %s\nLinux: %s\n' "$mac" "$linux"
    [[ "$mac" == "$linux" ]]
}

if [[ -n "$check_only" ]]; then
    compare && echo "Gleiche Version auf beiden Rechnern." || { echo "Die Versionen unterscheiden sich. ./sync.sh gleicht sie an." >&2; exit 1; }
    exit 0
fi

build_id="$(Tools/build-id.sh)"
echo "Version $(tr -d '[:space:]' < VERSION) ($build_id)"
ssh -o ConnectTimeout=8 "$host" true || { echo "$host ist nicht erreichbar." >&2; exit 1; }

echo "== Mac =="
./build.sh --install

# The Linux app reads the model catalog from docs/ai/spark-catalog.json, which the Mac writes from its Swift
# catalog. If the two differ, the machines would know different models, so nothing is shipped.
scratch="$(mktemp -d -t spark-sync)"
trap 'rm -rf "$scratch"' EXIT
"$mac_app" --catalog-export "$scratch" >/dev/null
cmp -s "$scratch/spark-catalog.json" docs/ai/spark-catalog.json || {
    echo "docs/ai/spark-catalog.json weicht vom Katalog der Mac-App ab. Neu schreiben mit:" >&2
    echo "  \"$mac_app\" --catalog-export docs/ai" >&2
    exit 1
}

echo "== Linux ($host) =="
files=(linux VERSION docs/ai/spark-catalog.json Resources/AppIcon.png)
git ls-files -z -co --exclude-standard -- $files | COPYFILE_DISABLE=1 tar -c --no-xattrs --null -T - -f - \
    | ssh "$host" 'rm -rf ~/.cache/spark-studio-sync && mkdir -p ~/.cache/spark-studio-sync && tar -x -C ~/.cache/spark-studio-sync'
ssh "$host" "~/.cache/spark-studio-sync/linux/install.sh '$build_id'"
ssh "$host" 'rm -rf ~/.cache/spark-studio-sync'

echo "== Vergleich =="
compare && echo "Gleiche Version auf beiden Rechnern." || { echo "Die Versionen unterscheiden sich!" >&2; exit 1; }
