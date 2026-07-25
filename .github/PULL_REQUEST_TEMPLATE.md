# Pull Request

## What changed

<!-- Describe the problem and the user-visible effect of this change. -->

## Related issue

<!--
Link the agreed issue for features, public contracts, architecture, or security
boundary changes. Use "Not required" for an issue-optional small fix.
-->

## Validation

<!-- List the exact commands you ran and their results. -->

- [ ] `cargo fmt --check`
- [ ] `cargo clippy --all-targets -- -D warnings`
- [ ] `cargo build --all-targets`
- [ ] `cargo test`
- [ ] `cargo +1.82.0 check --locked`

## Evidence

<!-- Add screenshots or terminal captures for visible TUI/output changes. -->

## Scope and safety

- [ ] The pull request solves one bounded problem.
- [ ] Behavior changes include tests.
- [ ] Public commands, output, configuration, or contracts have updated docs.
- [ ] I did not include secrets, personal paths, or generated run artifacts.
- [ ] I did not hand-edit Yardlet-owned canonical `.agents/` state.
- [ ] I have the right to submit this work under the repository's MIT License.
