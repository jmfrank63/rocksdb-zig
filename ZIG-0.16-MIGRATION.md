# Zig 0.16 migration

Status of `rocksdb-zig` against Zig **0.16.0**, and the changes made on branch
`update-to-zig-0.16`.

## Did `master` work on 0.16?

No. `master` (pinned to 0.14.1) does not even reach the configure phase:

```
build.zig:107:15: error: no field or member function named 'linkLibC' in 'Build.Step.Compile'
```

Both the build script and the binding sources needed changes.

## What 0.16 broke

### 1. `Build.Step.Compile` no longer forwards to its root module

Every `add*` / `link*` convenience method was removed from `Build.Step.Compile`;
they now live only on `Build.Module`. This was the single largest source of
errors in `build.zig`.

| 0.14 | 0.16 |
| --- | --- |
| `lib.linkLibC()` | `lib.root_module.link_libc = true` |
| `lib.linkLibCpp()` | `lib.root_module.link_libcpp = true` |
| `lib.addIncludePath(p)` | `lib.root_module.addIncludePath(p)` |
| `lib.addCSourceFile(f)` | `lib.root_module.addCSourceFile(f)` |
| `lib.addCSourceFiles(o)` | `lib.root_module.addCSourceFiles(o)` |
| `lib.linkLibrary(other)` | `lib.root_module.linkLibrary(other)` |

Note `link_libc` / `link_libcpp` are plain `?bool` fields, not methods.

### 2. `b.addTest` requires a module

`TestOptions` no longer accepts `root_source_file` / `target` / `optimize`;
it takes a pre-built `root_module`.

### 3. `Step.ConfigHeader.getOutput()` split in two

`getOutput()` was replaced by `getOutputDir()` and `getOutputFile()`. The old
`getOutput().dirname()` idiom becomes `getOutputDir()`.

### 4. `std.Thread` lost all synchronization primitives

`std.Thread.RwLock`, `Mutex` and `Condition` are gone. The replacements live in
`std.Io` and take an `Io` instance on every operation:

```zig
pub fn lock(rl: *RwLock, io: Io) Io.Cancelable!void
pub fn lockUncancelable(rl: *RwLock, io: Io) void
```

This is the one change with a **breaking public API consequence** — see below.

### 5. `std.fs` test helpers moved to `std.Io.Dir`

`std.testing.tmpDir()` now returns a `TmpDir` whose `dir` is an `std.Io.Dir`.
`realpathAlloc(allocator, sub_path)` became
`realPathFileAlloc(io, sub_path, allocator)` (note the capital `P` and the
reordered parameters). `std.testing.io` provides the `Io` instance in tests.

### 6. The `format` method contract changed

The old four-parameter `format(self, comptime fmt, options, writer)` is gone.
0.16 uses:

```zig
pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void
```

`std.fmt.FormatOptions` is now `std.fmt.Options`, and `std.fmt.formatBuf` was
replaced by `Writer.alignBufferOptions`.

**Silent behaviour trap:** a custom `format` method is only invoked by the `{f}`
specifier. Plain `{}` no longer errors — it falls back to dumping the struct's
fields. `src/database.zig` printed an error string with `{?}`, which on 0.16
would have quietly produced `.{ .data = { 104, 101, ... } }` instead of the
message. Changed to `{?f}`.

### 7. `std.ArrayList` is unmanaged

`std.ArrayList(T)` is now the unmanaged variant. `.init(allocator)` is gone;
the allocator is passed per-operation.

```zig
var list: std.ArrayList(T) = .empty;
try list.append(allocator, item);
list.deinit(allocator);
```

`std.ArrayListUnmanaged` still exists as a deprecated alias, so `build.zig`'s
use of it kept working.

### 8. `callconv(.C)` → `callconv(.c)`

The uppercase tag was removed.

## Breaking API change: `DB.open` takes an `Io`

Because `std.Io.RwLock` needs an `Io` for every lock operation, `DB` now stores
one and `DB.open` gained a parameter:

```zig
const db, const cfs = try DB.open(
    allocator,
    io,          // <-- new, e.g. std.testing.io or your Io.Threaded instance
    path,
    db_options,
    column_families,
    for_read_only,
    &err_str,
);
```

`lockUncancelable` / `lockSharedUncancelable` are used internally so that
`columnFamily()` and `createColumnFamily()` keep their existing error sets
rather than gaining `Io.Cancelable`.

