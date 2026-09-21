---
name: prompt-trace-iteration
description: >-
  Agent-only procedure for changing an LLM prompt to fix or add an agent conversational behavior.
  Use when editing or debugging a system prompt, workflow template, or tool guideline that shapes how a model responds.
  Owns production-trace grounding, negative-baseline reproduction, the minimal byte-diff principle, empirical multi-sample iteration, side-effect and counter-example guards, and the evidence artifact.
user-invocable: false
metadata:
  internal: true
---

# prompt-trace-iteration

Use this procedure whenever a change to an LLM prompt is meant to fix or add an agent conversational behavior.
A prompt is code whose compiler is a model, so treat a prompt change like any other behavior change: reproduce the current behavior, change the smallest thing that flips it, and prove the flip empirically.
Never ship a prompt edit justified only by reading it and reasoning that it should work.

## Ground the target in a production trace

Start from a real failure, not an imagined one.
Pull the actual trace that shows the wrong behavior: a Langfuse trace, a call log, or a real transcript from the provider in production.
Extract the exact context the model saw at the target turn: the full system prompt, the tool and function definitions, the model and provider identity and its sampling parameters, and the prior turn history up to that turn.
Preserve that context verbatim, including whitespace and ordering, because a paraphrase reproduces a different prompt than the one that failed.
If no production trace exists, say so and build the closest faithful context by hand, without presenting it as equivalent evidence.

## Reproduce the negative baseline

Re-run the extracted context against the same model and provider used in production before changing anything.
Confirm the wrong behavior appears, and record that failure as the starting proof.
Sample the baseline several times, because a behavior that already varies run to run changes what "fixed" has to mean.
If the baseline will not reproduce the reported failure, stop and resolve that gap first: an unreproduced behavior cannot be verified as fixed.

## Find the minimal byte diff

Change the fewest bytes that could plausibly flip the behavior, targeted strictly at the relevant step, instruction, or tool description.
Prefer editing an existing sentence over adding one, and adding one precise clause over adding a paragraph.
Refuse bloated prose, speculative essays, restated context, and multi-paragraph reminders: each added token is paid on every future call and dilutes the instructions already there.
When several diffs are candidates, test the smallest first and enlarge only when the smaller one fails empirically, never preemptively.

## Iterate empirically

Run the modified context against the same model and provider across multiple samples, not once.
A single passing sample is anecdote; require the change to flip the behavior to the desired outcome reliably across the sample set.
When a diff fails, adjust the wording or placement and re-run rather than piling on more text, and keep returning to the smallest form that still works.
Hold the model, provider, sampling parameters, and surrounding context fixed across baseline and candidate runs so the diff is the only variable.

## Guard against side effects

A prompt edit is a global change to a shared instruction surface, so prove it did no collateral damage.
Re-run adjacent turns and unaffected traces to confirm the change did not cause hallucinations, over-triggering of the new behavior, or regressions where the old behavior was already correct.
Construct counter-examples: inputs that should NOT trigger the new behavior, and confirm the model still declines them.
If the fix helps the target turn but breaks a neighbor, the diff is wrong; narrow its scope or its trigger condition until both hold.

## Record the evidence

Document the exact byte diff of the prompt change and the side-by-side model outputs in a compact evidence report.
Include the model, provider, sampling parameters, sample counts, the baseline failure rate, and the post-change success rate on both the target turn and the counter-examples.
Keep the report proportional to the change: the diff, the before/after outputs, and the numbers, not a narrative.
This evidence, not the prose of the new prompt, is what justifies the change.
