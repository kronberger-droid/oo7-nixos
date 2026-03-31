---
name: Use cargo add for dependencies
description: Always use `cargo add` instead of manually editing Cargo.toml for adding dependencies — ensures latest versions from crates.io
type: feedback
---

Use `cargo add` to add Rust dependencies instead of manually editing Cargo.toml.

**Why:** Manual version pinning means guessing versions that may not exist or be outdated. `cargo add` resolves the latest from crates.io automatically.

**How to apply:** When setting up a Rust project or adding dependencies, run `cargo add <crate>` (with `--features` as needed) instead of editing `[dependencies]` by hand.
