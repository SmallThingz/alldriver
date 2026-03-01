# Contributing

## Development Setup

Requirements:

- Zig `0.15.x`
- Git
- Bash (for local command examples)

Clone and validate:

```bash
git clone https://github.com/SmallThingz/alldriver.git
cd alldriver
zig build test
zig build examples
zig build tools -- self-test
```

## Workflow

1. Create a branch with prefix `codex/` or your project branch convention.
2. Keep changes scoped and commit in small logical chunks.
3. Add tests for behavioral changes.
4. Run validation locally before opening PR.

Recommended checks:

```bash
zig build
zig build test
zig build examples
zig build tools -- self-test
```

For release/tooling changes:

```bash
zig build tools -- adversarial-detection-gate --allow-missing-browser=1
zig build production-gate
```

## Coding Guidelines

- Prefer CDP/BiDi modern API paths.
- Preserve typed errors and capability checks (no silent no-op behavior).
- Avoid introducing runtime plugin/dynamic loading patterns.
- Keep docs in sync with code behavior.
- Do not add bot-detection bypass primitives.

## Tests

- Unit tests should be deterministic and isolated.
- Integration/behavioral tests should be opt-in and guard on host/tool availability.
- If adding new tool commands, include parser/contract tests when possible.

## Documentation

- Keep `/home/a/projects/zig/browser_driver/README.md` concise.
- Keep `/home/a/projects/zig/browser_driver/DOCUMENTATION.md` as the canonical detailed doc.

## Pull Requests

PRs should include:

- what changed
- why it changed
- risk/compatibility notes
- exact validation commands run and outcomes
