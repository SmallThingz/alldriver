# Contributing

Use Zig **0.16.0**, Git, and an installed Brave browser for the required Chromium integration gate.

```sh
zig build
zig build test
zig build examples
zig build test-chromium
```

Keep changes scoped and commit coherent steps using conventional commit prefixes such as `fix:`, `feat:`, and `refactor:`. Preserve typed failures and allocator ownership. Never replace a failed protocol action with invented success or placeholder output.

Tests must establish observable behavior. Unit tests should cover parsing, ownership, malformed inputs, and allocation failures where relevant. Browser changes require real fixture assertions: default actions and trusted events for input, actual pixels/formats for screenshots, complete trace data, persistent storage, and downloaded file contents. Include lifecycle, concurrent completion, and failure cases. The Chromium gate fails on a missing browser; do not convert that failure into a skip to make a release pass.

Chromium/CDP is the current supported scope. Firefox/BiDi and other engines remain deferred. Compiling a target, discovering a browser, or exercising a mocked protocol is not runtime qualification. Report the actual platform/browser and distinguish unit, compile, and real-browser results.

Build all examples after API changes. For package changes, verify a clean exported package includes every path referenced by `build.zig` and can build independently of the checkout.

Keep [README.md](README.md) concise and [DOCUMENTATION.md](DOCUMENTATION.md) accurate. Use relative repository links. PR descriptions should briefly state what changed.
