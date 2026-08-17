#!/bin/bash
#
# retrace-watchdog — keep Retrace actually *recording*, not merely running.
#
# Replaces io.retrace.app.keepalive, which polled every 10s with:
#     pgrep -x Retrace >/dev/null || open -g -j -a /Applications/Retrace.app
#
# That caught the case it was built for (Retrace exits, recordings silently stop
# until you notice) but not the case where Retrace is alive and recording
# nothing — the process is present, so pgrep is satisfied, and you still lose the
# day. This checks three conditions instead of one:
#
#   1. process gone                     -> launch
#   2. process alive, heartbeat stale   -> runtime wedged, restart
#   3. process alive, you are active,
#      but no new frame in a while      -> not recording, restart
#
# Check 3 is the one that matters: it measures the thing you actually care about
# (frames landing in the database) rather than a proxy for it. It is gated on
# your recent input so an idle or locked machine — where capture is *supposed* to
# be quiet — never triggers a restart.
#
# Restarts are rate limited. If Retrace is crash-looping, restarting it every
# minute forever makes things worse and buries the evidence; after the cap this
# backs off and just logs, leaving the failure intact to diagnose.

set -uo pipefail

APP_PATH="/Applications/Retrace.app"
APP_NAME="Retrace"
SUPPORT_DIR="$HOME/Library/Application Support/Retrace"
DB_PATH="$SUPPORT_DIR/retrace.db"
HEARTBEAT="$SUPPORT_DIR/.retrace_keepalive"

STATE_DIR="$HOME/services/retrace-watchdog"
LOG="$STATE_DIR/watchdog.log"
RESTART_LOG="$STATE_DIR/.restarts"

# Thresholds are env-overridable so the detection paths can be exercised without
# waiting 15 minutes for a real fault. DRY_RUN=1 logs the decision and acts on
# nothing, which is how these were verified.
#
# The app rewrites the heartbeat every 30s (StorageHealthMonitor.keepAliveInterval).
# 10x that before calling it wedged, so a transient stall is not a restart.
HEARTBEAT_STALE_SECS="${HEARTBEAT_STALE_SECS:-300}"
# Treat you as "at the machine" if there was input this recently.
USER_ACTIVE_SECS="${USER_ACTIVE_SECS:-300}"
# Capture interval is 2s and dedup discards a lot, but a quarter hour with input
# and zero frames is not deduplication, it is breakage.
NO_FRAME_SECS="${NO_FRAME_SECS:-900}"
# Give a fresh launch time to open the DB and write its first frame.
GRACE_AFTER_LAUNCH_SECS="${GRACE_AFTER_LAUNCH_SECS:-180}"
DRY_RUN="${DRY_RUN:-0}"

MAX_RESTARTS="${MAX_RESTARTS:-4}"
RESTART_WINDOW_SECS=3600
MAX_LOG_BYTES=1048576   # rotate at 1 MB; this script is not going to become the
                        # next 6 GB write-only log file.

mkdir -p "$STATE_DIR"

log() {
    if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt "$MAX_LOG_BYTES" ]; then
        mv -f "$LOG" "$LOG.1" 2>/dev/null
    fi
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$LOG"
}

now_epoch() { date +%s; }

# Seconds since the last keyboard/mouse input.
user_idle_secs() {
    local ns
    ns=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print $NF; exit}')
    [ -z "$ns" ] && { echo 999999; return; }
    echo $(( ns / 1000000000 ))
}

# Epoch seconds of the newest frame. Uses the primary key rather than
# MAX(createdAt): createdAt is not indexed, so MAX() would full-scan a 35+ GB
# table on every tick. id is AUTOINCREMENT, so the highest id is the newest row.
newest_frame_epoch() {
    [ -f "$DB_PATH" ] || { echo 0; return; }
    local ms
    # `PRAGMA busy_timeout` emits its own result row, so keep only the last line —
    # otherwise this returns "3000\n<timestamp>", fails the numeric guard below,
    # and silently disables this whole check.
    ms=$(sqlite3 -readonly "file:$DB_PATH?mode=ro" \
        "PRAGMA busy_timeout=3000;" \
        "SELECT createdAt FROM frame ORDER BY id DESC LIMIT 1;" 2>/dev/null | tail -1)
    case "$ms" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo $(( ms / 1000 )) ;;
    esac
}

restarts_in_window() {
    local cutoff=$(( $(now_epoch) - RESTART_WINDOW_SECS ))
    [ -f "$RESTART_LOG" ] || { echo 0; return; }
    awk -v c="$cutoff" '$1 >= c' "$RESTART_LOG" > "$RESTART_LOG.tmp" 2>/dev/null
    mv -f "$RESTART_LOG.tmp" "$RESTART_LOG" 2>/dev/null
    wc -l < "$RESTART_LOG" | tr -d ' '
}

launch_app() {
    open -g -j -a "$APP_PATH" 2>/dev/null
    now_epoch >> "$RESTART_LOG"
}

restart_app() {
    local reason="$1"
    local count
    count=$(restarts_in_window)
    if [ "$count" -ge "$MAX_RESTARTS" ]; then
        log "SUPPRESSED restart ($reason) — already restarted ${count}x in the last hour; backing off so the failure stays diagnosable"
        return
    fi

    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN would restart ($reason)"
        return
    fi

    log "RESTART ($reason)"
    pkill -x "$APP_NAME" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x "$APP_NAME" >/dev/null || break
        sleep 1
    done
    pgrep -x "$APP_NAME" >/dev/null && pkill -9 -x "$APP_NAME" 2>/dev/null
    sleep 1
    launch_app
}

# ---------------------------------------------------------------------------

if ! pgrep -x "$APP_NAME" >/dev/null; then
    count=$(restarts_in_window)
    if [ "$count" -ge "$MAX_RESTARTS" ]; then
        log "SUPPRESSED launch — Retrace not running, but already restarted ${count}x in the last hour; backing off"
        exit 0
    fi
    log "LAUNCH — Retrace was not running"
    launch_app
    exit 0
fi

# Retrace is running. Give a recent launch time to settle before judging it.
last_restart=$(tail -1 "$RESTART_LOG" 2>/dev/null || echo 0)
[ -z "$last_restart" ] && last_restart=0
if [ $(( $(now_epoch) - last_restart )) -lt "$GRACE_AFTER_LAUNCH_SECS" ]; then
    exit 0
fi

# 2. Heartbeat staleness. The app removes this file on clean shutdown, so absent
#    is not a fault signal — only present-and-stale is.
if [ -f "$HEARTBEAT" ]; then
    hb_age=$(( $(now_epoch) - $(stat -f%m "$HEARTBEAT" 2>/dev/null || now_epoch) ))
    if [ "$hb_age" -gt "$HEARTBEAT_STALE_SECS" ]; then
        restart_app "heartbeat stale ${hb_age}s (>${HEARTBEAT_STALE_SECS}s) — runtime wedged"
        exit 0
    fi
fi

# 3. Running, you are here, and nothing is being recorded.
idle=$(user_idle_secs)
if [ "$idle" -lt "$USER_ACTIVE_SECS" ]; then
    newest=$(newest_frame_epoch)
    if [ "$newest" -gt 0 ]; then
        frame_age=$(( $(now_epoch) - newest ))
        if [ "$frame_age" -gt "$NO_FRAME_SECS" ]; then
            restart_app "no frame for ${frame_age}s while you were active (idle ${idle}s) — running but not recording"
            exit 0
        fi
    fi
fi

exit 0
