# Local MCP Evaluation Guide

## Goal

Measure whether the server's declared tools let a client complete realistic
workflows correctly. Default evaluation is local, deterministic, and read-only.

## Build the Set

1. Inventory the implemented tools and their effects.
2. Create ten independent questions or actions from local fixtures.
3. Include multi-step cases, empty results, invalid input, and pagination.
4. Give every case one stable expected result.
5. Keep fixtures free of private or credential-bearing data.

## Run

Use the repository's normal test runner and a local or in-process transport.
Record the exact command, versioned fixture, actual output, and pass/fail result.
Do not call a provider or live external service as part of the default evaluation.

## Judge

A case passes only when the observed structured result matches the expected
result and no undeclared side effect occurred. Summarize failures by tool and
root cause, then rerun the full local set after repairs.

## Live Checks

If acceptance explicitly requires a live service, split it into a separately
authorized task with its own network, credential, billing, and mutation gates.
Local evaluation results must remain understandable without that live check.
