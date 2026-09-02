# PR #3498 focused verification — expected vs observed

## Real Pi 0.84.4 SDK, watcher-owned branch fallback

**Command**

`FM_PI_BRANCH_LIVE_E2E=1 FM_PI_PACKAGE_DIR="$HOME/.npm/_npx/1f276a68aabfc75c/node_modules/@earendil-works/pi-coding-agent" bin/fm-test-run.sh tests/fm-pi-branch-live-e2e.test.sh`

**Expected**

- The real branch accepts the watcher offer but rejects its settlement when no branch model is available.
- The watcher retains delivery ownership and sends the original wake to main.
- A real post-construction 429 also rejects settlement to watcher-owned main delivery without losing the durable queue row.
- A `/new` lifecycle replacement automatically starts a watcher arm.

**Observed**

- Pi SDK version: `0.84.4`.
- The unpromptable real branch rejected its settlement; watcher-owned main delivery preserved the wake.
- The intercepted post-construction 429 rejected to watcher-owned main delivery and retained its durable row.
- The replacement lifecycle reached the test's replacement-arm observation before its second wake was delivered.
- The guard completed successfully without reading user credentials or making an external provider call.

Full transcript: `real-sdk-0.84.4-watcher-owned-fallback.log`.

## Provider-free session replacement and actionable handoff

**Command**

`bin/fm-test-run.sh tests/fm-pi-watch-extension.test.sh`

**Expected**

- Owning replacements for `/new`, `/resume`, `/fork`, reload, and same-instance replacement automatically re-arm with one live watcher generation.
- An actionable close overlapping shutdown survives into the replacement exactly once.
- Unconsumed streaming/idle follow-ups, late retiring closes, and persistence-failure handoffs remain recoverable.

**Observed**

- Every named replacement path auto-armed through the replacement generation; stale callbacks did not disturb ownership and terminal quit still refused re-arm.
- The in-flight actionable close reached the replacement once while its replacement watcher remained live.
- Streaming follow-up replay, late-close transfer, cross-module token uniqueness, and in-process recovery after persistence failure all completed successfully.

Full transcript: `provider-free-session-replacement.log`.

## Credentialed production-provider check

Not executed in this test phase. The default `pi` launcher reports `0.82.0`; the cached npm package exposes an executable `0.84.4` CLI and lists both requested models, but no repository-owned bounded guard automates the requested credentialed `/new`-while-branch-owned scenario with the specified main/branch models and efforts. An ad hoc provider-driving orchestration would not provide a repeatable, reviewable safety bound for model calls or the exact timing precondition.
