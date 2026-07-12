# MCP Best Practices

## Design from Workflows

Model tools around complete user actions rather than mirroring every service
endpoint. Keep names action-oriented and descriptions explicit about side
effects, prerequisites, and returned data.

## Schemas

Use bounded inputs, enums where values are finite, and field descriptions that
state units and formats. Return structured content when clients benefit from
stable fields. Keep human-readable text concise.

## Effects and Authorization

Accurately label read-only, destructive, idempotent, and open-world behavior.
Annotations describe behavior; they never authorize it. Runtime credentials and
external writes stay behind the host's existing gates.

## Errors

Errors should say what failed, whether retry is safe, and what the caller can
change. Do not include credential values, private payloads, or stack traces that
expose environment details.

## Result Size

Provide filtering, pagination, and stable cursors for large result sets. Return
only the fields needed for the workflow and make truncation visible.

## Testing

Test schemas, effect annotations, pagination, error mapping, cancellation, and
timeouts through local fixtures or test transports before any gated live check.
