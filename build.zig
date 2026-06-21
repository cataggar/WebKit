const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

// Thin-driver build for Bun's WebKit fork (JSCOnly static JSC).
//
// Replaces the previous `build.ts` Bun script. This does NOT replace WebKit's
// CMake build graph or code generation — it only orchestrates the same two
// CMake phases (configure, then `--build --target jsc`) with identical flags.
//
// Usage:
//   zig build                       # debug (default)
//   zig build -Dconfig=release
//   zig build -Dconfig=lto
//   zig build -Dconfig=release -Dprint=true   # dry-run: print cmake argv, run nothing
//   zig build configure -Dconfig=debug        # configure only
//
// Toolchain: pinned in `.zig-version`. Parity target: oven-sh/WebKit build.ts.

const Config = enum { debug, release, lto };

pub fn build(b: *std.Build) void {
    const config = b.option(Config, "config", "Build configuration: debug | release | lto") orelse .debug;
    const print_only = b.option(bool, "print", "Print the cmake commands and exit without running") orelse false;

    const host = b.graph.host.result;
    const is_mac = host.os.tag == .macos;
    const is_linux = host.os.tag == .linux;
    const is_windows = host.os.tag == .windows;
    const is_arm64 = host.cpu.arch == .aarch64;

    // The WebKit source root is the directory containing this build.zig.
    const src_dir = b.build_root.path orelse ".";
    const build_dir_rel = switch (config) {
        .debug => "WebKitBuild/Debug",
        .release => "WebKitBuild/Release",
        .lto => "WebKitBuild/ReleaseLTO",
    };
    const build_dir_abs = b.pathJoin(&.{ src_dir, build_dir_rel });

    // Tool detection (mirrors build.ts findExecutable fallbacks; returns full paths).
    const ccache = which(b, &.{"ccache"});
    const cc_base = if (is_windows)
        which(b, &.{ "clang-cl.exe", "clang-cl" }) orelse "clang-cl"
    else
        which(b, &.{ "clang-21", "clang" }) orelse "clang";
    const cxx_base = if (is_windows)
        which(b, &.{ "clang-cl.exe", "clang-cl" }) orelse "clang-cl"
    else
        which(b, &.{ "clang++-21", "clang++" }) orelse "clang++";

    const a = b.allocator;
    var flags: std.ArrayList([]const u8) = .empty;

    // --- Common flags (build.ts getCommonFlags) ---
    flags.appendSlice(a, &.{
        "-DPORT=JSCOnly",
        "-DENABLE_STATIC_JSC=ON",
        "-DALLOW_LINE_AND_COLUMN_NUMBER_IN_BUILTINS=ON",
        "-DUSE_THIN_ARCHIVES=OFF",
        "-DUSE_BUN_JSC_ADDITIONS=ON",
        "-DUSE_BUN_EVENT_LOOP=ON",
        "-DENABLE_FTL_JIT=ON",
        "-DENABLE_MEDIA_SOURCE=OFF",
        "-DENABLE_MEDIA_STREAM=OFF",
        "-DENABLE_WEB_RTC=OFF",
        "-G",
        "Ninja",
    }) catch @panic("OOM");

    // Compiler / ccache launcher.
    if (ccache) |cc| {
        flags.append(a, b.fmt("-DCMAKE_C_COMPILER_LAUNCHER={s}", .{cc})) catch @panic("OOM");
        flags.append(a, b.fmt("-DCMAKE_CXX_COMPILER_LAUNCHER={s}", .{cc})) catch @panic("OOM");
        flags.append(a, b.fmt("-DCMAKE_C_COMPILER={s}", .{cc_base})) catch @panic("OOM");
        flags.append(a, b.fmt("-DCMAKE_CXX_COMPILER={s}", .{cxx_base})) catch @panic("OOM");
    } else {
        flags.append(a, b.fmt("-DCMAKE_C_COMPILER={s}", .{cc_base})) catch @panic("OOM");
        flags.append(a, b.fmt("-DCMAKE_CXX_COMPILER={s}", .{cxx_base})) catch @panic("OOM");
    }

    // Platform-specific common flags.
    if (is_mac or is_linux) {
        flags.append(a, "-DENABLE_REMOTE_INSPECTOR=ON") catch @panic("OOM");
    } else if (is_windows) {
        const lld_link = which(b, &.{ "lld-link.exe", "lld-link" }) orelse "lld-link";
        const icu = windowsIcuPaths(b, src_dir, config, is_arm64);
        flags.appendSlice(a, &.{
            "-DENABLE_REMOTE_INSPECTOR=ON",
            "-DUSE_VISIBILITY_ATTRIBUTE=1",
        }) catch @panic("OOM");
        flags.append(a, b.fmt("-DCMAKE_LINKER={s}", .{lld_link})) catch @panic("OOM");
        flags.append(a, b.fmt("-DICU_ROOT={s}", .{icu.root})) catch @panic("OOM");
        flags.append(a, b.fmt("-DICU_LIBRARY={s}", .{icu.library})) catch @panic("OOM");
        flags.append(a, b.fmt("-DICU_INCLUDE_DIR={s}", .{icu.include})) catch @panic("OOM");
        flags.append(a, b.fmt("-DICU_DATA_LIBRARY_RELEASE={s}", .{icu.data_lib})) catch @panic("OOM");
        flags.append(a, b.fmt("-DICU_I18N_LIBRARY_RELEASE={s}", .{icu.i18n_lib})) catch @panic("OOM");
        flags.append(a, b.fmt("-DICU_UC_LIBRARY_RELEASE={s}", .{icu.uc_lib})) catch @panic("OOM");
        flags.appendSlice(a, &.{
            "-DCMAKE_C_FLAGS=/DU_STATIC_IMPLEMENTATION",
            "-DCMAKE_CXX_FLAGS=/DU_STATIC_IMPLEMENTATION /clang:-fno-c++-static-destructors",
        }) catch @panic("OOM");
    }

    // --- Per-config flags (build.ts getBuildFlags) ---
    switch (config) {
        .debug => {
            flags.appendSlice(a, &.{
                "-DCMAKE_BUILD_TYPE=Debug",
                "-DENABLE_BUN_SKIP_FAILING_ASSERTIONS=ON",
                "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
                "-DENABLE_REMOTE_INSPECTOR=ON",
                "-DUSE_VISIBILITY_ATTRIBUTE=1",
            }) catch @panic("OOM");
            if (is_mac or is_linux) {
                flags.append(a, "-DENABLE_SANITIZERS=address") catch @panic("OOM");
            }
            if (is_windows) {
                flags.append(a, "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDebug") catch @panic("OOM");
            }
        },
        .lto => {
            flags.append(a, "-DCMAKE_BUILD_TYPE=Release") catch @panic("OOM");
            if (is_windows) {
                flags.appendSlice(a, &.{
                    "-DCMAKE_C_FLAGS=/DU_STATIC_IMPLEMENTATION -flto=full",
                    "-DCMAKE_CXX_FLAGS=/DU_STATIC_IMPLEMENTATION /clang:-fno-c++-static-destructors -flto=full",
                    "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
                }) catch @panic("OOM");
            } else {
                flags.appendSlice(a, &.{
                    "-DCMAKE_C_FLAGS=-flto=full",
                    "-DCMAKE_CXX_FLAGS=-flto=full",
                }) catch @panic("OOM");
            }
        },
        .release => {
            flags.append(a, "-DCMAKE_BUILD_TYPE=RelWithDebInfo") catch @panic("OOM");
            if (is_windows) {
                flags.append(a, "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded") catch @panic("OOM");
            }
        },
    }

    // CMake configure argv: cmake [flags...] -S <srcDir> -B <buildDir>.
    // Absolute -S/-B is the supported form and self-creates the build dir, so no
    // cwd or pre-mkdir is required (functionally identical to build.ts).
    var configure_argv: std.ArrayList([]const u8) = .empty;
    configure_argv.append(a, "cmake") catch @panic("OOM");
    configure_argv.appendSlice(a, flags.items) catch @panic("OOM");
    configure_argv.appendSlice(a, &.{ "-S", src_dir, "-B", build_dir_abs }) catch @panic("OOM");

    const build_type = switch (config) {
        .debug => "Debug",
        .lto => "Release",
        .release => "RelWithDebInfo",
    };
    const build_argv = [_][]const u8{
        "cmake", "--build", build_dir_abs, "--config", build_type, "--target", "jsc",
    };

    // Dry-run: print exactly what would be executed and stop.
    if (print_only) {
        std.debug.print("# config: {s}\n# cwd:    {s}\n", .{ @tagName(config), build_dir_abs });
        if (is_mac) std.debug.print("# env ICU_INCLUDE_DIRS={s}\n", .{macIcuIncludeDir(is_arm64)});
        std.debug.print("configure: ", .{});
        printArgv(configure_argv.items);
        std.debug.print("build:     ", .{});
        printArgv(&build_argv);
        return;
    }

    // Configure step.
    const configure = b.addSystemCommand(configure_argv.items);
    configure.has_side_effects = true; // cmake state lives in the build dir, not Zig's cache
    if (is_mac) configure.setEnvironmentVariable("ICU_INCLUDE_DIRS", macIcuIncludeDir(is_arm64));

    // Build step (depends on configure).
    const build_jsc = b.addSystemCommand(&build_argv);
    build_jsc.has_side_effects = true;
    if (is_mac) build_jsc.setEnvironmentVariable("ICU_INCLUDE_DIRS", macIcuIncludeDir(is_arm64));
    build_jsc.step.dependOn(&configure.step);

    // Named steps.
    const configure_step = b.step("configure", "Run CMake configure only");
    configure_step.dependOn(&configure.step);

    const jsc_step = b.step("jsc", "Configure and build the JSC target (default)");
    jsc_step.dependOn(&build_jsc.step);

    b.default_step.dependOn(&build_jsc.step);
}

