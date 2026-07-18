---
name: writing-plans
description: Use when a bounded Yardlet task needs a concrete implementation plan before code changes
---

# Writing Task-Internal Plans

## Purpose

Turn one accepted Yardlet task into a small, testable implementation plan. The
intent contract and work queue already own project-level decomposition. Do not
replace them, expand the task, or create a second queue.

## Scope First

1. Read the task's allowed scope, exclusions, acceptance criteria, and anchors.
2. List the files and interfaces likely to change.
3. Stop and report a blocker if acceptance requires work outside the contract.
4. Put adjacent ideas in the handoff or follow-up candidates, never into the
   active implementation plan.

## Plan Shape

Write the plan in the worker's normal progress channel unless the task requires
a durable plan file. Each step must contain:

- one independently checkable outcome;
- exact files or interfaces involved;
- the narrow validation that proves the step;
- dependencies on earlier steps;
- any safety or no-clobber constraint that applies.

Prefer the smallest useful sequence:

1. Add or identify a failing check for the required behavior.
2. Make the minimal implementation change.
3. Run the narrow check.
4. Run the relevant regression suite.
5. Compare the actual result with every acceptance criterion.

## Concrete Detail

A useful plan names real paths, types, commands, and expected results. Avoid
placeholders such as `TODO`, "handle edge cases", or "add tests" without naming
the behavior and proof. Follow existing repository patterns and avoid unrelated
refactors.

## Review Boundary

Use [plan-document-reviewer-prompt.md](plan-document-reviewer-prompt.md) to
check the completed plan against the task contract. If independent review is
required, represent it as a normal Yardlet queue task with `kind: review`; do
not invent another execution mechanism.

## Completion Checklist

- [ ] Every acceptance criterion maps to at least one plan step and validation.
- [ ] Every changed file is inside allowed scope.
- [ ] The plan does not duplicate project-level queue decomposition.
- [ ] Commands are concrete and expected outcomes are stated.
- [ ] Out-of-scope ideas remain outside the implementation steps.
