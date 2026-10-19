//! The reader shell on a PocketBook: `ReaderShell` hosted by
//! fabrum-platform-inkview. Built for the device by `zig build` into
//! `zig-out/pocketbook/ReaderShell.app`.
const std = @import("std");
const builtin = @import("builtin");
const inkview = @import("fabrum-platform-inkview");
const ReaderShell = @import("ReaderShell.zig");

pub const std_options: std.Options = .{ .log_level = .info };

comptime {
    if (builtin.os.tag == .linux and builtin.cpu.arch == .arm and builtin.abi == .gnueabi) {
        // Zig 0.17 selects /dev/urandom for this libc target. The B288
        // kernel has no getrandom; keep the example off that path.
        if (!builtin.link_libc or
            @TypeOf(std.posix.system.getrandom) != void or
            @TypeOf(std.posix.system.arc4random_buf) != void or
            !@hasField(std.Io.Threaded.RandomFile, "fd"))
            @compileError("the device build must use std's /dev/urandom entropy path");
    }
}

pub fn main(init: std.process.Init) !void {
    // the emulator's library lives wherever it was unpacked
    const library: [*:0]const u8 = if (std.c.getenv("INKVIEW_LIBRARY")) |path| path else "libinkview.so";
    try inkview.run(ReaderShell, init.gpa, init.io, .{}, .{
        .library = library,
        .fonts = &.{.{ .name = "Go", .data = @embedFile("fonts/Go-Regular.ttf") }},
        // Back asks the shell, which doesn't guard, so it closes
        .close_key = .back,
        .context = ReaderShell.layout_capacity,
    });
}

test {
    _ = ReaderShell;
}