/// Configure-time PATH lookup; returns the first match's full path (like Bun.which).
fn which(b: *std.Build, names: []const []const u8) ?[]const u8 {
    return b.findProgram(names, &.{}) catch null;
}

/// Configure-time directory existence check (for Windows vcpkg triplet detection).
fn dirExists(b: *std.Build, path: []const u8) bool {
    Io.Dir.cwd().access(b.graph.io, path, .{}) catch return false;
    return true;
}

fn printArgv(argv: []const []const u8) void {
    for (argv, 0..) |arg, i| {
        if (i != 0) std.debug.print(" ", .{});
        if (std.mem.indexOfScalar(u8, arg, ' ') != null) {
            std.debug.print("\"{s}\"", .{arg});
        } else {
            std.debug.print("{s}", .{arg});
        }
    }
    std.debug.print("\n", .{});
}

fn macIcuIncludeDir(is_arm64: bool) []const u8 {
    return if (is_arm64)
        "/opt/homebrew/opt/icu4c/include"
    else
        "/usr/local/opt/icu4c/include";
}

const IcuPaths = struct {
    root: []const u8,
    library: []const u8,
    include: []const u8,
    data_lib: []const u8,
    i18n_lib: []const u8,
    uc_lib: []const u8,
};

fn windowsIcuPaths(b: *std.Build, src_dir: []const u8, config: Config, is_arm64: bool) IcuPaths {
    // Auto-detect vcpkg triplet: prefer arm64 if present, else x64 (build.ts logic).
    const arm64_root = b.pathJoin(&.{ src_dir, "vcpkg_installed", "arm64-windows-static" });
    const x64_root = b.pathJoin(&.{ src_dir, "vcpkg_installed", "x64-windows-static" });
    _ = is_arm64;
    const root = if (dirExists(b, arm64_root)) arm64_root else x64_root;

    const is_debug = config == .debug;
    const lib_dir = if (is_debug)
        b.pathJoin(&.{ root, "debug", "lib" })
    else
        b.pathJoin(&.{ root, "lib" });
    const suffix: []const u8 = if (is_debug) "d" else "";
    return .{
        .root = root,
        .library = lib_dir,
        .include = b.pathJoin(&.{ root, "include" }),
        .data_lib = b.pathJoin(&.{ lib_dir, b.fmt("sicudt{s}.lib", .{suffix}) }),
        .i18n_lib = b.pathJoin(&.{ lib_dir, b.fmt("sicuin{s}.lib", .{suffix}) }),
        .uc_lib = b.pathJoin(&.{ lib_dir, b.fmt("sicuuc{s}.lib", .{suffix}) }),
    };
}
