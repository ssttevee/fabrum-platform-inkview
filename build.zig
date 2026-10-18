const std = @import("std");

/// The name of the example's `.app`, as it appears in the reader's
/// Applications list.
const app_name = "ReaderShell";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The platform module. It imports `fabrum`, which the app gives it (and
    // the renderer), so that the platform, the renderer and the app share
    // one fabrum built with `.platform = .none`:
    //
    //     const inkview = b.dependency("fabrum_platform_inkview", .{ .target = target, .optimize = optimize });
    //     @import("fabrum_platform_inkview").addFabrum(inkview.module("fabrum-platform-inkview"), fabrum_mod);
    const mod = platformModule(b, target, optimize, .public);

    const test_step = b.step("test", "Run tests");
    const app_step = b.step("app", "Cross-compile the example into " ++ app_name ++ ".app for a PocketBook B288 (arm-linux-gnueabi, glibc 2.38, Cortex-A7)");
    const emulator_step = b.step("emulator", "Build the example for x86_64 Linux, to run against the SDK's emulator libinkview.so in a Debian 12 container");

    // This package's own tests and example bring their own fabrum, lazily,
    // so that apps depending on the platform never fetch or build it.
    if (!b.isRoot()) return;

    // Tests, on the host, against a fake InkView.
    if (fabrumFor(b, target, optimize)) |fabrum| {
        addFabrum(mod, fabrum);
        const unit_tests = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);

        const example = exampleModule(b, target, optimize, fabrum, mod);
        const example_tests = b.addTest(.{ .root_module = example });
        test_step.dependOn(&b.addRunArtifact(example_tests).step);
    }

    // The device build: 32-bit ARMv7, soft-float EABI, glibc 2.38 dynamic
    // (the firmware's loader is /lib/ld-linux.so.3), tuned for the
    // Cortex-A7. `libinkview.so` is loaded at run time, so nothing but
    // glibc is linked.
    const device = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .linux,
        .abi = .gnueabi,
        .glibc_version = .{ .major = 2, .minor = 38, .patch = 0 },
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 },
    });
    if (exampleFor(b, device, .ReleaseSmall)) |exe| {
        const install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = "pocketbook" } },
            .dest_sub_path = app_name ++ ".app",
        });
        // a launcher that keeps the example's output in a log next to it
        const launcher = b.addInstallFileWithDir(b.path("src/example/launcher.sh"), .{ .custom = "pocketbook" }, app_name ++ "-log.app");
        app_step.dependOn(&install.step);
        app_step.dependOn(&launcher.step);
        b.getInstallStep().dependOn(app_step);
    }

    // The emulator build: the same program for x86_64 Linux. The SDK's
    // emulator libinkview.so draws into a GTK 2 window and needs Debian
    // 12's libraries, so it runs in a container, not on macOS.
    const emulator = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu });
    if (exampleFor(b, emulator, optimize)) |exe| {
        const install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = "emulator" } },
            .dest_sub_path = app_name,
        });
        emulator_step.dependOn(&install.step);
    }
}

/// Gives the platform module, and the renderer inside it, the app's
/// `fabrum`.
pub fn addFabrum(platform: *std.Build.Module, fabrum: *std.Build.Module) void {
    platform.addImport("fabrum", fabrum);
    platform.import_table.get("fabrum-renderer-z2d").?.addImport("fabrum", fabrum);
}

/// The platform module for a target, with its renderer: the public one
/// (`addModule`, for apps) or a private copy for another target.
fn platformModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, kind: enum { public, private }) *std.Build.Module {
    const renderer = b.dependency("fabrum_renderer_z2d", .{ .target = target, .optimize = optimize }).module("fabrum-renderer-z2d");
    const options: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fabrum-renderer-z2d", .module = renderer }},
        // `libinkview.so` is opened with dlopen
        .link_libc = true,
    };
    return switch (kind) {
        .public => b.addModule("fabrum-platform-inkview", options),
        .private => b.createModule(options),
    };
}

/// fabrum built for `none`, for this package's tests and example, or null
/// until the lazy dependency is fetched.
fn fabrumFor(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?*std.Build.Module {
    const dep = b.lazyDependency("fabrum", .{ .target = target, .optimize = optimize, .platform = .none }) orelse return null;
    return dep.module("fabrum");
}

fn exampleModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, fabrum: *std.Build.Module, platform: *std.Build.Module) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/example/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fabrum", .module = fabrum },
            .{ .name = "fabrum-platform-inkview", .module = platform },
        },
        .link_libc = true,
    });
}

/// The example executable for a target other than the host's, with its
/// own fabrum, renderer and platform modules for that target.
fn exampleFor(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?*std.Build.Step.Compile {
    const fabrum = fabrumFor(b, target, optimize) orelse return null;
    const platform = platformModule(b, target, optimize, .private);
    addFabrum(platform, fabrum);
    return b.addExecutable(.{
        .name = app_name,
        .root_module = exampleModule(b, target, optimize, fabrum, platform),
    });
}
