Your scout task has been promoted to a ship task, mode=local-only. Your window, worktree, and context stay as they are; only the contract below changes.

# Ship instructions
1. Inventory this worktree's scratch state with `git status` and `git log` before changing anything.
2. Return to a clean default-branch base, then create your branch: `git checkout -b fm/evidence-local-only`.
3. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
4. If you reproduced a bug, turn that reproduction into a regression test.
5. These ship instructions supersede the scout delivery rules and report-based Definition of done. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; the worktree isolation assertion; and every safety rule.

# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch `fm/evidence-local-only`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if `main` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append `done: ready in branch fm/evidence-local-only` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local `main` through the guarded fast-forward path.
