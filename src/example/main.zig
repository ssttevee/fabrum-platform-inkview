//! The reader shell on a PocketBook: `ReaderShell` hosted by
//! fabrum-platform-inkview. Built for the device by `zig build` into
//! `zig-out/pocketbook/ReaderShell.app`.
const std = @import("std");
const inkview = @import("fabrum-platform-inkview");
const ReaderShell = @import("ReaderShell.zig");

pub const std_options: std.Options = .{ .log_level = .info };

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
