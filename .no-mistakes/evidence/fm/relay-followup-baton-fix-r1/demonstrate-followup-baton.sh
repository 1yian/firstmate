#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE_DIR=/Users/kunchen/.no-mistakes/evidence/01M0K1Y4ADW6E61A1D3HE2DCJ4
HOME_DIR=$(mktemp -d "$EVIDENCE_DIR/manual-home.XXXXXX")
trap 'rm -rf "$HOME_DIR"' EXIT
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/fakebin"
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
printf 'FMX_PAIRING_TOKEN=test-token\n' > "$HOME_DIR/.env"
cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
cat > "$HOME_DIR/fakebin/curl" <<'EOF'
#!/usr/bin/env bash
url= data=
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary)
      case "$2" in
        @-) data=$(cat) ;;
        @*) data=$(cat -- "${2#@}") ;;
        *) data=$2 ;;
      esac
      shift 2 ;;
    -H|-m|-w|-X|-o) shift 2 ;;
    -s) shift ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [[ "$url" == */connector/followup ]]; then
  printf 'PUBLIC POST PAYLOAD: %s\n' "$data" >> "$FM_DEMO_POST_LOG"
  printf 200
else
  printf 204
fi
EOF
chmod +x "$HOME_DIR/fakebin/curl"
export PATH="$HOME_DIR/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DEMO_POST_LOG="$HOME_DIR/posts.log"
cd "$HOME_DIR"

jq -n '{request_id:"req-demo",platform:"discord",context_binding:{version:"ctx1",value:"ctx1_req-demo"},public_safe_summary:"investigate and fix worker placement",received_at:"2026-01-01T00:00:00Z",followup_expires_at:"2030-01-08T00:00:00Z",reservation_expires_at:"2030-01-08T00:00:00Z"}' > request.json
jq -n '{type:"pr-merged",project:"firstmate",required_deliverables:["pr_url"],completion_policy:"all-required"}' > expected.json
jq -n '{relation_id:"rel-code",work_ref:{home_id:"main",task_id:"investigation"},role:"fulfills",required:true,generation:1}' > relation.json
tasks-axi public-followup add pf-investigation --request-context-file request.json --purpose promised-final --expected-final-file expected.json --expires-at 2030-01-08T00:00:00Z >/dev/null
tasks-axi public-followup bind-work pf-investigation --relation-file relation.json >/dev/null
"$ROOT/bin/fm-public-followup.sh" register pf-investigation --relation rel-code --work-home main --work-id investigation --generation 1 >/dev/null
FM_HOME="$HOME_DIR" bash -c ". '$ROOT/bin/fm-x-lib.sh'; fmx_context_registry_set '$HOME_DIR/state' req-demo discord 1900"

mkdir child
"$ROOT/bin/fm-public-followup-emit.sh" --home "$HOME_DIR" --obligation pf-investigation --relation rel-code --source-home main --work-id investigation --generation 1 --outcome pr-merged --deliverable pr_url=https://github.com/example/firstmate/pull/42 --outcome-text 'Investigation shipped the fix.'
"$ROOT/bin/fm-public-followup.sh" consume
"$ROOT/bin/fm-public-followup.sh" deliver pf-investigation

echo
echo '=== Session-start pending surface after delivery ==='
"$ROOT/bin/fm-public-followup.sh" pending

echo
echo '=== Retained registration state (public-safe fields only) ==='
grep -E '^(obligation_id|work_home|work_id|state|delivered_at|followup_expires_at|request_context_b64)=' "$HOME_DIR/state/public-followup/registry/pf-investigation" | sed 's/^request_context_b64=.*/request_context_b64=<bounded encoded public-safe context>/'

echo
echo '=== Rechain the delivered investigation baton to follow-on fix work ==='
"$ROOT/bin/fm-public-followup.sh" rechain pf-followon --from pf-investigation --work-home main --work-id followon-fix --expected pr-merged

echo
echo '=== Registry after rechain ==='
for f in "$HOME_DIR/state/public-followup/registry"/*; do
  printf '%s: ' "$(basename "$f")"
  grep -E '^(state|work_id)=' "$f" | paste -sd ' ' -
done
echo "source registration present: $([ -e "$HOME_DIR/state/public-followup/registry/pf-investigation" ] && echo yes || echo no)"
echo "retirement receipt present: $([ -e "$HOME_DIR/state/public-followup/retired/pf-investigation" ] && echo yes || echo no)"
grep -E '^(reason|retired_at)=' "$HOME_DIR/state/public-followup/retired/pf-investigation"

echo
echo '=== Public delivery observed ==='
cat "$HOME_DIR/posts.log"
