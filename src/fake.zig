//! A fake InkView: the functions of `inkview.Api` as a test double, so
//! the host can be driven without a device. It keeps a gray framebuffer,
//! the handler, the timers, and a log of every update, dialog, menu and
//! keyboard, and plays the user: taps, drags, keys, dialog answers,
//! keyboard results, the clock. It mirrors what the library does around
//! its modal UIs (saves and restores the pixels under them, sends
//! `EVT_SHOW` after the keyboard), so a host that forgets to repaint
//! fails here.
//!
//! One fake per process, like the library: `state`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const inkview = @import("inkview.zig");

pub const Update = struct {
    kind: Kind,
    x: c_int = 0,
    y: c_int = 0,
    w: c_int = 0,
    h: c_int = 0,

    pub const Kind = enum { full, partial, dynamic, a2 };
};

pub const Timer = struct {
    name: []const u8,
    proc: inkview.TimerProc,
    due_ms: i64,
    hard: bool,
};

pub const Event = struct { kind: c_int, par1: c_int, par2: c_int };

pub const Message = struct { icon: inkview.DialogIcon, title: []u8, text: []u8, timeout: c_int };

pub const Dialog = struct {
    icon: inkview.DialogIcon,
    title: []u8,
    text: []u8,
    buttons: [3]?[]u8,
    callback: inkview.DialogHandler,
    saved: []u8,
};

pub const Menu = struct {
    items: [*]inkview.MenuItem,
    x: c_int,
    y: c_int,
    callback: inkview.MenuHandler,
    saved: []u8,

    /// The entries of the top-level array.
    pub fn top(self: Menu) []inkview.MenuItem {
        var n: usize = 0;
        while (self.items[n].type != .end) n += 1;
        return self.items[0..n];
    }
};

pub const Keyboard = struct {
    title: []u8,
    buffer: [*:0]u8,
    maxlen: c_int,
    flags: inkview.KeyboardFlags,
    callback: inkview.KeyboardHandler,
    saved: []u8,
};

pub const Options = struct {
    width: c_int = 758,
    height: c_int = 1024,
    /// Rows this many bytes apart, more than the width to catch hosts that
    /// assume packed rows.
    padding: c_int = 6,
    depth: c_int = 8,
    dpi: c_int = 212,
    panel_height: c_int = 40,
    /// Which optional functions the fake library has.
    has_a2: bool = true,
    has_dynamic: bool = true,
    has_dpi: bool = true,
    has_directory_selector: bool = false,
};

pub const State = struct {
    gpa: Allocator,
    options: Options,
    /// The screen's size in the current orientation.
    width: c_int,
    height: c_int,
    orientation: inkview.Orientation = .portrait,
    panel_type: inkview.PanelType = .{ .enabled = true },
    framebuffer: []u8 = &.{},
    canvas: inkview.Canvas = undefined,
    handler: ?inkview.Handler = null,
    now_ms: i64 = 0,
    timers: std.ArrayList(Timer) = .empty,
    updates: std.ArrayList(Update) = .empty,
    /// Events sent with `SendEvent`, delivered by `pump`.
    queue: std.ArrayList(Event) = .empty,
    messages: std.ArrayList(Message) = .empty,
    dialogs: std.ArrayList(Dialog) = .empty,
    menus: std.ArrayList(Menu) = .empty,
    keyboards: std.ArrayList(Keyboard) = .empty,
    directory_requests: usize = 0,
    orientation_sets: std.ArrayList(inkview.Orientation) = .empty,
    stretches: usize = 0,
    closed: bool = false,
    /// How many times the handler was entered, for re-entrancy checks.
    depth: u32 = 0,
    max_depth: u32 = 0,
};

pub var state: State = undefined;

pub fn init(gpa: Allocator, options: Options) !void {
    state = .{ .gpa = gpa, .options = options, .width = options.width, .height = options.height };
    try layoutFramebuffer();
}

