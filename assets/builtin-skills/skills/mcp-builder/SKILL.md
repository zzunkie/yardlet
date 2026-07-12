---
name: mcp-builder
description: Use when a task explicitly creates or improves an MCP server and needs a safe implementation and evaluation workflow
license: Complete terms in LICENSE.txt
---

# MCP Server Builder

## Activation Boundary

Use this skill only for an MCP server authoring or improvement task. Repository
classification alone does not activate it or grant network, credential, tool,
browser, or external-mutation access.

## Phase 1: Understand and Plan

1. Identify the user workflows the server must support.
2. Read the bundled references before choosing a language or transport.
3. Inventory required upstream documentation. If current external documentation
   is necessary, stop at the existing network opt-in boundary and record the
   exact source and immutable revision to inspect. Never rely on a moving branch.
4. List tool, resource, and prompt surfaces with their read/write effects.
5. Define authentication as an injected runtime boundary. Do not request,
   inspect, persist, or expose credentials while authoring the bundle.

## Phase 2: Implement

- Use clear, action-oriented names and precise input schemas.
- Return focused structured data and actionable errors.
- Mark destructive, idempotent, read-only, and open-world behavior accurately.
- Add pagination or filtering when responses can grow without bound.
- Keep transport and service clients behind small interfaces that can be tested locally.
- Never infer authorization from tool annotations or repository classification.

Language-specific patterns are in:

- [reference/node_mcp_server.md](reference/node_mcp_server.md)
- [reference/python_mcp_server.md](reference/python_mcp_server.md)
- [reference/mcp_best_practices.md](reference/mcp_best_practices.md)

## Phase 3: Review and Test

1. Run local syntax, type, and unit checks.
2. Exercise each tool through an in-process or local test transport.
3. Verify read-only and destructive annotations against actual behavior.
4. Check errors, empty results, pagination, cancellation, and timeouts.
5. Confirm logs and fixtures contain no credential values or private data.

## Phase 4: Evaluate

Follow [reference/evaluation.md](reference/evaluation.md). Evaluations should be
independent, realistic, stable, and locally verifiable. Any live external
service evaluation is a separate gated task, not a default step in this skill.

## Completion

Report the implemented surfaces, effect classification, local validation, and
remaining gated dependencies. Do not claim live interoperability unless it was
explicitly authorized and freshly verified.
