const std = @import("std");
const Build = std.Build;
const ResolvedTarget = Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;

pub fn build(b: *Build) !void {
    const io = b.graph.io;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_snappy = b.option(
        bool,
        "enable_snappy",
        "Enables and builds with the Snappy compressor",
    ) orelse false;

    const use_msvc_lib = b.option(
        bool,
        "use_msvc_lib",
        "Use pre-built MSVC library from vendor/ (requires -Dtarget=native-windows-msvc)",
    ) orelse false;

    const use_msvc_compiler = b.option(
        bool,
        "use_msvc_compiler",
        "Use MSVC compiler instead of clang (Windows MSVC ABI only). Default: false (uses clang)",
    ) orelse false;

    // When targeting MSVC ABI, use MSVC-built RocksDB library by default
    // because Zig's clang has conflicts between libc++ and MSVC STL headers.
    const effective_use_msvc_lib = use_msvc_lib or target.result.abi == .msvc or use_msvc_compiler;

    const enable_c_api_static = b.option(
        bool,
        "enable_c_api_static",
        "Build a C-API-only static library (no C++ API)",
    ) orelse false;

    const enable_c_api_shared = b.option(
        bool,
        "enable_c_api_shared",
        "Build a C-API-only shared library (avoids Windows export limit)",
    ) orelse false;

    // Add build steps for RocksDB MSVC library (define early so we can reference them)
    var rocksdb_build_step: ?*Build.Step = null;
    if (target.result.os.tag == .windows and effective_use_msvc_lib) {
        // First, check if vendor/rocksdb exists
        const vendor_rocksdb_exists = blk: {
            b.build_root.handle.access(io, "vendor/rocksdb", .{}) catch break :blk false;
            break :blk true;
        };

        if (!vendor_rocksdb_exists) {
            std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
            std.debug.print("ERROR: vendor/rocksdb not found\n", .{});
            std.debug.print("=" ** 70 ++ "\n\n", .{});
            std.debug.print("RocksDB submodule is not initialized.\n\n", .{});
            std.debug.print("SOLUTION: Initialize the submodule:\n\n", .{});
            std.debug.print("    git submodule update --init --recursive\n\n", .{});
            std.debug.print("Or clone RocksDB manually:\n\n", .{});
            std.debug.print("    git clone --depth 1 --branch v10.9.1 https://github.com/facebook/rocksdb.git vendor/rocksdb\n\n", .{});
            std.debug.print("=" ** 70 ++ "\n", .{});
            return error.RocksDBSubmoduleNotInitialized;
        }

        // Check if we need to build RocksDB
        // Always use Release config for RocksDB library to avoid debug CRT symbol issues
        // (Zig's libc doesn't provide _malloc_dbg, _free_dbg, etc.)
        const rocksdb_config = "Release";
        const vendor_lib_path = b.fmt("build/rocksdb_{s}/rocksdb.lib", .{rocksdb_config});

        // Always create build step if use_msvc_compiler is set,
        // or if the library doesn't exist yet.
        const lib_exists = blk: {
            b.build_root.handle.access(io, vendor_lib_path, .{}) catch break :blk false;
            break :blk true;
        };

        if (use_msvc_compiler or !lib_exists) {
            if (use_msvc_compiler) {
                std.debug.print("Forcing RocksDB build with MSVC compiler...\n", .{});
            } else {
                std.debug.print("RocksDB MSVC library not found, will build automatically...\n", .{});
            }
            const build_rocksdb_cmd = b.addSystemCommand(&[_][]const u8{
                "powershell.exe",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                "scripts/build_rocksdb.ps1",
                "-BuildType",
                "Release",
            });
            rocksdb_build_step = &build_rocksdb_cmd.step;
        }

        // Also create manual build steps
        const build_rocksdb_release = b.step("rocksdb-msvc-release", "Build RocksDB Release library with MSVC");
        const build_rocksdb_release_cmd = b.addSystemCommand(&[_][]const u8{
            "powershell.exe",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            "scripts/build_rocksdb.ps1",
            "-BuildType",
            "Release",
        });
        build_rocksdb_release.dependOn(&build_rocksdb_release_cmd.step);
    }

    // RocksDB's translate-c module
    const rocksdb_mod = try addRocksDB(b, target, optimize, enable_snappy, enable_c_api_static, enable_c_api_shared, effective_use_msvc_lib, use_msvc_compiler, rocksdb_build_step);
    const bindings_mod = b.addModule("bindings", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/lib.zig"),
    });
    bindings_mod.addImport("rocksdb", rocksdb_mod);

    const test_optimize = if (effective_use_msvc_lib) optimize else optimize; // Use same optimize mode

    const bindings_mod_for_test = b.addModule("bindings", .{
        .target = target,
        .optimize = test_optimize,
        .root_source_file = b.path("src/lib.zig"),
    });
    bindings_mod_for_test.addImport("rocksdb", rocksdb_mod);

    const tests = b.addTest(.{
        .root_module = bindings_mod_for_test,
    });

    const test_step = b.step("test", "Run bindings tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

/// Create a zig module for the bare C++ library by exposing its C api.
/// Builds rocksdb, links it, and translates its headers.
///
/// COMPILER SELECTION:
/// - Default: Zig's clang compiler (LLVM-based)
/// - Option: MSVC compiler via -Duse_msvc_compiler (Windows MSVC ABI only)
///
/// KNOWN ISSUES:
/// - Debug builds with clang may fail due to CRT mismatch with RocksDB source
/// - Use Release mode or -Duse_msvc_lib to work around this issue
fn addRocksDB(
    b: *Build,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    enable_snappy: bool,
    enable_c_api_static: bool,
    enable_c_api_shared: bool,
    use_msvc_lib: bool,
    use_msvc_compiler: bool,
    maybe_rocksdb_build_step: ?*Build.Step,
) !*Build.Module {
    const io = b.graph.io;

    // Validate MSVC compiler option first
    if (use_msvc_compiler) {
        if (target.result.os.tag != .windows or target.result.abi != .msvc) {
            std.debug.print("ERROR: -Duse_msvc_compiler requires -Dtarget=native-windows-msvc\n", .{});
            return error.InvalidTarget;
        }
    }

    // Note: MSVC ABI builds may fail if MSVC headers are not available.
    // In that case, use -Duse_msvc_lib=true or the default target.

    // Print compiler info
    if (use_msvc_compiler) {
        std.debug.print("Building with MSVC compiler (via scripts/build_rocksdb.ps1)\n", .{});
    } else if (use_msvc_lib) {
        std.debug.print("Building with Zig clang compiler + pre-built MSVC RocksDB library\n", .{});
    } else {
        std.debug.print("Building with Zig clang compiler (default)\n", .{});
    }

    // Check if vendor/rocksdb exists for MSVC builds
    const use_vendor_rocksdb = blk: {
        b.build_root.handle.access(io, "vendor/rocksdb", .{}) catch break :blk false;
        break :blk target.result.abi == .msvc;
    };

    // Determine source for RocksDB: vendor directory or Zig dependency
    const rocks_path_base = if (use_vendor_rocksdb)
        b.path("vendor/rocksdb")
    else
        b.dependency("rocksdb", .{}).path("");

    const translate_c = b.addTranslateC(.{
        .root_source_file = if (use_vendor_rocksdb)
            b.path("vendor/rocksdb/include/rocksdb/c.h")
        else
            b.dependency("rocksdb", .{}).path("include/rocksdb/c.h"),
        .target = target,
        .optimize = optimize,
    });

    // If we need to build RocksDB first, make translate_c depend on it
    if (maybe_rocksdb_build_step) |build_step| {
        translate_c.step.dependOn(build_step);
    }

    // Use pre-built MSVC library when targeting MSVC ABI
    if (use_msvc_lib) {
        if (target.result.abi != .msvc) {
            std.debug.print("WARNING: -Duse_msvc_lib requires -Dtarget=native-windows-msvc\n", .{});
            return error.InvalidTarget;
        }

        // Try building from vendor/rocksdb first if it exists
        const lib_path = if (use_vendor_rocksdb) blk: {
            std.debug.print("Using MSVC-built RocksDB from vendor/...\n", .{});

            // Try to find the pre-built library
            // Always use Release build to avoid debug CRT symbol linking issues
            const vendor_lib_path = b.fmt("build/rocksdb_Release/rocksdb.lib", .{});

            // If we have a build step, the library will be built, so proceed
            if (maybe_rocksdb_build_step != null) {
                std.debug.print("Library will be built automatically...\n", .{});
                break :blk vendor_lib_path;
            }

            // Otherwise check if it exists
            const lib_file = b.build_root.handle.openFile(io, vendor_lib_path, .{}) catch {
                std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
                std.debug.print("ERROR: MSVC RocksDB library not found\n", .{});
                std.debug.print("=" ** 70 ++ "\n\n", .{});
                std.debug.print("Expected location: {s}\n\n", .{vendor_lib_path});
                std.debug.print("NOTE: The build system should have built this automatically.\n", .{});
                std.debug.print("      If you see this error, try building manually:\n\n", .{});
                std.debug.print("    .\\scripts\\build_rocksdb.ps1 -BuildType Release\n\n", .{});
                std.debug.print("=" ** 70 ++ "\n", .{});
                return error.LibraryNotFound;
            };
            lib_file.close(io);

            break :blk vendor_lib_path;
        } else blk: {
            // Fall back to build/rocksdb_Release (always use Release to avoid debug CRT symbols)
            const release_path = "build/rocksdb_Release/rocksdb.lib";
            // Check if Release library exists
            const release_file = b.build_root.handle.openFile(io, release_path, .{}) catch {
                std.debug.print("ERROR: No MSVC RocksDB library found.\n", .{});
                std.debug.print("       Clone RocksDB: git clone --depth=1 -b v10.9.1 https://github.com/facebook/rocksdb vendor/rocksdb\n", .{});
                std.debug.print("       Then build: .\\scripts\\build_rocksdb.ps1 -BuildType Release\n", .{});
                return error.LibraryNotFound;
            };
            release_file.close(io);
            std.debug.print("Using pre-built MSVC RocksDB library from build/rocksdb_Release\n", .{});
            break :blk release_path;
        };

        // Create module with libc but WITHOUT libc++ (MSVC uses its own C++ stdlib)
        const mod = b.addModule("rocksdb", .{
            .root_source_file = translate_c.getOutput(),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // Do NOT link libc++ - MSVC has its own C++ standard library
        });

        // Link the MSVC-built library
        mod.addObjectFile(b.path(lib_path));

        // Add Windows system libraries that MSVC builds expect
        if (target.result.os.tag == .windows) {
            mod.linkSystemLibrary("shlwapi", .{});
            mod.linkSystemLibrary("rpcrt4", .{});
            // Note: Not linking MSVC CRT explicitly to avoid conflicts with Zig's libc
            // This means Debug builds with MSVC library have CRT mismatch issues

            mod.addIncludePath(b.path("vendor/rocksdb/include"));
        } else {
            mod.addIncludePath(b.dependency("rocksdb", .{}).path("include"));
        }

        return mod;
    }

    // Default path: build from source with libc++ (unless targeting MSVC)
    // MSVC has its own C++ standard library, so we don't link libc++
    const mod = b.addModule("rocksdb", .{
        .root_source_file = translate_c.getOutput(),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = target.result.abi != .msvc, // Only link libc++ on non-MSVC targets
    });

    const force_pic = b.option(bool, "force_pic", "Forces PIC enabled for the libraries");

    const static_rocksdb = b.addLibrary(.{
        .name = if (enable_c_api_static) "rocksdb_c_api" else "rocksdb",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .pic = if (force_pic == true) true else null,
        }),
    });
    // Windows DLLs have a 65535 symbol export limit, but RocksDB exports ~80k symbols.
    // By default we skip the shared library on Windows. You can opt in to a C-API-only DLL.
    const dynamic_rocksdb = if (target.result.os.tag == .windows)
        (if (enable_c_api_shared) b.addLibrary(.{
            .name = "rocksdb_shared",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .pic = if (force_pic == true) true else null,
            }),
        }) else null)
    else
        b.addLibrary(.{
            .name = "rocksdb_shared",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .pic = if (force_pic == true) true else null,
            }),
        });

    const maybe_libsnappy = if (enable_snappy) b.addLibrary(.{
        .name = "snappy",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .pic = if (force_pic == true) true else null,
        }),
    }) else null;

    if (enable_c_api_static) {
        // C-API-only static library: disable C++ and export symbols
        static_rocksdb.root_module.addCMacro("ROCKSDB_DLL", "");
        static_rocksdb.root_module.addCMacro("ROCKSDB_LIBRARY_EXPORTS", "");
    }

    try buildRocksDB(b, static_rocksdb, maybe_libsnappy, target, enable_c_api_static, rocks_path_base);
    if (dynamic_rocksdb) |dyn| {
        const dyn_is_c_api_only = enable_c_api_shared or target.result.os.tag == .windows;
        if (dyn_is_c_api_only) {
            // Export only the C API symbols (c.h) to avoid the DLL export limit.
            dyn.dll_export_fns = false;
            dyn.root_module.addCMacro("ROCKSDB_DLL", "");
            dyn.root_module.addCMacro("ROCKSDB_LIBRARY_EXPORTS", "");
        }
        try buildRocksDB(b, dyn, maybe_libsnappy, target, dyn_is_c_api_only, rocks_path_base);
    }

    mod.addIncludePath(rocks_path_base.path(b, "include"));
    mod.linkLibrary(static_rocksdb);

    // If snappy is enabled, ensure it's also linked to the module
    // so that tests and other consumers have access to snappy symbols
    if (maybe_libsnappy) |libsnappy| {
        mod.linkLibrary(libsnappy);
    }

    return mod;
}

