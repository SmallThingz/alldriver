# alldriver API

`alldriver` requires Zig 0.16.0. The supported browser scope is Chromium over CDP. The required real-browser suite targets Brave; Chrome and Edge use the same Chromium protocol surface, but a Brave run does not independently certify every browser/version/OS combination.

Firefox and other Gecko browsers, BiDi, Safari/WebKit, Lightpanda, and platform-specific webviews are outside the currently validated scope. Their discovery entries or existing APIs are not support guarantees.

## Sessions and ownership

Use `driver.modern.launch`, `launchAuto`, or `attach`. Launch and attach return after protocol readiness. `launchAuto` discovers installed browsers; explicitly choose Chromium kinds such as `.brave`, `.chrome`, and `.edge`.

Call `session.deinit()` once. Ephemeral profiles are removed on teardown; persistent profiles require `profile_dir` and retain their data. Discovery returns an owned list with its own `deinit()`.

Domain clients (`page`, `runtime`, `network`, `input`, `log`, `storage`, `contexts`, `targets`) borrow their session. Keep the session alive while using them. Buffers returned by evaluation, screenshots, and tracing are owned by the allocator supplied to that API and must be freed. Evaluation returns the protocol response payload, including the remote result, rather than a decoded application value.

## Navigation and input

`page.navigate`, `reload`, `goBack`, and `goForward` use Chromium navigation. `setViewport(width, height)` configures device metrics; zero dimensions are invalid.

`input.click(selector)` scrolls the target into view, checks hit-testing, and dispatches native mouse input. Missing, disabled, hidden, or occluded targets fail explicitly. `input.typeText(selector, text)` replaces existing editable content using native selection and text insertion, including contenteditable elements. Empty text clears the selection. Read-only and noneditable targets are rejected.

`keyDown` and `keyUp` send trusted Chromium keyboard events. Supported mappings include ordinary text, Unicode scalars, editing/navigation keys, modifiers, and F1–F12. Modifier state survives repeated `session.input()` calls. Pair modifier presses with releases. `mouseMove(x, y)` uses viewport coordinates; `wheel(dx, dy)` scrolls at the last pointer position. These operations use browser input, so normal default actions and page handlers apply.

## Waits, async work, and cancellation

`waitFor(target, options)` supports `dom_ready`, `network_idle`, `selector_visible`, `url_contains`, `cookie_present`, `storage_key_present`, and `js_truthy`. `waitForCookie` is a convenience wrapper. Set `timeout_ms`, `poll_interval_ms`, and an optional `CancelToken` in wait options.

Async operations return an owned handle. Call `await(timeout_ms)` to obtain the result, then `deinit()` to join and release the handle. A successful result can be consumed only once; a second successful-result await returns `AlreadyConsumed`. An await timeout does not cancel the work.

- `isCancelable()` reports whether pending work supports cooperative cancellation.
- `requestCancel()` returns whether its cancellation request was accepted.
- `cancel()` retains its void API; for work without a cancellation callback it does nothing.
- Acceptance does not mean the worker has exited. `deinit()` still joins it.
- Unconsumed owned results are released by the handle. A successful await transfers result ownership to the caller, who must free a byte buffer or deinitialize a returned session.

Wait operations support cooperative cancellation. Navigation, evaluation, input, and artifact operations must finish or fail normally; requesting cancellation does not falsely report that their browser-side effects stopped.

## Screenshots and tracing

`session.screenshot(allocator, .png)` and `.jpeg` return the requested image bytes from Chromium. Capture errors propagate; no placeholder image or alternate-format fallback is returned.

For tracing, call `session.base.startTracing()`, perform the work, and call `session.base.stopTracing(allocator)`. Async equivalents are also available. Stop waits for Chromium's completion event, reads the entire trace stream, closes it, and returns JSON containing `traceEvents`. It does not return the `Tracing.end` acknowledgement. Malformed data, protocol errors, data loss, timeouts, and the 256 MiB collection limit are reported as errors.

## Network callbacks

Register `network.onRequest` and `network.onResponse`, then call `try network.enable()` to start delivery. `try network.subscribe(callback)` registers raw CDP network events and starts observation directly. Events arrive on a dedicated worker even while the caller is idle. `clearRequest`, `clearResponse`, and `unsubscribe` remove the corresponding callback; `disable` stops observation and interception.

