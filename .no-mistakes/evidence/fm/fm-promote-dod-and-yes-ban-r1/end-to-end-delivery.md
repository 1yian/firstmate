# End-to-end delivery evidence

## Promotion command output

```text
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no watcher has a fresh beacon (last beat: never, grace 300s).
●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.
●  This is a supervision warning only; the guarded operation WILL still run.
●  repair a missing or failed watcher cycle with the Pi tool fm_watch_arm_pi, or restart Pi with -e /Users/kunchen/.no-mistakes/worktrees/016d88035d58/01M17Z91T3MH4GB7K74ZS94ZKB/.pi/extensions/fm-primary-turnend-guard.ts -e /Users/kunchen/.no-mistakes/worktrees/016d88035d58/01M17Z91T3MH4GB7K74ZS94ZKB/.pi/extensions/fm-primary-pi-watch.ts if the extensions are not loaded.
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
promoted demo-promoted to ship mode=no-mistakes yolo=off (teardown protection restored)
wrote ship instructions for mode=no-mistakes: /Users/kunchen/.no-mistakes/evidence/01M17Z91T3MH4GB7K74ZS94ZKB/manual-home/data/demo-promoted/ship-instructions.md
next: FM_HOME=/Users/kunchen/.no-mistakes/evidence/01M17Z91T3MH4GB7K74ZS94ZKB/manual-home bin/fm-send.sh fm-demo-promoted "$(cat /Users/kunchen/.no-mistakes/evidence/01M17Z91T3MH4GB7K74ZS94ZKB/manual-home/data/demo-promoted/ship-instructions.md)"
delivered to fm-demo-promoted (3253 bytes)
```

## Delivered promoted-worker contract (key lines)

```text
Your scout task has been promoted to a ship task, mode=no-mistakes. Your window, worktree, and context stay as they are; only the contract below changes.
6. These ship instructions supersede the scout delivery rules and report-based Definition of done. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule.
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
- NEVER pass `--yes` (or `-y`) to `no-mistakes axi run` or `no-mistakes axi respond`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.
```

## Ordinary brief mode contracts

### no-mistakes

```text
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append `done: {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make `--intent` preserve all relevant content from this brief's `# Task` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies `ask-user-authority` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass `--yes` (or `-y`) to `no-mistakes axi run` or `no-mistakes axi respond`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append `done: PR {url} checks green` and stop. You are finished.
```

### direct-PR

```text
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with `gh-axi`, then append `done: PR {url}` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
```

### local-only

```text
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch `fm/ordinary-local`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if `main` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append `done: ready in branch fm/ordinary-local` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local `main` through the guarded fast-forward path.
```