pub fn deinit() void {
    const gpa = state.gpa;
    gpa.free(state.framebuffer);
    state.timers.deinit(gpa);
    state.updates.deinit(gpa);
    state.queue.deinit(gpa);
    for (state.messages.items) |m| {
        gpa.free(m.title);
        gpa.free(m.text);
    }
    state.messages.deinit(gpa);
    for (state.dialogs.items) |d| freeDialog(d);
    state.dialogs.deinit(gpa);
    for (state.menus.items) |m| gpa.free(m.saved);
    state.menus.deinit(gpa);
    for (state.keyboards.items) |k| freeKeyboard(k);
    state.keyboards.deinit(gpa);
    state.orientation_sets.deinit(gpa);
    state = undefined;
}

fn freeDialog(d: Dialog) void {
    state.gpa.free(d.title);
    state.gpa.free(d.text);
    for (d.buttons) |b| if (b) |s| state.gpa.free(s);
    state.gpa.free(d.saved);
}

fn freeKeyboard(k: Keyboard) void {
    state.gpa.free(k.title);
    state.gpa.free(k.saved);
}

/// (Re)allocates the framebuffer for the current size, white.
fn layoutFramebuffer() !void {
    state.gpa.free(state.framebuffer);
    const stride: usize = @intCast(state.width + state.options.padding);
    state.framebuffer = try state.gpa.alloc(u8, stride * @as(usize, @intCast(state.height)));
    @memset(state.framebuffer, 0xff);
    state.canvas = .{
        .width = state.width,
        .height = state.height,
        .scanline = @intCast(stride),
        .depth = state.options.depth,
        .clipx1 = 0,
        .clipx2 = state.width - 1,
        .clipy1 = 0,
        .clipy2 = state.height - 1,
        .addr = state.framebuffer.ptr,
    };
}

/// The fake as an `Api`, with the optional functions `Options` allow.
pub fn api() inkview.Api {
    return .{
        .InkViewMain = InkViewMain,
        .CloseApp = CloseApp,
        .SendEvent = SendEvent,
        .SetHardTimer = SetHardTimer,
        .SetWeakTimer = SetWeakTimer,
        .ClearTimer = ClearTimer,
        .ScreenWidth = ScreenWidth,
        .ScreenHeight = ScreenHeight,
        .GetCanvas = GetCanvas,
        .SetOrientation = SetOrientation,
        .SetPanelType = SetPanelType,
        .PanelHeight = PanelHeight,
        .Stretch = Stretch,
        .FullUpdate = FullUpdate,
        .PartialUpdate = PartialUpdate,
        .Message = MessageFn,
        .Dialog3 = Dialog3,
        .OpenMenu = OpenMenu,
        .OpenKeyboard = OpenKeyboard,
        .DynamicUpdateA2 = if (state.options.has_a2) DynamicUpdateA2 else null,
        .DynamicUpdate = if (state.options.has_dynamic) DynamicUpdate else null,
        .get_screen_dpi = if (state.options.has_dpi) get_screen_dpi else null,
        .OpenDirectorySelector = if (state.options.has_directory_selector) OpenDirectorySelector else null,
    };
}

// Driving the host

/// Calls the handler with one event, as the loop would.
pub fn send(kind: inkview.Event, par1: c_int, par2: c_int) c_int {
    return sendRaw(@backingInt(kind), par1, par2);
}

fn sendRaw(kind: c_int, par1: c_int, par2: c_int) c_int {
    const h = state.handler orelse return 0;
    state.depth += 1;
    state.max_depth = @max(state.max_depth, state.depth);
    defer state.depth -= 1;
    return h(kind, par1, par2);
}

/// A finger down and up at a pixel.
pub fn tap(x: c_int, y: c_int) void {
    _ = send(.pointer_down, x, y);
    _ = send(.pointer_up, x, y);
}

