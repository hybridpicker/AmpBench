#!/usr/bin/env bash
# Prints the id of what is being built: the short commit, and for uncommitted changes "+" and a short digest of them,
# so two machines that build the same files print the same id. Used by build.sh and sync.sh, on macOS and on Linux,
# so it sticks to what bash 3.2 and both sets of tools can do.
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v shasum >/dev/null; then sha=shasum; else sha=sha1sum; fi

# A fixed length, because Git's automatic one depends on how many objects a clone has.
commit="$(git rev-parse --short=7 HEAD 2>/dev/null || echo nogit)"
# Only what ships to a build counts: the sources, the resources, the Linux app and the shared catalog.
existing=()
for p in Package.swift Sources Resources Tools linux VERSION docs/ai/spark-catalog.json build.sh sync.sh; do
    [[ -e "$p" ]] && existing+=("$p")
done
if [[ -z "$(git status --porcelain -- "${existing[@]}" 2>/dev/null)" ]]; then
    echo "$commit"
else
    digest="$( (git diff --no-color --no-ext-diff HEAD -- "${existing[@]}"
                git ls-files -z -o --exclude-standard -- "${existing[@]}" | xargs -0 "$sha" 2>/dev/null | sort
                ) | "$sha" | cut -c1-6)" || true
    echo "$commit+$digest"
fi
