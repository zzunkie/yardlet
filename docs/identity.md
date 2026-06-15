# Identity — what Yard is, in one place

> **Rent the intelligence. Own the work.**
> (지능은 빌리고, 작업은 소유한다.)

Yard is a local console for **engineering the loop** that turns a few
sentences of intent into verified, durable work — using your
already-installed coding agents as interchangeable workers.

## The four layers

**1. Deterministic core, generative behind the contract.**
The orchestrator does only deterministic, auditable operations — compiling
packets from state, routing by rules, evaluating by checks, merging by git,
running hooks. Anything that *generates or judges* work goes through the
worker contract: packet in → process → result files out. A Yard-shipped
worker (a native API adapter, someday) is identity-compatible exactly when
it sits behind that same contract, routable like any other worker.

**2. Containerized work.**
The shipping container didn't make ships faster; it standardized the unit of
cargo so that *logistics* became possible — any ship, any crane, any port.
The packet/result contract is that container spec for delegated cognitive
work. Routing, parallel worktrees, recovery, adoption, audit, handoff: all
of Yard's features are the logistics that a standard unit makes possible.
A *yard* is literally where containers wait, get inspected, and get assigned
to carriers.

**3. Verification is the scarce good.**
Worker capability churns — the best model changes every few months, and
Yard gets *stronger* when workers improve, because its product is not
generation. As generation gets cheap, the binding constraint becomes: can
you trust, verify, and account for what an agent did while you weren't
looking? The evaluator, the gates (ambiguity, approval, hooks), human
promotion, and the audit trail are not safety chrome. They are the product.

**4. User-owned, compounding capital.**
Work done in a chat session belongs to no one — it evaporates. Yard keeps
the records, rules, skills, telemetry, and handoffs in `.agents/`, in your
repo, in open formats, portable across workers. That asset *appreciates*:
telemetry improves routing, handoffs become organizational memory, promoted
lessons strengthen every future packet. Capability depreciates;
accountability compounds. Yard sits on the compounding side.

## The moment this lands in: loop engineering

In mid-2026 the discourse caught up with the shape of this product. Boris
Cherny (Anthropic, Claude Code lead): *"I don't prompt Claude anymore. I have
loops running that prompt Claude and figure out what to do. My job is to
write loops."* Addy Osmani then named the practice **loop engineering**:
"you stop being the person who prompts the agent and start being the person
who designs the system that prompts it" — spec → execute → **verify** →
iterate, with the verifier deliberately separated from the doer.

Yard is that practice as a product, with one addition the vendor loop
primitives (claude `/loop`/`/goal`, codex Automations) don't give you:
**the loop is yours.** It is worker-neutral (any CLI behind one contract),
local (state in your repo, not a vendor session), verified by parties other
than the doer (deterministic evaluator + reviewer-role tasks), and it
compounds (every cycle can strengthen the harness all future cycles ride).
Vendor loops run inside one vendor's walls; Yard is the loop you own across
all of them.

## The practice this enables

- **You don't write prompts — packets are compiled.** Intent contract +
  rules + skill catalog + role discipline + checkpoint are the source;
  every worker prompt is a build artifact. Improving the loop's inputs
  improves every future prompt without anyone writing one.
- **You don't babysit sessions — you engineer the loop.** What enters the
  context (harness), what blocks passage (gates), what survives a cycle
  (checkpoints), what compounds across cycles (learning loop): those are
  the knobs. The loop runs rented labor; you own the loop.

## One-line forms

- Tagline: **Rent the intelligence. Own the work.**
- Mechanism: *Prompts are compiled, not written.*
- Positioning: *Workers race on capability; Yard races on nothing-gets-lost.*
- Metaphor: *The container yard for AI labor.*

## What this rules out

No magic keywords or hidden modes (contracts are explicit artifacts). No
worker-grade tool surfaces in the core (owning them pulls the console into
the judgment loop). The harness self-improves — skills and learned rules are
written and pruned automatically — but the deterministic core is the sole
writer (workers propose, Yard records) and an eval loop self-corrects, so
the human steps back instead of approving each change; gates are reserved for
the irreversible or outward-facing (push, deploy, secrets). No vendor lock-in
of the user's capital (open formats, read-only discovery of existing assets).
See [absorption.md](absorption.md) for the full invariants.