Callback strings are borrowed until the callback returns. Synchronize application state shared with callbacks. A callback may unregister itself, but session destruction, target switching, and observer shutdown must run on the owning thread after callbacks return.

## Console and exception callbacks

```zig
var logs = session.log();
try logs.onConsole(onConsole);
try logs.onException(onException);
// Later:
logs.clearConsole();
logs.clearException();
```

Callbacks receive `LogEntry { level, text, source }` from a dedicated observer, including events that arrive while no session command is running. They execute on the observer worker. Strings are borrowed only for the duration of the callback; copy any retained text and synchronize shared application state.

A callback may unsubscribe itself. Clearing a subscription does not revoke a callback already selected for delivery. **Do not destroy the session from one of its own callbacks**: teardown joins the observer. Arrange teardown on the owning thread after the callback returns.

## Downloads

Configure a caller-owned directory before starting downloads:

```zig
try session.setDownloadDirectory("downloads");
var input = session.input();
try input.click("a.download");

const items = try session.listDownloads(allocator);
defer session.freeDownloads(allocator, items);
for (items) |item| {
    // suggested_filename: the server/browser suggestion
    // save_path: actual GUID-named destination
    // completed: Chromium reported completion
    // canceled: Chromium reported cancellation
    _ = item;
}
```

The browser uses GUID filenames to avoid collisions. `suggested_filename` is metadata, not the saved basename. Poll fresh snapshots until the desired item is completed or canceled. Download events are consumed by a dedicated worker even while the session is idle. Each snapshot owns its array and strings; release all of them through `freeDownloads`.

Before configuration, listing returns `DownloadDirectoryNotConfigured`. Reader/protocol failures are returned rather than disguised as empty results. A directory change replaces the tracker and starts a new list. Teardown restores browser download defaults and leaves downloaded files in place. This configures Chromium's default browser context; use an isolated browser/profile when sharing download policy would be undesirable.

## Storage and session cache

The storage client provides cookies, local/session storage, typed cookie queries, and `buildCookieHeaderForUrl`. Cookie changes emit `cookie_updated` after successful writes.

`SessionCacheStore` provides `open`, `load`, `save`, `saveWithOptions`, `invalidate`, and `cleanupExpired`. Presets are `.minimal` (cookies), `.http_session` (cookies and user agent), and `.rich_state` (cookies, user agent, storage, URL, and extra headers). `SessionCachePayloadMask` selects individual payloads. Cache persistence is not a full browser-profile snapshot.

## Network and lifecycle events

The network client supports request/response callbacks, interception rules, `records(allocator, include_bodies)`, `frames`, `serviceWorkers`, and navigation snapshots. Body inclusion attempts protocol retrieval and depends on the browser retaining the response. Snapshot capture includes DOM HTML, headers, cookies, and web storage.

`onEvent(filter, callback)` returns a subscription ID removed by `offEvent(id)`. Event kinds cover navigation/reload, waits, actions, network observations, challenge heuristics, and cookie changes. Empty `filter.kinds` selects all kinds. Domain filters match exact hosts or subdomains case-insensitively; events without a domain are not domain-filtered. Failure and cancellation are separate from successful completion.

Lifecycle subscriptions and telemetry consume protocol notifications during session commands. For network delivery while the caller is idle, use the dedicated request/response or raw network callbacks described above.

Use `setTimeoutPolicy`, `timeoutPolicy`, and `lastDiagnostic` for operation policy and failures. `driver.modern.setHardErrorLogger` replaces the default diagnostic sink. The library does not provide detection-bypass or challenge-solving primitives.

## Discovery and deferred surfaces

Discovery searches explicit paths, managed cache, PATH, catalog paths, and host probes, then ranks and deduplicates candidates. A catalog match is discovery evidence only. Managed provisioning and the dedicated Lightpanda example remain separate from Chromium runtime qualification. WebView2, Electron, and Android bridge APIs likewise need their own runtime tests before relying on them.

## Validation

```sh
zig build
zig build test
zig build examples
zig build test-chromium
```

`test-chromium` is a required real-Brave gate, including local browser fixtures and behavior/content assertions. It fails if its required browser is missing. Ordinary `test` may skip opt-in browser suites; a unit-only pass is not an integration pass. Cross-target builds establish compilation only; they do not establish native Windows, macOS, or mobile browser behavior.

See [contributing](CONTRIBUTING.md) for test expectations and [examples](examples/README.md) for compiled API usage.
