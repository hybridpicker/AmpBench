#!/usr/bin/env bash
# Sets up, removes or shows the background job that keeps this machine on GitHub's main: every 15 minutes, at login
# and when the other machine's ./sync.sh asks, it runs ./sync.sh --pull. That pulls only fast-forwards on main with a
# clean tree, and installs only while AmpBench is closed, so work in progress and a running recording are left alone.
#
#   Tools/autosync.sh install   macOS: a LaunchAgent; Linux: a systemd user timer
#   Tools/autosync.sh remove
#   Tools/autosync.sh status    the job and the end of its log
#
# The job files are written on this machine with this clone's path; nothing of them is in Git.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
label="ampbench.sync"
action="${1:-status}"

case "$(uname -s)" in
Darwin)
    plist="$HOME/Library/LaunchAgents/$label.plist"
    log="$HOME/Library/Logs/AmpBench/sync.log"
    domain="gui/$(id -u)"
    case "$action" in
    install)
        mkdir -p "$(dirname "$plist")" "$(dirname "$log")"
        cat > "$plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key><array><string>/bin/bash</string><string>$repo/sync.sh</string><string>--pull</string></array>
    <key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
    <key>StartInterval</key><integer>900</integer>
    <key>RunAtLoad</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>$log</string>
    <key>StandardErrorPath</key><string>$log</string>
</dict>
</plist>
P
        launchctl bootout "$domain/$label" 2>/dev/null || true
        launchctl bootstrap "$domain" "$plist"
        echo "Installed: $label runs ./sync.sh --pull every 15 minutes. Log: ~/Library/Logs/AmpBench/sync.log"
        ;;
    remove)
        launchctl bootout "$domain/$label" 2>/dev/null || true
        rm -f "$plist"
        echo "Removed $label."
        ;;
    status)
        launchctl print "$domain/$label" 2>/dev/null | grep -E '^\s*(state|last exit code|run interval) ' || echo "$label is not installed."
        [[ -f "$log" ]] && tail -5 "$log" || true
        ;;
    *) echo "usage: Tools/autosync.sh install|remove|status" >&2; exit 64 ;;
    esac
    ;;
Linux)
    units="$HOME/.config/systemd/user"
    case "$action" in
    install)
        mkdir -p "$units"
        cat > "$units/$label.service" <<S
[Unit]
Description=AmpBench: pull main from GitHub and install what changed
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash $repo/sync.sh --pull
S
        cat > "$units/$label.timer" <<T
[Unit]
Description=AmpBench: keep this machine on GitHub's main

[Timer]
OnStartupSec=2min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
T
        systemctl --user daemon-reload
        systemctl --user enable --now "$label.timer"
        echo "Installed: $label.timer runs ./sync.sh --pull every 15 minutes. Log: journalctl --user -u $label"
        ;;
    remove)
        systemctl --user disable --now "$label.timer" 2>/dev/null || true
        rm -f "$units/$label.service" "$units/$label.timer"
        systemctl --user daemon-reload
        echo "Removed $label."
        ;;
    status)
        systemctl --user list-timers "$label.timer" --no-pager 2>/dev/null || true
        journalctl --user -u "$label" -n 5 --no-pager -o cat 2>/dev/null || true
        ;;
    *) echo "usage: Tools/autosync.sh install|remove|status" >&2; exit 64 ;;
    esac
    ;;
*) echo "Tools/autosync.sh: only macOS and Linux" >&2; exit 1 ;;
esac