/// A finger down, `steps` moves (drags past the dead zone), and up.
pub fn drag(from_x: c_int, from_y: c_int, to_x: c_int, to_y: c_int, steps: u8) void {
    _ = send(.pointer_down, from_x, from_y);
    var i: c_int = 1;
    while (i <= steps) : (i += 1) {
        _ = send(.pointer_drag, from_x + @divTrunc((to_x - from_x) * i, steps), from_y + @divTrunc((to_y - from_y) * i, steps));
    }
    _ = send(.pointer_up, to_x, to_y);
}

/// A hardware key pressed and released.
pub fn pressKey(key: inkview.Key) c_int {
    const taken = send(.key_press, @backingInt(key), 0);
    _ = send(.key_release, @backingInt(key), 0);
    return taken;
}

/// Moves the clock on and runs the timers that came due, in order.
pub fn advance(ms: i64) void {
    const until = state.now_ms + ms;
    while (nextDue(until)) |i| {
        const t = state.timers.orderedRemove(i);
        state.now_ms = @max(state.now_ms, t.due_ms);
        t.proc();
    }
    state.now_ms = until;
}

fn nextDue(until: i64) ?usize {
    var best: ?usize = null;
    for (state.timers.items, 0..) |t, i| {
        if (t.due_ms > until) continue;
        if (best) |b| if (t.due_ms >= state.timers.items[b].due_ms) continue;
        best = i;
    }
    return best;
}

