# Yardlet Code Review Task Template

## What Was Implemented

[DESCRIPTION]

## Requirements

[PLAN_OR_REQUIREMENTS]

## Evidence Range

[CHANGED_FILES_OR_LOCAL_REVISION_RANGE]

## Review Rules

Review the actual workspace read-only. Do not mutate the working tree, index,
branch, canonical `.agents/` state, or external systems.

Check:

- requirement and scope alignment;
- correctness, edge cases, and backward compatibility;
- security and data-loss risks;
- test quality and fresh validation output;
- documentation and operational completeness where required.

## Output Format

For every acceptance criterion, return:

- criterion identifier;
- `pass` or `fail`;
- exact evidence;
- residual risk;
- bounded remediation when failed.

Then summarize findings as Critical, Important, and Minor, followed by an
overall `ready` or `not ready` assessment. Do not pass a criterion that was not
verified against the actual workspace.
