#!/usr/bin/env bash
# Keeps AmpBench the same on the Mac and on the Linux laptop, whichever of the two you develop on.
#
#   ./sync.sh          publishes this machine's commits on main to GitHub, installs them here, then updates the other
#                      machine and checks that both report the same version
#   ./sync.sh --pull   only brings this machine up to date with GitHub and installs what changed; the background job
#                      (Tools/autosync.sh) runs this every 15 minutes, and the other machine's ./sync.sh starts it
#   ./sync.sh --check  only compares what is installed on both machines
#
# GitHub (origin/main) is where both machines meet: each has its own clone, and nothing travels beside Git. The version
# is VERSION plus the id of what was built (Tools/build-id.sh), so both report the same string exactly when they run
# the same commit. Linux needs no root: everything goes to the home folder (linux/install.sh).
#
# Machine-specific settings are in sync.local next to this script, which Git ignores (see sync.local.example).
# Environment variables of the same names win over the file.
set -euo pipefail
cd "$(dirname "$0")"

settings=(SPARK_LINUX_HOST SPARK_LINUX_REPO SPARK_MAC_HOST SPARK_MAC_REPO)
for name in "${settings[@]}"; do eval "given_$name=\${$name:-}"; done
# shellcheck disable=SC1091
if [[ -f sync.local ]]; then source ./sync.local; fi
for name in "${settings[@]}"; do eval "if [[ -n \"\$given_$name\" ]]; then $name=\"\$given_$name\"; fi"; done

mode=publish
case "${1:-}" in
    "") ;;
    --pull) mode=pull ;;
    --check) mode=check ;;
    *) echo "usage: ./sync.sh [--pull | --check]" >&2; exit 64 ;;
esac

mac_bin="/Applications/AmpBench.app/Contents/MacOS/AmpBench"
linux_bin=".local/bin/ampbench"
job_label="ampbench.sync"
case "$(uname -s)" in
    Darwin) here=mac; other=linux; other_host="${SPARK_LINUX_HOST:-}"; other_name="SPARK_LINUX_HOST" ;;
    Linux)  here=linux; other=mac; other_host="${SPARK_MAC_HOST:-}"; other_name="SPARK_MAC_HOST" ;;
    *) echo "sync.sh: only macOS and Linux" >&2; exit 1 ;;
esac

say() { printf '%s\n' "$*"; }
# In the background job only what happened is worth a line in the log.
note() { if [[ -t 1 || "$mode" != pull ]]; then say "$*"; fi; }
die() { say "sync.sh: $*" >&2; exit 1; }

wanted_version() { printf 'AmpBench %s (%s)' "$(tr -d '[:space:]' < VERSION)" "$(Tools/build-id.sh)"; }

installed_here() {
    if [[ $here == mac ]]; then "$mac_bin" --version 2>/dev/null || true; else "$HOME/$linux_bin" --version 2>/dev/null || true; fi
}

installed_there() {
    local bin=$linux_bin; [[ $other == mac ]] && bin="$mac_bin"
    ssh -o ConnectTimeout=8 -o BatchMode=yes "$other_host" "$bin --version" 2>/dev/null || echo "not installed or not reachable"
}

app_running() {
    if [[ $here == mac ]]; then pgrep -f "^/Applications/AmpBench.app/Contents/MacOS/" >/dev/null
    else pgrep -f -- "python[0-9.]* -m ampbench( |$)" >/dev/null; fi
}

install_here() {
    if [[ $here == mac ]]; then
        ./build.sh --install
        # The Linux app reads the model catalog from docs/ai/spark-catalog.json, which the Mac writes from its Swift
        # catalog. If the two differ, the machines would know different models.
        local scratch; scratch="$(mktemp -d -t ampbench-sync.XXXXXX)"
        "$mac_bin" --catalog-export "$scratch" >/dev/null
        if ! cmp -s "$scratch/spark-catalog.json" docs/ai/spark-catalog.json; then
            rm -rf "$scratch"
            say "docs/ai/spark-catalog.json differs from the Mac app's catalog. Write it anew with:" >&2
            say "  \"$mac_bin\" --catalog-export docs/ai" >&2
            return 1
        fi
        rm -rf "$scratch"
    else
        linux/install.sh "$(Tools/build-id.sh)"
    fi
}

compare() {
    local mine theirs
    mine="$(installed_here)"; theirs="$(installed_there)"
    if [[ $here == mac ]]; then printf 'Mac:   %s\nLinux: %s\n' "$mine" "$theirs"; else printf 'Linux: %s\nMac:   %s\n' "$mine" "$theirs"; fi
    [[ -n "$mine" && "$mine" == "$theirs" ]]
}

