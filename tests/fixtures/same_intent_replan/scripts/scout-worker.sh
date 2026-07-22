#!/usr/bin/env bash
set -euo pipefail

run_dir="${1:?scout fixture requires run directory}"
access="${2:-}"
packet="$(cat)"
mkdir -p "$run_dir"

[[ "$access" == "sandboxed" ]] || {
  printf 'scout fixture did not receive its sandbox contract\n' >&2
  exit 65
}

printf '%s\n' "$packet" >"$run_dir/scout-packet-captured.md"

python3 - "$run_dir" <<'PY'
import json
import pathlib
import re
import sys

run_dir = pathlib.Path(sys.argv[1])
packet = (run_dir / "scout-packet-captured.md").read_text(encoding="utf-8")

def field(name):
    match = re.search(rf"^{re.escape(name)}: (.+)$", packet, re.MULTILINE)
    if not match:
        raise SystemExit(f"missing scout packet field: {name}")
    return match.group(1).strip()

topics_section = packet.split("## Topics", 1)[1]
topics = []
for line in topics_section.splitlines():
    if line.startswith("- "):
        topics.append(" ".join(line[2:].split()).lower())

results = [
    {
        "topic": topic,
        "sources_consulted": ["workspace_skill_catalog", "user_skill_library"],
        "disposition": "record_tool_candidate",
        "gap": {
            "kind": "tool_or_resource",
            "missing_capabilities": ["deterministic_replan_probe"],
        },
    }
    for topic in topics
]

output = {
    "schema_version": 1,
    "intent_id": field("intent_id"),
    "request_digest": field("request_digest"),
    "cycle": 1,
    "results": results,
}
(run_dir / "scout-result.json").write_text(
    json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
PY
printf 'scouted replan fixture topics\n'
