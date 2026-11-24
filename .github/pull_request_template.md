<!-- Thanks for the pull request. CONTRIBUTING.md says what helps it get merged. -->

## What changed and why


## How it was checked

- [ ] `swift build --build-system native`
- [ ] `scripts/product-warnings.sh` on the build log: no warnings
- [ ] Relevant `swift test --build-system native --filter …`, or `./scripts/test-fast.sh`
- [ ] User-visible strings added to `en.lproj/Localizable.strings` only
- [ ] For a visible UI change: light and dark screenshots below
- [ ] Relevant `docs/` updated if behavior changed
