# Python MCP Server Guide

## Structure

Keep protocol registration, service access, models, and tests separate:

```text
server.py
tools/
service/
tests/
```

## Tool Pattern

Validate inputs at the boundary and inject service objects so local tests need
no network or credentials.

```python
from dataclasses import dataclass

@dataclass(frozen=True)
class LookupResult:
    id: str
    title: str

def lookup(item_id: str, service) -> LookupResult:
    if not item_id.strip():
        raise ValueError("item_id is required")
    return service.lookup(item_id)
```

## Validation

Run syntax, type, and unit checks supported by the repository. Cover invalid
input, service errors, empty results, pagination, and cancellation. Dependency
installation or current upstream documentation lookup remains a separate
network-gated prerequisite when not already available.
