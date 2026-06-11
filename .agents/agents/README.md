# Role profiles

A Yard task runs under a **role** — a prompt mode over the hidden worker,
derived from the task's `kind`:

| kind | role |
| --- | --- |
| `implementation` (default) | `builder` |
| `review` | `reviewer` |
| `research` | `researcher` |
| `safety` | `security` |

Built-in guidance for each role lives in `src/packet.rs` (`role_guidance`).

To extend a role for this workspace, write `<role>.md` in this directory
(e.g. `reviewer.md`); its content is appended to every packet of that role
under "Workspace role notes". Keep notes short and imperative — they ride in
every matching packet.

These files are harness assets: edit freely. Tool-specific wrappers
(`.claude/`, `.codex/`) should symlink into here rather than fork the text.
