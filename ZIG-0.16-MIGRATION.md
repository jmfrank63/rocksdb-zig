# Zig 0.16 migration

Status of `rocksdb-zig` against Zig **0.16.0**.

This document originally covered the small upstream-tracking port on branch
`update-to-zig-0.16`. It now describes branch `zig-0.16.0-full`, which merges
that work into the `update_to_0.15.2` fork — the fork's vendored/MSVC build
system, Windows port, transactions, checkpoints and backup engine are all
carried forward and ported to 0.16.

Target is Zig **0.16.0** only; 0.17-dev is explicitly out of scope.

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
`getOutput().dirname()` idiom becomes either `getOutputFile().dirname()` (what
this repo uses, matching upstream) or the equivalent, more direct
`getOutputDir()` — `getOutputFile()` is defined as `getOutputDir().path(...)`,
so the two resolve to the same directory.

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

## Breaking API change: `Io` is threaded through as a parameter

Because `std.Io.RwLock` needs an `Io` for every lock operation, the methods that
touch the column-family map gained an `io` parameter. This applies to all three
database types — `DB`, `TransactionDB` and `OptimisticTransactionDB`:

```zig
const db, const cfs = try DB.open(allocator, io, path, db_options, cfs, false, &err_str);
const handle        = try db.createColumnFamily(io, name, &err_str);
const cf            = try db.columnFamily(io, "another");
```

`open()` takes `io` as well, because it populates the locked map via
`putUnowned()`. The alternative — having `open()` write to the map directly and
skip the lock, on the grounds that the map is not yet shared — was rejected in
favour of keeping the rule uniform.

**No function stores an `Io`.** It is passed per call so every function stays
colorless: callable from both sync and async contexts, with the caller deciding
which `Io` implementation applies at each call site.

`lockUncancelable` / `lockSharedUncancelable` are used internally so that
`columnFamily()` and `createColumnFamily()` keep their existing error sets
rather than gaining `Io.Cancelable`.

## Breaking API change: `DB.liveFiles` returns an owned slice

`liveFiles` now returns `[]const LiveFile` instead of a `std.ArrayList`, and it
destroys the underlying RocksDB livefiles handle before returning. Callers own
the slice:

```zig
const lfs = try db.liveFiles(allocator);
defer {
    for (lfs) |lf| lf.deinit();
    allocator.free(lfs);
}
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
| `build.zig` | `std.fs.cwd()` → `std.Io.Dir.cwd()` with `b.graph.io`; C/link calls routed through `root_module`; `ConfigHeader` output accessors. `TranslateC.getOutput()` deliberately untouched — it still exists in 0.16 |
| `build.zig.zon` | `minimum_zig_version` → `0.16.0` (version stays `10.9.1`) |
| `.github/workflows/check.yml` | Zig 0.15.2 → 0.16.0; the fork's Windows self-hosted test matrix is kept |
| `.gitignore` | Union of both branches' entries |
| `.gitattributes` | **New** — force LF for `*.zig` / `*.zon` (see below) |
| `ZIG-0.16-MIGRATION.md` | This document |
| `src/data.zig` | `format` takes a concrete `*std.Io.Writer`; `std.io.fixedBufferStream` → `std.Io.Writer.fixed` |
| `src/database.zig` | `std.Io.RwLock`; `io` threaded through `open`/`createColumnFamily`/`columnFamily` on all three DB types; `Io.Dir` paths |
| `src/batch.zig`, `src/iterator.zig` | `Io.Dir` test paths; `io` at `open()` call sites |

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

All verification below was run **natively on Windows** with Zig 0.16.0, which
the fork's build system supports.

- `zig build --help` — configure phase succeeds.
- `zig fmt --check src/ build.zig` — passes.
- `zig build test --summary all` — 115/116 pass, 1 skipped. The skip is the
  fork's pre-existing `if (builtin.mode == .Debug) return error.SkipZigTest`,
  not a regression.
- `zig build --release=fast test --summary all` — **116/116 pass**. This is
  CI's main job, and the Debug-only skip runs here.
- `zig build --release=fast -Denable_c_api_static=true` — succeeds.

## Known issues / follow-ups

### Windows is supported on this branch

The upstream-tracking branch panicked with `TODO: support windows!` in
`build.zig`. That is **resolved here**: the fork provides `OS_WIN`,
`port/win/{env_win,io_win,win_logger,win_thread}.cc`, `rpcrt4`/`shlwapi`
linkage, an MSVC path via `scripts/build_rocksdb.ps1`, and a vendored
`vendor/rocksdb` submodule. All verification above ran natively on Windows.

The MSVC configuration (`-Dtarget=native-windows-msvc
-Duse_msvc_compiler=true`) additionally requires the submodule to be
initialised (`git submodule update --init --recursive`) and a Visual Studio
toolchain; it is exercised by CI on the `ghr-base-win` self-hosted runner
rather than here.

### musl targets abort in RocksDB's cache (pre-existing)

Carried over from the upstream-tracking branch and **not re-verified here**,
since verification on this branch is native Windows. Recorded so the finding is
not lost. On that branch the glibc build passed all tests and only musl was
affected, aborting inside RocksDB C++:

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

### README

The fork's README is carried forward unchanged by the merge. It has not been
re-checked for stale Zig version references.
