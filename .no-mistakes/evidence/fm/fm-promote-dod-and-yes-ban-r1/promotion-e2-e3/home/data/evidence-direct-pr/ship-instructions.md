Your scout task has been promoted to a ship task, mode=direct-PR. Your window, worktree, and context stay as they are; only the contract below changes.

# Ship instructions
1. Inventory this worktree's scratch state with `git status` and `git log` before changing anything.
2. Return to a clean default-branch base, then create your branch: `git checkout -b fm/evidence-direct-pr`.
3. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
4. If you reproduced a bug, turn that reproduction into a regression test.
5. These ship instructions supersede the scout delivery rules and report-based Definition of done. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; the worktree isolation assertion; and every safety rule.

# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with `gh-axi`, then append `done: PR {url}` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
