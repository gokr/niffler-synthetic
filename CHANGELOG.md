# Changelog

All notable changes to `niffler-synthetic` are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
`niffler.json`'s `version` is the version a `plugin_install` pins to when it
resolves a release tag.

## [Unreleased]

## [0.3.0] — 2026-10-21

### Changed

- **The Synthetic credential comes from the harness's `synthetic` provider
  record.** The component previously authenticated only from
  `SYNTHETIC_API_KEY` or opencode's key store, so a harness that already had a
  `synthetic` provider — the normal setup, since `llm` routes through it —
  still reported "no Synthetic API key" and every tool failed. The same
  credential was required twice, in two places.

  Resolution order is now `SYNTHETIC_API_KEY` (an explicit override) and then
  the stored provider record named `synthetic`, read over the bus with
  `provider_get` — the same registry lookup `llm` uses. The registry is
  consumed through the wire contract (a component request), never by importing
  another component's code. (`#1`)

### Removed

- **opencode's credential store is no longer consulted.** It was a fallback
  into *another tool's* state: that couples this plugin to software it does not
  own, and on a box where that tool happened to be configured the component
  would silently authenticate with a credential nobody chose for this harness.
  A Niffler component resolves credentials from Niffler (env, then the provider
  registry).

### Fixed

- The `selftest` `api-key` check names **which** source answered (environment
  vs provider record) without ever printing the value, so an operator knows
  whether to fix the store or the box.

### Notes for maintainers

- `provider_get` answers `{ok, provider: {...}, source}` — the config is
  **nested**. Reading `apiKey` off the top level silently yields `""` and looks
  exactly like "no provider stored". The lookup accepts either shape.
- Until this release the repository published no tags or releases, so
  `plugin_install` fell back to the default branch. Releases are what let an
  install pin a version; future changes should bump `niffler.json` and tag.

## [0.2.0]

Prior to the changelog being kept: usage/quota tracking with the `/synthetic`
slash command, live model catalog, zero-data-retention web search, `chat`,
token counting and the `models` catalog source plugin.