/// The timer with `name`, if armed.
pub fn timer(name: []const u8) ?Timer {
    for (state.timers.items) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

/// Delivers the events `SendEvent` queued.
pub fn pump() void {
    while (state.queue.items.len > 0) {
        const e = state.queue.orderedRemove(0);
        _ = sendRaw(e.kind, e.par1, e.par2);
    }
}

/// Answers the oldest dialog with a button (1–3) or -1, restoring the
/// screen under it and refreshing, as the library does.
pub fn answerDialog(button: c_int) void {
    const d = state.dialogs.orderedRemove(0);
    defer freeDialog(d);
    @memcpy(state.framebuffer, d.saved);
    state.updates.append(state.gpa, .{ .kind = .full }) catch @panic("OOM");
    d.callback(button);
}

/// Chooses the item at `index` (as in `imenu.index`) of the oldest menu,
/// or -1 to dismiss it.
pub fn chooseMenu(index: c_int) void {
    const m = state.menus.orderedRemove(0);
    defer state.gpa.free(m.saved);
    @memcpy(state.framebuffer, m.saved);
    m.callback(index);
}

/// The user typed `text` and pressed OK, or cancelled with null: the
/// buffer is filled, the screen under the keyboard restored, the callback
/// called, and `EVT_SHOW` sent unless the flags said not to.
pub fn keyboardResult(text: ?[]const u8) void {
    const k = state.keyboards.orderedRemove(0);
    defer freeKeyboard(k);
    @memcpy(state.framebuffer, k.saved);
    if (!k.flags.no_update_after_close) state.updates.append(state.gpa, .{ .kind = .full }) catch @panic("OOM");
    if (text) |t| {
        const max: usize = @intCast(k.maxlen);
        const n = @min(t.len, max);
        @memcpy(k.buffer[0..n], t[0..n]);
        k.buffer[n] = 0;
        k.callback(k.buffer);
    } else {
        k.callback(null);
    }
    if (!k.flags.no_evt_show) _ = send(.show, 0, 0);
}

/// The g-sensor turned the device: the library rotates the screen when
/// the app sets the orientation.
pub fn rotate(orientation: inkview.Orientation) void {
    _ = send(.orientation, @backingInt(orientation), 0);
}

/// The whole framebuffer's pixel rows, `width` wide, for comparisons.
pub fn row(y: usize) []const u8 {
    const stride: usize = @intCast(state.canvas.scanline);
    return state.framebuffer[y * stride ..][0..@intCast(state.width)];
}

/// The fake's clock, for `Options.clock`.
pub fn clock() std.Io.Timestamp {
    return std.Io.Timestamp.zero.addDuration(.fromMilliseconds(state.now_ms));
}

/// Clears the logs of updates, keeping everything else.
pub fn clearUpdates() void {
    state.updates.clearRetainingCapacity();
}

/// The kinds of the updates logged, in order (the first 64), good until
/// the next call.
pub fn kinds() []const Update.Kind {
    const S = struct {
        var buffer: [64]Update.Kind = undefined;
    };
    const n = @min(S.buffer.len, state.updates.items.len);
    for (state.updates.items[0..n], S.buffer[0..n]) |u, *k| k.* = u.kind;
    return S.buffer[0..n];
}

// The library's functions

/// Stores the handler and delivers `EVT_INIT` and `EVT_SHOW`, then
/// returns (the real one runs the loop until the app exits).
fn InkViewMain(h: inkview.Handler) callconv(.c) void {
    state.handler = h;
    _ = sendRaw(@backingInt(inkview.Event.init), 0, 0);
    _ = sendRaw(@backingInt(inkview.Event.show), 0, 0);
}

fn CloseApp() callconv(.c) void {
    state.closed = true;
}

fn SendEvent(h: inkview.Handler, kind: c_int, par1: c_int, par2: c_int) callconv(.c) void {
    std.debug.assert(h == state.handler.?);
    state.queue.append(state.gpa, .{ .kind = kind, .par1 = par1, .par2 = par2 }) catch @panic("OOM");
}

/// The pixels under a modal UI, restored when it closes. The UI then
/// draws itself (`drawModal`).
fn saveScreen() []u8 {
    const saved = state.gpa.dupe(u8, state.framebuffer) catch @panic("OOM");
    drawModal();
    return saved;
}

/// The gray a modal UI is drawn in, a band across the middle of the
/// screen, so a host that draws over one is caught (`modalShown`).
const modal_gray = 0x55;
const modal_rows = 8;

fn drawModal() void {
    const stride: usize = @intCast(state.canvas.scanline);
    const top: usize = @intCast(@divTrunc(state.height, 2));
    for (top..top + modal_rows) |y| @memset(state.framebuffer[y * stride ..][0..@intCast(state.width)], modal_gray);
}

/// Whether the last modal UI drawn is still on the framebuffer, as the
/// library drew it.
pub fn modalShown() bool {
    const top: usize = @intCast(@divTrunc(state.height, 2));
    for (top..top + modal_rows) |y| {
        for (row(y)) |px| if (px != modal_gray) return false;
    }
    return true;
}

/// A copy of a C string, for the logs.
fn dupe(s: [*:0]const u8) []u8 {
    return state.gpa.dupe(u8, std.mem.span(s)) catch @panic("OOM");
}

fn setTimer(name: [*:0]const u8, proc: inkview.TimerProc, ms: c_int, hard: bool) void {
    // a timer is its function: setting it again replaces it
    for (state.timers.items, 0..) |t, i| if (t.proc == proc) {
        _ = state.timers.orderedRemove(i);
        break;
    };
    state.timers.append(state.gpa, .{ .name = std.mem.span(name), .proc = proc, .due_ms = state.now_ms + ms, .hard = hard }) catch @panic("OOM");
}

fn SetHardTimer(name: [*:0]const u8, proc: inkview.TimerProc, ms: c_int) callconv(.c) void {
    setTimer(name, proc, ms, true);
}

fn SetWeakTimer(name: [*:0]const u8, proc: inkview.TimerProc, ms: c_int) callconv(.c) void {
    setTimer(name, proc, ms, false);
}

fn ClearTimer(proc: inkview.TimerProc) callconv(.c) void {
    for (state.timers.items, 0..) |t, i| if (t.proc == proc) {
        _ = state.timers.orderedRemove(i);
        return;
    };
}

fn ScreenWidth() callconv(.c) c_int {
    return state.width;
}

fn ScreenHeight() callconv(.c) c_int {
    return state.height;
}

fn GetCanvas() callconv(.c) ?*inkview.Canvas {
    return &state.canvas;
}

fn SetOrientation(n: inkview.Orientation) callconv(.c) void {
    state.orientation_sets.append(state.gpa, n) catch @panic("OOM");
    const turned = n.isLandscape() != state.orientation.isLandscape();
    state.orientation = n;
    if (turned) {
        std.mem.swap(c_int, &state.width, &state.height);
        layoutFramebuffer() catch @panic("OOM");
    }
}

fn SetPanelType(t: inkview.PanelType) callconv(.c) void {
    state.panel_type = t;
}

fn PanelHeight() callconv(.c) c_int {
    return if (state.panel_type.enabled) state.options.panel_height else 0;
}

fn Stretch(_: [*]const u8, _: c_int, _: c_int, _: c_int, _: c_int, _: c_int, _: c_int, _: c_int, _: c_int, _: c_int) callconv(.c) void {
    state.stretches += 1;
}

fn logUpdate(kind: Update.Kind, x: c_int, y: c_int, w: c_int, h: c_int) void {
    state.updates.append(state.gpa, .{ .kind = kind, .x = x, .y = y, .w = w, .h = h }) catch @panic("OOM");
}

fn FullUpdate() callconv(.c) void {
    logUpdate(.full, 0, 0, state.width, state.height);
}

fn PartialUpdate(x: c_int, y: c_int, w: c_int, h: c_int) callconv(.c) void {
    logUpdate(.partial, x, y, w, h);
}

fn DynamicUpdate(x: c_int, y: c_int, w: c_int, h: c_int) callconv(.c) void {
    logUpdate(.dynamic, x, y, w, h);
}

fn DynamicUpdateA2(x: c_int, y: c_int, w: c_int, h: c_int) callconv(.c) void {
    logUpdate(.a2, x, y, w, h);
}

fn get_screen_dpi() callconv(.c) c_int {
    return state.options.dpi;
}

fn MessageFn(icon: inkview.DialogIcon, title: [*:0]const u8, text: [*:0]const u8, timeout: c_int) callconv(.c) void {
    state.messages.append(state.gpa, .{
        .icon = icon,
        .title = dupe(title),
        .text = dupe(text),
        .timeout = timeout,
    }) catch @panic("OOM");
    // 6.x pumps the loop while the box is up: timers fire
    advance(@max(timeout, 1));
}

fn Dialog3(icon: inkview.DialogIcon, title: [*:0]const u8, text: [*:0]const u8, b1: ?[*:0]const u8, b2: ?[*:0]const u8, b3: ?[*:0]const u8, cb: inkview.DialogHandler) callconv(.c) void {
    state.dialogs.append(state.gpa, .{
        .icon = icon,
        .title = dupe(title),
        .text = dupe(text),
        .buttons = .{
            if (b1) |b| dupe(b) else null,
            if (b2) |b| dupe(b) else null,
            if (b3) |b| dupe(b) else null,
        },
        .callback = cb,
        .saved = saveScreen(),
    }) catch @panic("OOM");
}

fn OpenMenu(items: [*]inkview.MenuItem, _: c_int, x: c_int, y: c_int, cb: inkview.MenuHandler) callconv(.c) void {
    state.menus.append(state.gpa, .{ .items = items, .x = x, .y = y, .callback = cb, .saved = saveScreen() }) catch @panic("OOM");
}

fn OpenKeyboard(title: [*:0]const u8, buffer: [*:0]u8, maxlen: c_int, flags: inkview.KeyboardFlags, cb: inkview.KeyboardHandler) callconv(.c) void {
    state.keyboards.append(state.gpa, .{
        .title = dupe(title),
        .buffer = buffer,
        .maxlen = maxlen,
        .flags = flags,
        .callback = cb,
        .saved = saveScreen(),
    }) catch @panic("OOM");
}

fn OpenDirectorySelector(_: [*:0]const u8, buffer: [*:0]u8, _: c_int, cb: inkview.DirHandler) callconv(.c) void {
    state.directory_requests += 1;
    // confirms at once with the path it was given
    cb(buffer);
}
