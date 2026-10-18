//! fabrum-platform-inkview: fabrum on PocketBook e-readers, through
//! libinkview, as an external platform on fabrum's `none` platform. The
//! app's own code hosts the runtime; this package is that code for
//! InkView: its event loop drives the frames, the z2d renderer draws the
//! damage into the panel's gray framebuffer, the refresh hints choose the
//! e-ink update, and InkView's dialogs, menus and keyboard are the
//! services.
//!
//! ```zig
//! const inkview = @import("fabrum-platform-inkview");
//! pub fn main(init: std.process.Init) !void {
//!     try inkview.run(Reader, init.gpa, init.io, .{}, .{
//!         .fonts = &.{.{ .name = "Go", .data = @embedFile("fonts/Go-Regular.ttf") }},
//!     });
//! }
//! ```
//!
//! **fabrum is the app's.** The app gives this module, and the renderer
//! inside it, the `fabrum` it uses (built with `.platform = .none`):
//! `@import("fabrum_platform_inkview").addFabrum(module, fabrum_mod)` in
//! its build.zig.
//!
//! `libinkview.so` is loaded at run time (`inkview.Api.load`), so the
//! binary links only glibc and runs on every firmware that has the
//! functions it needs, doing without the optional ones.
const std = @import("std");

const host = @import("host.zig");

/// The InkView functions, types and constants this package uses, and the
/// loader.
pub const inkview = @import("inkview.zig");
/// Refresh hints to e-ink updates.
pub const refresh = @import("refresh.zig");
/// Hardware keys to fabrum keys.
pub const KeyMap = @import("keys.zig").KeyMap;
/// A fake InkView, for testing hosts and apps without a device.
pub const fake = @import("fake.zig");

pub const Options = host.Options;
pub const App = host.App;
/// What an e-reader is to fabrum.
pub const capabilities = host.capabilities;
/// The event a post from another thread wakes the loop with.
pub const wake_event = host.wake_event;

/// Loads `libinkview.so` and runs `Root` in it. Never returns on the
/// device: InkView ends the process when the app closes.
pub fn run(comptime Root: type, gpa: std.mem.Allocator, io: std.Io, props: Root.Props, options: Options) !void {
    const api = try inkview.Api.load(options.library);
    return App(Root).run(gpa, io, api, props, options);
}

test {
    _ = inkview;
    _ = refresh;
    _ = KeyMap;
    _ = host;
    _ = fake;
    _ = @import("host_test.zig");
}
