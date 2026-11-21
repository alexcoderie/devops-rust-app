# Instructions for AI agents

This repository is a Rust web application (axum) deployed to Fly.io. Work is
done through tickets (GitHub issues) and pull requests. A human decides only
three things: deploying to production, spending above the cap, and destructive
changes to data. Everything else goes through the pipeline.

## Layout

- `src/main.rs`: binary entry point (logging, port, graceful shutdown)
- `src/router/`: the library crate `router` (all routes live here, so they can be tested)
- `tests/`: integration tests that call the router directly
- `.github/workflows/`: CI and deploy. **Do not edit.**

## Commands (run all three before opening a pull request)

```sh
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
```

Always pass `--locked`. Never edit `Cargo.lock` by hand.

## Rules

- Do exactly what the ticket asks, nothing more. Keep the pull request small.
- Reference the ticket in the pull request description with `Closes #<number>`.
- Every change needs tests, including failure and abuse cases (bad input, missing input).
- Do not modify `.github/`, `deny.toml`, `rust-toolchain.toml`, `Dockerfile` or
  `fly.toml` unless the ticket explicitly says so. If a check fails and the
  "fix" would be weakening a check, stop and say so in the pull request instead.
- Do not add or upgrade a dependency unless the ticket asks for it. State why in
  the pull request. `cargo deny check` must keep passing.
- Never put secrets, tokens, passwords or real personal data in code, tests,
  logs, comments, commit messages or prompts. Read them from environment variables.
- Do not use `unwrap()` or `expect()` in request-handling code. Return a proper
  HTTP error instead. (`expect` at startup in `main.rs` is fine.)
- Validate and bound all external input. Never build SQL by string concatenation.
- If a ticket involves destructive data changes, spending, or deploying, stop and
  ask a human.

## Style

- Format with `cargo fmt`, no warnings from clippy.
- Prefer small functions and explicit types at module boundaries.
- Log with the `tracing` macros, never `println!`. Do not log secrets or personal data.
