#!/usr/bin/env bash
set -u
ROOT=$(pwd)
WORK="$1/work"
rm -rf "$WORK"; mkdir -p "$WORK/fakebin" "$WORK/home/state"
cat > "$WORK/fakebin/tmux" <<'TMUX'
#!/usr/bin/env bash
case "${1:-}" in
 display-message) for a in "$@"; do case "$a" in *cursor_y*) echo 1; exit;; esac; done; echo %1 ;;
 capture-pane) printf '%s\n' 'Quick safety check: Is this a project you created or trust?' '❯ 1. Yes, I trust this folder' '  2. No, exit' 'Enter to confirm · Esc to cancel' ;;
 send-keys) printf '%s\n' "$*" >> "$FM_TMUX_LOG" ;;
esac
TMUX
cat > "$WORK/fakebin/sleep" <<'SLEEP'
#!/usr/bin/env bash
:
SLEEP
chmod +x "$WORK/fakebin/tmux" "$WORK/fakebin/sleep"
cat > "$WORK/home/state/mate.meta" <<EOF
window=sess:fm-mate
kind=secondmate
mode=secondmate
harness=claude
home=$WORK/home
EOF
: > "$WORK/tmux.log"
cd "$WORK"
set +e
env -u NO_MISTAKES_GATE PATH="$WORK/fakebin:$PATH" FM_HOME="$WORK/home" FM_ROOT_OVERRIDE="$WORK/home" FM_TMUX_LOG="$WORK/tmux.log" FM_SEND_SETTLE=0 \
  "$ROOT/bin/fm-send.sh" mate 'please handle the full steer' >/dev/null 2>"$WORK/stderr"
rc=$?
set -e
printf '%s\n' '=== End-user trust-dialog send ==='
printf 'exit=%s\n' "$rc"
grep -E 'error: text not sent|gated modal|No Enter was sent' "$WORK/stderr" | tail -1
printf 'tmux Enter calls=%s\n' "$(grep -c ' Enter' "$WORK/tmux.log" || true)"
printf 'durable pending records=%s\n' "$(find "$WORK/home/state/pending-replies" -type f 2>/dev/null | wc -l | tr -d ' ')"

. "$ROOT/bin/fm-pending-reply-lib.sh"
mkdir -p "$WORK/durable/state"
payload='Line one: full recovery payload. '
i=0; while [ "$i" -lt 15 ]; do payload="${payload}segment-$i-abcdefghijklmnopqrstuvwxyz "; i=$((i+1)); done
corr=$(FM_PENDING_REPLY_NOW=100 fm_pending_reply_create "$WORK/durable" "$WORK/durable/state" task "$payload")
rec=$(fm_pending_reply_path "$WORK/durable/state" "$corr")
body=$(fm_pending_reply_request_body "$rec")
printf '%s\n' '=== Durable recovery body ==='
printf 'payload-bytes=%s stored-bytes=%s exact-match=%s\n' "$(printf %s "$payload" | wc -c | tr -d ' ')" "$(fm_pending_reply_get "$rec" request_bytes)" "$([ "$payload" = "$body" ] && echo yes || echo no)"
recovery=$(fm_pending_reply_recovery_message "$rec")
case "$recovery" in *"$payload"*) included=yes;; *) included=no;; esac
printf 'full-payload-in-recovery=%s summary-bytes=%s\n' "$included" "$(fm_pending_reply_get "$rec" request_summary | wc -c | tr -d ' ')"
