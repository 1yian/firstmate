#!/usr/bin/env bash
# Actual Pi CLI/SDK proof for optional supervisor memory, with local scripted providers.
# FM_OPTCHAT_PACKAGE names the unmodified published pi-optchat@0.7.2 package.
# The guard prepares a separate pinned dependency patch in scratch (no download here).
# No credentials, production homes, model evaluation, fleet supervision or Herdr operations.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_OPTCHAT_LIVE pi node npm git patch
if [ -z "${FM_OPTCHAT_PACKAGE:-}" ] || [ ! -f "$FM_OPTCHAT_PACKAGE/package.json" ]; then
  if [ "${FM_OPTCHAT_LIVE:-}" = 1 ] || [ "${FM_LIVE:-}" = 1 ]; then
    fail "FM_OPTCHAT_PACKAGE must name the installed optional pi-optchat package"
  fi
  printf 'SKIP: optional pi-optchat package absent (set FM_OPTCHAT_PACKAGE)\n'
  exit 0
fi
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
[ -f "$PI_PACKAGE_DIR/dist/index.js" ] || fail "installed Pi SDK absent (set FM_PI_PACKAGE_DIR)"
# Keep macOS Unix socket paths below OptChat's 103-byte limit.
TMP_ROOT=$(TMPDIR=/tmp fm_test_tmproot fm-optchat)
trap fm_test_cleanup EXIT
FM_OPTCHAT_ROOT="$ROOT" FM_OPTCHAT_SCRATCH="$TMP_ROOT" FM_OPTCHAT_PACKAGE="$FM_OPTCHAT_PACKAGE" \
  PI_PACKAGE_DIR="$PI_PACKAGE_DIR" node "$ROOT/tests/fixtures/fm-optchat-e2e.mjs"
printf 'PASS: pinned memory integration preserves restart, notifications, lossless recall and Firstmate-only delegation\n'