# Nothing personal goes to the public repository: before a push, the new commits are checked for author addresses
# other than GitHub's noreply ones, home folders, this setup's host names and the global Git address, and gitleaks
# looks for secrets. Only counts and file names are printed, never the matches.
privacy_check() {
    local range="$1" failed="" bad word files words=()
    bad="$(git log --format='%ae%n%ce' "$range" | grep -vc '@users\.noreply\.github\.com$' || true)"
    if [[ "$bad" != 0 ]]; then
        say "  $bad author/committer addresses are not a GitHub noreply address (set user.email in this clone)" >&2
        failed=1
    fi
    for word in "$(git config --global user.email 2>/dev/null || true)" "${SPARK_LINUX_HOST:-}" "${SPARK_MAC_HOST:-}"; do
        word="${word#*@}"; word="${word%.local}"
        if [[ ${#word} -ge 4 ]]; then words+=("$word"); fi
    done
    # Every added line and every message line, as "file<TAB>text", in a file only this user can read.
    local added; added="$(mktemp -t ampbench-check.XXXXXX)"; chmod 600 "$added"
    { git diff --no-color --no-ext-diff -U0 "$range" \
          | awk '/^\+\+\+ b\//{f=substr($0,7)} /^\+[^+]/{print f "\t" substr($0,2)}'
      git log --format=%B "$range" | awk '{print "<commit messages>\t" $0}'; } > "$added"
    files="$( { grep -E $'\t''.*(/Users/[A-Za-z]|/home/[A-Za-z])' "$added" || true
                for word in ${words[@]+"${words[@]}"}; do grep -F -i -- "$word" "$added" || true; done; } \
              | cut -f1 | sort | uniq -c)"
    rm -f "$added"
    if [[ -n "$files" ]]; then
        say "  personal traces (home folders, host names or your address) in:" >&2; say "$files" >&2
        failed=1
    fi
    if command -v gitleaks >/dev/null; then
        gitleaks git --no-banner --log-opts="$range" >/dev/null 2>&1 \
            || { say "  gitleaks found something (run: gitleaks git --log-opts=$range)" >&2; failed=1; }
    else
        say "  gitleaks is not installed here, the secret scan is skipped" >&2
    fi
    [[ -z "$failed" ]]
}

# Starts the other machine's background job and waits for it, because only that job builds there: on the Mac it runs
# in the login session, which signing needs.
update_there() {
    if [[ -z "$other_host" ]]; then
        say "No $other_name in sync.local: the $other machine catches up through its own background job."; return 0
    fi
    if ! ssh -o ConnectTimeout=8 -o BatchMode=yes "$other_host" true 2>/dev/null; then
        say "The $other machine is not reachable. Its background job catches up when it is on again."; return 0
    fi
    say "== $other =="
    if [[ $other == linux ]]; then
        ssh "$other_host" "systemctl --user start $job_label.service && journalctl --user -u $job_label -n 3 --no-pager -o cat" \
            || say "The job on $other failed or is missing (Tools/autosync.sh install there; log: journalctl --user -u $job_label)." >&2
    else
        ssh "$other_host" "launchctl kickstart gui/\$(id -u)/$job_label" \
            || { say "The job on $other is missing (Tools/autosync.sh install there)." >&2; return 0; }
        # kickstart returns at once; a Mac build takes a few minutes.
        local want tries=0; want="$(wanted_version)"
        while [[ "$(installed_there)" != "$want" && $tries -lt 90 ]]; do sleep 10; tries=$((tries + 1)); done
    fi
}

if [[ $mode == check ]]; then
    [[ -n "$other_host" ]] || die "set $other_name in sync.local"
    if compare; then say "Same version on both machines."; else say "The versions differ. ./sync.sh brings them together." >&2; exit 1; fi
    exit 0
fi

branch="$(git symbolic-ref --short -q HEAD || true)"
dirty="$(git status --porcelain --untracked-files=no)"

if [[ $mode == pull ]]; then
    lock="${TMPDIR:-/tmp}/ampbench-sync.lock"
    mkdir "$lock" 2>/dev/null || { note "Another sync is running."; exit 0; }
    trap 'rmdir "$lock"' EXIT
    [[ "$branch" == main ]] || { note "Not on main ($branch), nothing pulled."; exit 0; }
    git fetch -q origin main 2>/dev/null || { note "GitHub is not reachable, nothing pulled."; exit 0; }
    if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
        if [[ -n "$dirty" ]]; then
            say "$(date '+%F %T') Not pulled: uncommitted changes."
        elif git merge-base --is-ancestor HEAD origin/main; then
            git merge -q --ff-only origin/main && say "$(date '+%F %T') Pulled $(git rev-parse --short=7 HEAD)."
        else
            note "This machine has commits GitHub has not: publish them with ./sync.sh."
        fi
    fi
    want="$(wanted_version)"
    if [[ "$(installed_here)" == "$want" ]]; then note "Up to date: $want"; exit 0; fi
    if app_running; then
        say "$(date '+%F %T') AmpBench is open, so $want is installed once it is closed."
        exit 0
    fi
    say "$(date '+%F %T') Installing $want"
    install_here
    exit 0
fi

# Publish.
[[ "$branch" == main ]] || die "publishing works from main (this is $branch)"
[[ -z "$dirty" ]] || die "uncommitted changes: commit them first (./build.sh --install tries them on the Mac without publishing)"
[[ "$(Tools/build-id.sh)" != *+* ]] || die "untracked files in what ships (see git status): commit or remove them first"
git fetch -q origin main || die "GitHub is not reachable"
if ! git merge-base --is-ancestor origin/main HEAD; then
    if git merge-base --is-ancestor HEAD origin/main; then
        git merge -q --ff-only origin/main; say "Pulled from GitHub: $(git rev-parse --short=7 HEAD)"
    else
        die "this machine and GitHub both have new commits: git pull --rebase origin main, check, then ./sync.sh again"
    fi
fi
range="origin/main..HEAD"
count="$(git rev-list --count "$range")"
if [[ "$count" != 0 ]]; then
    say "== Checking $count new commit(s) before publishing =="
    privacy_check "$range" || die "nothing was pushed"
    git push -q origin HEAD:main
    say "Published to GitHub."
fi
say "Version $(wanted_version)"
say "== $here =="
if [[ "$(installed_here)" == "$(wanted_version)" ]]; then say "Already installed."; else install_here; fi
update_there
if [[ -n "$other_host" ]]; then
    say "== Comparison =="
    if compare; then say "Same version on both machines."; else say "The versions differ (see above)." >&2; exit 1; fi
fi
