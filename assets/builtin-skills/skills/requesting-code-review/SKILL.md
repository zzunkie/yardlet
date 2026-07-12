---
name: requesting-code-review
description: Use after meaningful implementation work to create an independent Yardlet review task
---

# Requesting Code Review

## Purpose

Turn review into an explicit Yardlet queue item with bounded inputs and a
structured verdict. Review is independent work, not an implicit hidden action.

## When to Request

Request review after a meaningful implementation slice, before integration, or
when the task contract explicitly requires independent acceptance review.

## Prepare Evidence

Record:

- what was implemented;
- the governing intent, task, or specification;
- the exact changed files or local revision range;
- validation commands already run and their results;
- unresolved risks or assumptions.

Do not claim that the implementation is correct. The review task owns that
judgment.

## Create the Review Task

Create or propose a normal Yardlet queue task with `kind: review`. Keep its
allowed scope read-only unless the contract explicitly creates a separate
repair task. Use [code-reviewer.md](code-reviewer.md) as the review body.

The review must return one verdict per acceptance criterion with concrete file,
command, or runtime evidence. A failed criterion remains failed until a later
repair task changes the workspace and review is rerun.

## Act on Findings

- Repair critical and important findings in a bounded implementation task.
- Challenge an incorrect finding with code or test evidence.
- Keep optional polish separate from blocking acceptance.
- Never mark the reviewed task complete solely because the implementer reports success.
