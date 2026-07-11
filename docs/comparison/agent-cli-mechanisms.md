# Agent CLI mechanisms and Yardlet

Agent CLIs and Yardlet operate at different layers. An agent CLI supplies the
generative worker process. Yardlet supplies a local, worker-neutral loop around
that process.

| Mechanism | Agent CLI | Yardlet |
|---|---|---|
| Model and tools | Chooses a model and exposes its own tools | Reuses the installed CLI without embedding its tools in the core |
| Work input | Accepts a prompt or session context | Compiles a packet from intent, scope, acceptance, rules, skills, and prior evidence |
| Execution | Generates or judges work | Routes an interchangeable worker process behind one packet-to-result contract |
| Completion | Reports the worker or session outcome | Applies deterministic checks before changing canonical task state |
| Recovery | May resume its own session | Reconstructs work from repository-owned runs, checkpoints, conversations, and transitions |
| Memory | Usually scoped to a product or session | Keeps open-format project memory and an index under `.agents/` |
| Billing | Follows the CLI's configured account | Adds no provider account and scrubs billing variables unless a profile opts them in |

This division is deliberate. Yardlet does not claim to improve a model's code
generation, replace its tools, or reproduce its session UX. The core compiles,
routes, checks, records, and recovers. Generative work remains behind the worker
contract, and canonical `.agents/` state remains under the deterministic core's
control.

The practical result is portability. A worker can change without changing the
intent contract, queue, evidence format, or project memory. That portability is
the guarantee. Equivalent output quality across workers is not.

See [identity.md](../identity.md) and [absorption.md](../absorption.md) for the
invariants behind this boundary.
