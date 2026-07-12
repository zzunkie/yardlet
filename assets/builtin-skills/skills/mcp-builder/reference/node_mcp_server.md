# TypeScript MCP Server Guide

## Structure

Keep protocol registration, service access, schemas, and tests separate:

```text
src/server.ts
src/tools/
src/service/
tests/
```

## Tool Pattern

Define a strict schema, map it to a small service method, and return stable
structured content. Keep service construction injectable so tests can use a
local fake without network or credentials.

```typescript
type LookupInput = { id: string };
type LookupResult = { id: string; title: string };

export async function lookup(
  input: LookupInput,
  service: { lookup(id: string): Promise<LookupResult> },
): Promise<LookupResult> {
  if (!input.id.trim()) throw new Error("id is required");
  return service.lookup(input.id);
}
```

## Validation

Run the repository's formatter, type checker, unit tests, and local transport
test. Cover invalid input, service errors, empty results, and cancellation.
Dependency installation or current upstream documentation lookup is a separate
network-gated prerequisite when not already available.
