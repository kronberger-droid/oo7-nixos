---
name: Use rust-overlay only, not fenix
description: For Rust Nix flakes, use only oxalica/rust-overlay — fenix is redundant
type: feedback
---

Only use `oxalica/rust-overlay` for Rust toolchains in Nix flakes. Do not include fenix.

**Why:** rust-overlay handles everything needed (stable/nightly toolchains, rust-analyzer, extensions). fenix is redundant and adds an unnecessary input.

**How to apply:** When creating Rust flakes, only add `rust-overlay` as an input. Use `pkgs.rust-bin.stable.<version>` for toolchains.
