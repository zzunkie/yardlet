# Plan Document Review Task Template

Use this template when creating a Yardlet task with `kind: review` for an
implementation plan.

## Inputs

- Plan: `[PLAN_PATH_OR_TEXT]`
- Intent contract: `[INTENT_PATH]`
- Queue task: `[TASK_ID]`

## Review Contract

Review read-only. Check the plan against the actual intent and task rather than
the author's summary.

1. Map each acceptance criterion to a concrete step and validation command.
2. Flag any file or action outside allowed scope.
3. Check dependency order and interface names for consistency.
4. Find vague placeholders, missing failure cases, and unverifiable outcomes.
5. Return findings by severity with exact plan references.

## Output

- `pass`: all criteria are covered and no blocking scope or correctness gap exists.
- `fail`: list each blocking gap, why it matters, and the bounded correction.

Do not implement the plan or mutate repository state during this review.
