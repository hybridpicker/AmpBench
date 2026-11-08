#!/bin/zsh
# Prints the id of what is being built: the short commit, and for uncommitted changes "+" and a short digest of them,
# so two machines that build the same files print the same id. Used by build.sh, sync.sh and linux/install.sh's caller.
set -euo pipefail
cd "$(dirname "$0")/.."
commit="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
# Only what ships to a build counts: the sources, the resources, the Linux app and the shared catalog.
paths=(Package.swift Sources Resources Tools linux VERSION docs/ai/spark-catalog.json build.sh sync.sh)
existing=()
for p in $paths; do [[ -e "$p" ]] && existing+=("$p"); done
if [[ -z "$(git status --porcelain -- $existing 2>/dev/null)" ]]; then
    echo "$commit"
else
    digest="$( (git diff HEAD -- $existing; git ls-files -z -o --exclude-standard -- $existing | xargs -0 shasum 2>/dev/null | sort) | shasum | cut -c1-6)" || true
    echo "$commit+$digest"
fi
