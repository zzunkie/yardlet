# v0.9 launch copy draft

> Draft only. This file is not a release announcement and has not been posted.

## Short version

Yardlet is a local terminal workbench that turns a goal into a bounded task
queue, runs your installed coding-agent CLIs as interchangeable workers, and
keeps the contract, evidence, recovery state, and project memory in your repo.

The v0.9 engineering loop adds explicit goal conditions with bounded feedback,
read-only memory scouts with a separate core apply step, a foreground bounded
`yardlet watch`, deterministic mechanism fixtures, and a TUI Answer view that
puts the question beside the worker output and conversation that caused it.

## Longer version

Coding agents are increasingly capable, but a capable session is not yet an
owned engineering loop. Yardlet keeps the loop outside any one worker: intent,
scope, acceptance, queue state, evidence, retries, questions, and handoffs live
in open files under `.agents/`.

In v0.9, failed deterministic checks can be fed into the next attempt until the
task's explicit feedback limit is reached. At that boundary Yardlet stops with
a recorded question instead of claiming success. Memory scouts inspect isolated
copies and produce candidates; only a separate Yardlet core action updates
canonical memory. `yardlet watch` observes a local command or path in the
foreground with time and run limits. `yardlet eval fixtures` proves core
mechanisms locally without calling a model provider.

Yardlet does not rank models or replace agent tools. It rents the intelligence
already available through your CLIs and keeps the work, evidence, and learning
loop in your repository.

## Release checklist excluded from this draft

- Version bump and tag
- Package or GitHub release
- External post or message
- Claims beyond locally verified mechanisms