## Breaking API change: `DB.liveFiles` returns an unmanaged list

`liveFiles` still returns `std.ArrayList(LiveFile)`, but that type is unmanaged
on 0.16, so callers must supply the allocator when freeing:

```zig
var lfs = try db.liveFiles(allocator);
defer lfs.deinit(allocator);   // was: lfs.deinit()
```

## Incidental bugs fixed

These were latent on `master` — Zig's lazy analysis meant the affected functions
were never semantically analysed, so they never surfaced as errors:

- `CfNameToHandleMap.put` discarded the error union from `map.put` (missing
  `try`) and leaked `owned_name` if the insert failed (missing `errdefer`).
- `DB.createColumnFamily` discarded the error union from
  `cf_name_to_handle.put`.

## Files changed

| File | Change |
| --- | --- |
| `build.zig` | Route all C/link calls through `root_module`; `addTest` module; `ConfigHeader` output accessors |
| `build.zig.zon` | `minimum_zig_version` → `0.16.0` |
| `.github/workflows/check.yml` | Zig 0.14.1 → 0.16.0 |
| `.gitignore` | Ignore the new `/zig-pkg` directory (see below) |
| `.gitattributes` | **New** — force LF for `*.zig` / `*.zon` (see below) |
| `README.md` | Zig version bump; note that native Windows builds are unsupported |
| `ZIG-0.16-MIGRATION.md` | **New** — this document |
| `src/data.zig` | `callconv(.c)`; new `format` signature |
| `src/database.zig` | `std.Io.RwLock` + `Io` threading; unmanaged `ArrayList`; `Io.Dir` test paths; `{?f}`; latent bug fixes |

## `zig-pkg/` — new in 0.16

Zig 0.16 unpacks fetched dependencies into a **project-local** `zig-pkg/`
directory rather than only the global cache. For this repo that is 2,066 files
of vendored RocksDB C++ source appearing as untracked content in a fresh clone.

Verified by renaming the directory and re-running the configure phase: Zig
recreated `zig-pkg/` with an identical 2,066-file tree.

The `.gitignore` was written for 0.14 (`/.zig-cache`, `/zig-out`) and did not
know about it, so `/zig-pkg` has been added.

## CRLF vs the lint job

On a Windows clone with `core.autocrlf=true` (the default from Git for Windows),
every `.zig` file checks out with CRLF line endings. Zig requires LF, so:

```
$ zig fmt --check src/ build.zig
src/batch.zig
src/data.zig
...            # every file, including ones nobody touched
```

CI never caught this because the Ubuntu runner checks out with LF. A
`.gitattributes` pinning `*.zig` and `*.zon` to `eol=lf` has been added so the
working tree is correct regardless of the developer's `autocrlf` setting.

## Verification performed

- `zig build --help` — configure phase succeeds.
- `zig build test -Dtarget=x86_64-linux-musl` — RocksDB C++ and the Zig test
  binary compile and link cleanly.
- Test binary executed under WSL (Windows cannot run Linux binaries directly).

## Known issues / follow-ups

### Windows is unsupported (pre-existing)

`build.zig` still contains:

```zig
} else {
    @panic("TODO: support windows!");
}
```

So `zig build` cannot run natively on Windows at all, on 0.14 or 0.16. All
verification here was done by cross-compiling to Linux. This is unchanged by the
migration.

### musl targets abort in RocksDB's cache (pre-existing)

Running the musl build aborts inside RocksDB C++:

```
panic: constructor call on misaligned address ... for type 'LRUCacheShard',
which requires 64 byte alignment
```

Cause: `port_posix.cc`'s `cacheline_aligned_alloc` only uses `posix_memalign`
when `_POSIX_C_SOURCE >= 200112L` or `_XOPEN_SOURCE >= 600` is defined,
otherwise falling back to plain `malloc` (16-byte aligned). glibc's `features.h`
defines `_POSIX_C_SOURCE` by default; musl compiled via Zig does not, and this
repo's `rocksdb_flags` does not define it either.

This is independent of the 0.16 migration. The fix would be to add
`-D_POSIX_C_SOURCE=200112L` to `rocksdb_flags`, but that is deliberately left
out of this branch to keep the migration scoped.

### README still documents 0.14.1

Updated as part of this branch.