/// The build process for rocksdb itself. works for static or shared library
fn buildRocksDB(
    b: *Build,
    librocksdb: *std.Build.Step.Compile,
    maybe_libsnappy: ?*std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    c_api_only: bool,
    rocks_path: Build.LazyPath,
) !void {
    const t = target.result;

    librocksdb.root_module.link_libc = true;
    // Only link libc++ on non-MSVC targets; MSVC has its own C++ stdlib
    if (t.abi != .msvc) {
        librocksdb.root_module.link_libcpp = true;
    }

    var rocksdb_flags: std.ArrayListUnmanaged([]const u8) = .empty;
    defer rocksdb_flags.deinit(b.allocator);
    try rocksdb_flags.appendSlice(b.allocator, &.{
        "-std=c++17",
        "-faligned-new",
        "-DHAVE_ALIGNED_NEW",
        "-DROCKSDB_UBSAN_RUN",
    });
    if (maybe_libsnappy != null) try rocksdb_flags.append(b.allocator, "-DSNAPPY=1");

    librocksdb.root_module.addIncludePath(rocks_path.path(b, "include"));
    librocksdb.root_module.addIncludePath(rocks_path.path(b, "."));
    librocksdb.root_module.addCSourceFiles(.{
        .root = rocks_path.path(b, "."),
        .files = &.{
            "cache/cache.cc",
            "cache/cache_entry_roles.cc",
            "cache/cache_key.cc",
            "cache/cache_helpers.cc",
            "cache/cache_reservation_manager.cc",
            "cache/charged_cache.cc",
            "cache/clock_cache.cc",
            "cache/compressed_secondary_cache.cc",
            "cache/lru_cache.cc",
            "cache/secondary_cache.cc",
            "cache/secondary_cache_adapter.cc",
            "cache/sharded_cache.cc",
            "cache/tiered_secondary_cache.cc",
            "db/arena_wrapped_db_iter.cc",
            "db/attribute_group_iterator_impl.cc",
            "db/blob/blob_contents.cc",
            "db/blob/blob_fetcher.cc",
            "db/blob/blob_file_addition.cc",
            "db/blob/blob_file_builder.cc",
            "db/blob/blob_file_cache.cc",
            "db/blob/blob_file_garbage.cc",
            "db/blob/blob_file_meta.cc",
            "db/blob/blob_file_reader.cc",
            "db/blob/blob_garbage_meter.cc",
            "db/blob/blob_log_format.cc",
            "db/blob/blob_log_sequential_reader.cc",
            "db/blob/blob_log_writer.cc",
            "db/blob/blob_source.cc",
            "db/blob/prefetch_buffer_collection.cc",
            "db/builder.cc",
            "db/c.cc",
            "db/coalescing_iterator.cc",
            "db/column_family.cc",
            "db/compaction/compaction.cc",
            "db/compaction/compaction_iterator.cc",
            "db/compaction/compaction_picker.cc",
            "db/compaction/compaction_job.cc",
            "db/compaction/compaction_picker_fifo.cc",
            "db/compaction/compaction_picker_level.cc",
            "db/compaction/compaction_picker_universal.cc",
            "db/compaction/compaction_service_job.cc",
            "db/compaction/compaction_state.cc",
            "db/compaction/compaction_outputs.cc",
            "db/compaction/sst_partitioner.cc",
            "db/compaction/subcompaction_state.cc",
            "db/convenience.cc",
            "db/db_filesnapshot.cc",
            "db/db_impl/compacted_db_impl.cc",
            "db/db_impl/db_impl.cc",
            "db/db_impl/db_impl_write.cc",
            "db/db_impl/db_impl_compaction_flush.cc",
            "db/db_impl/db_impl_files.cc",
            "db/db_impl/db_impl_follower.cc",
            "db/db_impl/db_impl_open.cc",
            "db/db_impl/db_impl_debug.cc",
            "db/db_impl/db_impl_experimental.cc",
            "db/db_impl/db_impl_readonly.cc",
            "db/db_impl/db_impl_secondary.cc",
            "db/db_info_dumper.cc",
            "db/db_iter.cc",
            "db/dbformat.cc",
            "db/error_handler.cc",
            "db/event_helpers.cc",
            "db/experimental.cc",
            "db/external_sst_file_ingestion_job.cc",
            "db/file_indexer.cc",
            "db/flush_job.cc",
            "db/flush_scheduler.cc",
            "db/forward_iterator.cc",
            "db/import_column_family_job.cc",
            "db/internal_stats.cc",
            "db/logs_with_prep_tracker.cc",
            "db/log_reader.cc",
            "db/log_writer.cc",
            "db/malloc_stats.cc",
            "db/manifest_ops.cc",
            "db/memtable.cc",
            "db/memtable_list.cc",
            "db/merge_helper.cc",
            "db/merge_operator.cc",
            "db/multi_scan.cc",
            "db/output_validator.cc",
            "db/periodic_task_scheduler.cc",
            "db/range_del_aggregator.cc",
            "db/range_tombstone_fragmenter.cc",
            "db/repair.cc",
            "db/seqno_to_time_mapping.cc",
            "db/snapshot_impl.cc",
            "db/table_cache.cc",
            "db/table_properties_collector.cc",
            "db/transaction_log_impl.cc",
            "db/trim_history_scheduler.cc",
            "db/version_builder.cc",
            "db/version_edit.cc",
            "db/version_edit_handler.cc",
            "db/version_set.cc",
            "db/wal_edit.cc",
            "db/wal_manager.cc",
            "db/wide/wide_column_serialization.cc",
            "db/wide/wide_columns.cc",
            "db/wide/wide_columns_helper.cc",
            "db/write_batch.cc",
            "db/write_batch_base.cc",
            "db/write_controller.cc",
            "db/write_stall_stats.cc",
            "db/write_thread.cc",
            "env/composite_env.cc",
            "env/env.cc",
            "env/env_chroot.cc",
            "env/env_encryption.cc",
            "env/file_system.cc",
            "env/file_system_tracer.cc",
            "env/fs_on_demand.cc",
            "env/fs_remap.cc",
            "env/mock_env.cc",
            "env/unique_id_gen.cc",
            "file/delete_scheduler.cc",
            "file/file_prefetch_buffer.cc",
            "file/file_util.cc",
            "file/filename.cc",
            "file/line_file_reader.cc",
            "file/random_access_file_reader.cc",
            "file/read_write_util.cc",
            "file/readahead_raf.cc",
            "file/sequence_file_reader.cc",
            "file/sst_file_manager_impl.cc",
            "file/writable_file_writer.cc",
            "logging/auto_roll_logger.cc",
            "logging/event_logger.cc",
            "logging/log_buffer.cc",
            "memory/arena.cc",
            "memory/concurrent_arena.cc",
            "memory/jemalloc_nodump_allocator.cc",
            "memory/memkind_kmem_allocator.cc",
            "memory/memory_allocator.cc",
            "memtable/alloc_tracker.cc",
            "memtable/hash_linklist_rep.cc",
            "memtable/hash_skiplist_rep.cc",
            "memtable/skiplistrep.cc",
            "memtable/vectorrep.cc",
            "memtable/wbwi_memtable.cc",
            "memtable/write_buffer_manager.cc",
            "monitoring/histogram.cc",
            "monitoring/histogram_windowing.cc",
            "monitoring/in_memory_stats_history.cc",
            "monitoring/instrumented_mutex.cc",
            "monitoring/iostats_context.cc",
            "monitoring/perf_context.cc",
            "monitoring/perf_level.cc",
            "monitoring/persistent_stats_history.cc",
            "monitoring/statistics.cc",
            "monitoring/thread_status_impl.cc",
            "monitoring/thread_status_updater.cc",
            "monitoring/thread_status_util.cc",
            "monitoring/thread_status_util_debug.cc",
            "options/cf_options.cc",
            "options/configurable.cc",
            "options/customizable.cc",
            "options/db_options.cc",
            "options/offpeak_time_info.cc",
            "options/options.cc",
            "options/options_helper.cc",
            "options/options_parser.cc",
            "port/mmap.cc",
            "port/stack_trace.cc",
            "table/adaptive/adaptive_table_factory.cc",
            "table/block_based/binary_search_index_reader.cc",
            "table/block_based/block.cc",
            "table/block_based/block_based_table_builder.cc",
            "table/block_based/block_based_table_factory.cc",
            "table/block_based/block_based_table_iterator.cc",
            "table/block_based/block_based_table_reader.cc",
            "table/block_based/block_builder.cc",
            "table/block_based/block_cache.cc",
            "table/block_based/block_prefetcher.cc",
            "table/block_based/block_prefix_index.cc",
            "table/block_based/data_block_hash_index.cc",
            "table/block_based/data_block_footer.cc",
            "table/block_based/filter_block_reader_common.cc",
            "table/block_based/filter_policy.cc",
            "table/block_based/flush_block_policy.cc",
            "table/block_based/full_filter_block.cc",
            "table/block_based/hash_index_reader.cc",
            "table/block_based/index_builder.cc",
            "table/block_based/index_reader_common.cc",
            "table/block_based/parsed_full_filter_block.cc",
            "table/block_based/partitioned_filter_block.cc",
            "table/block_based/partitioned_index_iterator.cc",
            "table/block_based/partitioned_index_reader.cc",
            "table/block_based/reader_common.cc",
            "table/block_based/uncompression_dict_reader.cc",
            "table/block_fetcher.cc",
            "table/cuckoo/cuckoo_table_builder.cc",
            "table/cuckoo/cuckoo_table_factory.cc",
            "table/cuckoo/cuckoo_table_reader.cc",
            "table/format.cc",
            "table/get_context.cc",
            "table/iterator.cc",
            "table/merging_iterator.cc",
            "table/compaction_merging_iterator.cc",
            "table/meta_blocks.cc",
            "table/persistent_cache_helper.cc",
            "table/plain/plain_table_bloom.cc",
            "table/plain/plain_table_builder.cc",
            "table/plain/plain_table_factory.cc",
            "table/plain/plain_table_index.cc",
            "table/plain/plain_table_key_coding.cc",
            "table/plain/plain_table_reader.cc",
            "table/sst_file_dumper.cc",
            "table/sst_file_reader.cc",
            "table/sst_file_writer.cc",
            "table/table_factory.cc",
            "table/table_properties.cc",
            "table/two_level_iterator.cc",
            "table/unique_id.cc",
            "test_util/sync_point.cc",
            "test_util/sync_point_impl.cc",
            "test_util/testutil.cc",
            "test_util/transaction_test_util.cc",
            "trace_replay/block_cache_tracer.cc",
            "trace_replay/io_tracer.cc",
            "trace_replay/trace_record_handler.cc",
            "trace_replay/trace_record_result.cc",
            "trace_replay/trace_record.cc",
            "trace_replay/trace_replay.cc",
            "util/async_file_reader.cc",
            "util/cleanable.cc",
            "util/coding.cc",
            "util/compaction_job_stats_impl.cc",
            "util/comparator.cc",
            "util/compression.cc",
            "util/compression_context_cache.cc",
            "util/concurrent_task_limiter_impl.cc",
            "util/crc32c.cc",
            "util/data_structure.cc",
            "util/dynamic_bloom.cc",
            "util/hash.cc",
            "util/murmurhash.cc",
            "util/random.cc",
            "util/rate_limiter.cc",
            "util/ribbon_config.cc",
            "util/slice.cc",
            "util/file_checksum_helper.cc",
            "util/status.cc",
            "util/stderr_logger.cc",
            "util/string_util.cc",
            "util/thread_local.cc",
            "util/threadpool_imp.cc",
            "util/udt_util.cc",
            "util/write_batch_util.cc",
            "util/xxhash.cc",
            "utilities/agg_merge/agg_merge.cc",
            "utilities/backup/backup_engine.cc",
            "utilities/blob_db/blob_compaction_filter.cc",
            "utilities/blob_db/blob_db.cc",
            "utilities/blob_db/blob_db_impl.cc",
            "utilities/blob_db/blob_db_impl_filesnapshot.cc",
            "utilities/blob_db/blob_dump_tool.cc",
            "utilities/blob_db/blob_file.cc",
            "utilities/cache_dump_load.cc",
            "utilities/cache_dump_load_impl.cc",
            "utilities/cassandra/cassandra_compaction_filter.cc",
            "utilities/cassandra/format.cc",
            "utilities/cassandra/merge_operator.cc",
            "utilities/checkpoint/checkpoint_impl.cc",
            "utilities/compaction_filters.cc",
            "utilities/compaction_filters/remove_emptyvalue_compactionfilter.cc",
            "utilities/counted_fs.cc",
            "utilities/debug.cc",
            "utilities/env_mirror.cc",
            "utilities/env_timed.cc",
            "utilities/fault_injection_env.cc",
            "utilities/fault_injection_fs.cc",
            "utilities/fault_injection_secondary_cache.cc",
            "utilities/leveldb_options/leveldb_options.cc",
            "utilities/memory/memory_util.cc",
            "utilities/merge_operators.cc",
            "utilities/merge_operators/bytesxor.cc",
            "utilities/merge_operators/max.cc",
            "utilities/merge_operators/put.cc",
            "utilities/merge_operators/sortlist.cc",
            "utilities/merge_operators/string_append/stringappend.cc",
            "utilities/merge_operators/string_append/stringappend2.cc",
            "utilities/merge_operators/uint64add.cc",
            "utilities/object_registry.cc",
            "utilities/option_change_migration/option_change_migration.cc",
            "utilities/options/options_util.cc",
            "utilities/persistent_cache/block_cache_tier.cc",
            "utilities/persistent_cache/block_cache_tier_file.cc",
            "utilities/persistent_cache/block_cache_tier_metadata.cc",
            "utilities/persistent_cache/persistent_cache_tier.cc",
            "utilities/persistent_cache/volatile_tier_impl.cc",
            "utilities/simulator_cache/cache_simulator.cc",
            "utilities/simulator_cache/sim_cache.cc",
            "utilities/table_properties_collectors/compact_for_tiering_collector.cc",
            "utilities/table_properties_collectors/compact_on_deletion_collector.cc",
            "utilities/trace/file_trace_reader_writer.cc",
            "utilities/trace/replayer_impl.cc",
            "utilities/transactions/lock/lock_manager.cc",
            "utilities/transactions/lock/point/point_lock_tracker.cc",
            "utilities/transactions/lock/point/point_lock_manager.cc",
            "utilities/transactions/lock/range/range_tree/range_tree_lock_manager.cc",
            "utilities/transactions/lock/range/range_tree/range_tree_lock_tracker.cc",
            "utilities/transactions/optimistic_transaction_db_impl.cc",
            "utilities/transactions/optimistic_transaction.cc",
            "utilities/transactions/pessimistic_transaction.cc",
            "utilities/transactions/pessimistic_transaction_db.cc",
            "utilities/transactions/snapshot_checker.cc",
            "utilities/transactions/transaction_base.cc",
            "utilities/transactions/transaction_db_mutex_impl.cc",
            "utilities/transactions/transaction_util.cc",
            "utilities/transactions/write_prepared_txn.cc",
            "utilities/transactions/write_prepared_txn_db.cc",
            "utilities/transactions/write_unprepared_txn.cc",
            "utilities/transactions/write_unprepared_txn_db.cc",
            "utilities/types_util.cc",
            "utilities/ttl/db_ttl_impl.cc",
            "utilities/wal_filter.cc",
            "utilities/write_batch_with_index/write_batch_with_index.cc",
            "utilities/write_batch_with_index/write_batch_with_index_internal.cc",
            "utilities/transactions/lock/range/range_tree/lib/locktree/concurrent_tree.cc",
            "utilities/transactions/lock/range/range_tree/lib/locktree/keyrange.cc",
            "utilities/transactions/lock/range/range_tree/lib/locktree/lock_request.cc",
            "utilities/transactions/lock/range/range_tree/lib/locktree/locktree.cc",
            "utilities/transactions/lock/range/range_tree/lib/locktree/manager.cc",
            "utilities/transactions/lock/range/range_tree/lib/locktree/range_buffer.cc",
            "utilities/transactions/lock/range/range_tree/lib/locktree/treenode.cc",
            "utilities/transactions/lock/range/range_tree/lib/locktree/txnid_set.cc",
            "utilities/transactions/lock/range/range_tree/lib/locktree/wfg.cc",
            "utilities/transactions/lock/range/range_tree/lib/standalone_port.cc",
            "utilities/transactions/lock/range/range_tree/lib/util/dbt.cc",
            "utilities/transactions/lock/range/range_tree/lib/util/memarena.cc",
        },
        .flags = rocksdb_flags.items,
    });

    // Tools are excluded for C-API-only builds to avoid linker errors
    // from missing stress test symbols (DbStressCustomCompressionManager)
    if (!c_api_only) {
        librocksdb.root_module.addCSourceFiles(.{
            .root = rocks_path.path(b, "."),
            .files = &.{
                "tools/block_cache_analyzer/block_cache_trace_analyzer.cc",
                "tools/dump/db_dump_tool.cc",
                "tools/io_tracer_parser_tool.cc",
                "tools/ldb_cmd.cc",
                "tools/ldb_tool.cc",
                "tools/sst_dump_tool.cc",
                "tools/trace_analyzer_tool.cc",
            },
            .flags = rocksdb_flags.items,
        });
    }

    if (maybe_libsnappy) |libsnappy| not_yet_fetched: {
        const snappy_dep = b.lazyDependency("snappy", .{}) orelse
            break :not_yet_fetched;

        librocksdb.root_module.linkLibrary(libsnappy);
        librocksdb.root_module.addIncludePath(snappy_dep.path("."));

        libsnappy.root_module.link_libcpp = true;

        const flags = .{
            "-std=c++11",
            "-fno-exceptions",
            "-Wno-sign-compare",
        };

        libsnappy.root_module.addCSourceFiles(.{
            .root = snappy_dep.path("."),
            .files = &.{
                "snappy-c.cc",
                "snappy-sinksource.cc",
                "snappy-stubs-internal.cc",
                "snappy.cc",
            },
            .flags = &flags,
        });

        const build_version = b.addConfigHeader(.{
            .style = .{ .cmake = snappy_dep.path("snappy-stubs-public.h.in") },
            .include_path = "snappy-stubs-public.h",
        }, .{
            .PROJECT_VERSION_MAJOR = 1,
            .PROJECT_VERSION_MINOR = 2,
            .PROJECT_VERSION_PATCH = 2,
            // sys/uio.h only exists on POSIX systems, not Windows
            .HAVE_SYS_UIO_H_01 = @as(u8, @intFromBool(t.os.tag != .windows)),
        });

        libsnappy.root_module.addIncludePath(build_version.getOutputFile().dirname());
        librocksdb.root_module.addIncludePath(build_version.getOutputFile().dirname());
    }

    // platform dependent stuff
    if (t.cpu.arch == .aarch64) {
        librocksdb.root_module.addCSourceFile(.{
            .file = rocks_path.path(b, "util/crc32c_arm64.cc"),
            .flags = rocksdb_flags.items,
        });
    }

    if (t.os.tag != .windows) {
        librocksdb.root_module.addCMacro("ROCKSDB_PLATFORM_POSIX", "");
        librocksdb.root_module.addCMacro("ROCKSDB_LIB_IO_POSIX", "");
        librocksdb.root_module.addCSourceFiles(.{
            .root = rocks_path.path(b, "."),
            .files = &.{
                "port/port_posix.cc",
                "env/env_posix.cc",
                "env/fs_posix.cc",
                "env/io_posix.cc",
            },
            .flags = rocksdb_flags.items,
        });
    } else {
        librocksdb.root_module.addCMacro("OS_WIN", "");
        librocksdb.root_module.addCMacro("WIN32", "");
        librocksdb.root_module.addCMacro("_MBCS", "");
        librocksdb.root_module.addCMacro("WIN64", "");
        librocksdb.root_module.addCMacro("NOMINMAX", "");
        librocksdb.root_module.addCMacro("_WINDOWS", "");
        librocksdb.root_module.addCSourceFiles(.{
            .root = rocks_path.path(b, "."),
            .files = &.{
                "port/win/env_win.cc",
                "port/win/env_default.cc",
                "port/win/port_win.cc",
                "port/win/io_win.cc",
                "port/win/win_logger.cc",
                "port/win/win_thread.cc",
            },
            .flags = rocksdb_flags.items,
        });
        librocksdb.root_module.linkSystemLibrary("rpcrt4", .{});
        librocksdb.root_module.linkSystemLibrary("shlwapi", .{});
    }

    const os_name = switch (t.os.tag) {
        .macos => "OS_MACOSX",
        .linux => "OS_LINUX",
        .windows => null, // Already set OS_WIN above
        else => std.debug.panic("TODO: support target OS '{s}'", .{@tagName(t.os.tag)}),
    };
    if (os_name) |name| {
        librocksdb.root_module.addCMacro(name, "");
    }

    const build_version = b.addConfigHeader(.{
        .style = .{ .cmake = rocks_path.path(b, "util/build_version.cc.in") },
        .include_path = "util/build_version.cc",
    }, .{
        .GIT_MOD = 1,
        .GIT_SHA = null,
        .GIT_TAG = null,
        .GIT_DATE = null,
        .BUILD_DATE = null,
        .ROCKSDB_PLUGIN_EXTERNS = null,
        .ROCKSDB_PLUGIN_BUILTINS = null,
    });
    librocksdb.root_module.addCSourceFile(.{ .file = build_version.getOutputFile() });

    b.installArtifact(librocksdb);
}
