# Path Discovery

## Search Order
`discover()` checks candidates in this order:
1. Explicit path (`BrowserPreference.explicit_path`).
2. Managed cache (if `allow_managed_download=true`).
3. `PATH` environment scan (browser executable aliases).
4. Known absolute path catalog (`src/catalog/path_table.zig`).
5. OS-specific probes:
   - Windows: known locations + registry-hint-backed discovery source tagging.
   - macOS: app bundle scanning in `/Applications` and `~/Applications`.
   - Linux: known package paths + `.desktop` Exec parsing + PATH resolution.

## Deterministic Ranking
Candidates are scored and sorted by:
1. Descending score.
2. Descending version (if present).
3. Ascending path lexicographic order.

Duplicates are de-duplicated by normalized path key (case-insensitive normalization on Windows).

## Path Catalog
The canonical path metadata is Zig-only and lives in:
- `src/catalog/path_table.zig`

Each browser/platform record includes:
- executable aliases for PATH probing,
- known absolute install paths,
- macOS bundle IDs,
- Windows registry hints,
- Linux package hints,
- base confidence weight.
