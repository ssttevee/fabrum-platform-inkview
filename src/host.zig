//! The host: fabrum's `none` contract driven by InkView's event loop.
//! `App(Root)` owns the runtime, the z2d renderer and the panel's
//! framebuffer; `run` hands InkView a handler and never returns on the
//! device (`InkViewMain` ends the process with `_exit`).
//!
//! **Events in.** `EVT_INIT` sets the panel and orientation up and reads
//! the screen; `EVT_SHOW`, `EVT_REPAINT`, `EVT_FOREGROUND` and
//! `EVT_ORIENTATION` redraw everything and refresh the whole screen (the
//! library restored or rotated the screen under us); pointer events go to
//! `Runtime.mouse` as presses, drags, a long press and the release
//! (`EVT_POINTERLONG`); keys go through `Options.keys` to `Runtime.key`;
//! `EVT_EXIT` can't be refused (the library is already exiting), so a
//! guarded close only works for the app's own `quit` and `Options.close_key`.
//!
//! **Frames out.** After every event, frames run while the runtime says one
//! is due; a later due time arms an InkView timer (`SetHardTimer`, or a
//! weak one by `Options.frame_timer`), since the library's timers are
//! one-shot and keyed by their function. Only the damage is redrawn, into
//! the task framebuffer (`GetCanvas`, gray8) or, on a panel whose
//! framebuffer isn't 8-bit, into a private gray buffer blitted with
//! `Stretch`. The refresh hint picks the e-ink update through
//! `refresh.Policy`.
//!
//! **Posts from other threads** call `Platform.requestFrame`, which sends
//! an `EVT_CUSTOM` wake to the handler with `SendEvent`, the way libinkview
//! documents for worker threads (the queue is a ring of 128, so wakes are
//! coalesced: at most one is in flight). Everything else runs on the loop
//! thread.
//!
//! **Modal InkView UI** (`Dialog3`, `OpenMenu`, `OpenKeyboard`) replaces
//! the handler until the user answers, and then restores the pixels it
//! saved. While one is up, frames are held (timers still fire), and if any
//! were, everything is redrawn when it closes, so what a timer or a post
//! changed under the dialog isn't lost to the restore. The keyboard also
//! sends `EVT_SHOW` on closing, which redraws and refreshes the whole
//! screen; it is opened with `KBD_NOUPDATE_AFTER_CLOSE` so that refresh is
//! the only one.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fabrum = @import("fabrum");
const app = fabrum.app;
const layout = fabrum.layout;
const Rect = fabrum.Rect;
const Vec2 = fabrum.Vec2;
const Renderer = @import("fabrum-renderer-z2d");

const inkview = @import("inkview.zig");
const refresh = @import("refresh.zig");
const KeyMap = @import("keys.zig").KeyMap;

const log = std.log.scoped(.fabrum_inkview);

/// What an e-reader is to fabrum: touch without hover, no animation, 16
/// grays, the system keyboard.
pub const capabilities: app.Capabilities = .{ .pointer = .touch, .hover = false, .animation = .none, .color = .gray16, .keyboard = .on_screen };

/// The wake event posts from other threads send to the handler.
pub const wake_event: c_int = @backingInt(inkview.Event.custom) + 1;

pub const Options = struct {
    /// The library to load: its soname, found through the loader's search
    /// path on the device, or a path (the emulator's copy).
    library: [*:0]const u8 = "libinkview.so",
    /// TrueType or OpenType fonts for the renderer; the first is the one
    /// text without a family uses. Names and data must outlive the app.
    fonts: []const Font = &.{},
    /// The look of the drawn widgets. Made high-contrast for the gray
    /// panel by the runtime.
    theme: app.native.Theme = .{},
    capabilities: app.Capabilities = capabilities,
    /// Edit commands for a USB or Bluetooth keyboard, if any.
    keymap: app.Keymap = .linux,
    /// What the hardware keys mean.
    keys: KeyMap = .default,
    /// A hardware key that asks the app to close: `Runtime.shouldClose`
    /// first, so a view's `guardClose` can ask, then `CloseApp`. The
    /// library's own Back and Home actions apply when null.
    close_key: ?inkview.Key = null,
    refresh: refresh.Options = .{},
    /// Device pixels per point, or null for the panel's dpi over
    /// `points_per_inch`: 212 dpi makes 2.2 pixels per point, so a
    /// 13-point font is 29 pixels, about what readers draw.
    scale: ?f32 = null,
    points_per_inch: f32 = 96,
    /// The dpi assumed when the library can't say (`get_screen_dpi` is
    /// 5.14+).
    dpi: u16 = 212,
    /// The orientation to set at start, or null to keep the library's.
    orientation: ?inkview.Orientation = .portrait,
    /// Whether to follow the g-sensor: sets `SUPPORT_EVT_ORIENTATION`,
    /// without which 6.x firmware keeps `EVT_ORIENTATION` to itself.
    follow_gsensor: bool = false,
    /// Whether the system status panel (clock, battery) is shown; the
    /// viewport leaves it out.
    panel: enum { hidden, shown } = .hidden,
    /// Hard timers wake the device for the frame; weak ones run only while
    /// it is awake anyway.
    frame_timer: enum { hard, weak } = .hard,
    /// How the whole screen is refreshed when the library asks for a
    /// redraw (`EVT_SHOW` after the keyboard closes, `EVT_REPAINT`,
    /// coming back to the foreground): a cleaning flash, or quietly.
    show_refresh: enum { full, partial } = .full,
    /// Root values for the app, as `Runtime.Options.provide`.
    provide: []const app.RootValue = &.{},
    /// Capacity of the layout built each frame, as `Runtime.Options.context`:
    /// a long list needs a `breadth` above the default.
    context: layout.Context.Config = .{},
    /// The system keyboard's buffer size when a `TextRequest` has no
    /// `max_len`.
    text_max_len: usize = 1024,
    /// Where the directory chooser starts.
    directory: []const u8 = "/mnt/ext1",
    /// The clock frames run on, or null for the monotonic clock. A fake
    /// InkView gives its own, so timers come due when it says.
    clock: ?*const fn () Io.Timestamp = null,

    pub const Font = struct { name: [:0]const u8, data: []const u8 };
};

/// The app of this process: one, since InkView has one handler and one
/// loop. `instance` is it; the C callbacks reach it there.
pub fn App(comptime Root: type) type {
    return struct {
        gpa: Allocator,
        io: Io,
        api: inkview.Api,
        options: Options,
        props: Root.Props,
        runtime: Runtime,
        renderer: Renderer,
        policy: refresh.Policy,
        screen: Screen = .{},
        /// Whether the app is the active task; updates from a background
        /// task are dropped by the system anyway.
        active: bool = true,
        /// Whether a primary press is under way.
        pointer_down: bool = false,
        /// Inside the runtime (an input call, a frame): anything asking for
        /// frames meanwhile (a timer firing from a blocking `Message`, a
        /// chooser answering at once) is deferred to after the call.
        in_runtime: bool = false,
        deferred: bool = false,
        /// InkView modal UIs up: dialogs, menus, the keyboard.
        modal: u32 = 0,
        /// Whether a frame was held while a modal UI was up.
        held: bool = false,
        /// Redraw everything next time, with at least this refresh.
        stale: ?app.Refresh = null,
        frame_timer_armed: bool = false,
        wake_pending: std.atomic.Value(bool) = .init(false),
        /// The modal requests under way, with what they own.
        open_dialog: ?Dialog = null,
        open_menu: ?Menu = null,
        open_keyboard: ?Keyboard = null,
        open_directory: ?Directory = null,

        const Self = @This();

        pub const Runtime = app.Runtime(.{ .Text = Renderer.Text });

        /// The one app of the process.
        pub var instance: Self = undefined;

        /// What the panel is: its size in pixels, the scale, and where the
        /// pixels go.
        const Screen = struct {
            width: u32 = 0,
            height: u32 = 0,
            scale: f32 = 1,
            /// The task framebuffer, when it is gray8 and big enough.
            canvas: ?*inkview.Canvas = null,
            /// Else a gray8 buffer of the screen's size, blitted whole.
            private: []u8 = &.{},

            pub fn viewport(self: Screen) Vec2 {
                return .init(@as(f32, @floatFromInt(self.width)) / self.scale, @as(f32, @floatFromInt(self.height)) / self.scale);
            }
        };

        const Dialog = struct {
            reply: app.platform.IndexReply,
            strings: [5]?[:0]u8,
        };
        const Menu = struct {
            reply: app.platform.IndexReply,
            /// The `imenu` tree, its strings and `ids`: one arena, freed
            /// when the menu is answered.
            arena: std.heap.ArenaAllocator,
            /// The `MenuItem.id` of item `index - 1`.
            ids: std.ArrayList(usize),
        };
        const Keyboard = struct {
            reply: app.platform.Reply,
            title: [:0]u8,
            buffer: [:0]u8,
        };
        const Directory = struct {
            reply: app.platform.Reply,
            title: [:0]u8,
            buffer: [:0]u8,
        };

        /// Sets the app up and hands InkView the handler. On the device
        /// this never returns; a fake library returns after its events.
        pub fn run(gpa: Allocator, io: Io, api: inkview.Api, props: Root.Props, options: Options) !void {
            const self = &instance;
            self.* = .{
                .gpa = gpa,
                .io = io,
                .api = api,
                .options = options,
                .props = props,
                .runtime = undefined,
                .renderer = try .init(gpa),
                .policy = .{ .options = options.refresh },
            };
            errdefer self.renderer.deinit();
            for (options.fonts) |font| try self.renderer.loadFont(font.name, font.data);
            self.runtime = try .init(gpa, .{
                .io = io,
                .text_context = self.renderer.text_context,
                .platform = .{ .ptr = self, .vtable = &platform_vtable },
                .provide = options.provide,
                .context = options.context,
                .theme = options.theme,
                .capabilities = options.capabilities,
                .keymap = options.keymap,
                .services = .{ .ptr = self, .vtable = &services_vtable },
            });
            errdefer self.runtime.deinit();
            if (options.follow_gsensor) _ = setenv("SUPPORT_EVT_ORIENTATION", "1", 1);
            api.InkViewMain(handler);
        }

        /// Frees everything, for hosts whose library returns (tests).
        pub fn deinit(self: *Self) void {
            self.runtime.deinit();
            self.renderer.deinit();
            self.gpa.free(self.screen.private);
            if (self.open_dialog) |*d| self.freeDialog(d);
            if (self.open_menu) |*m| freeMenu(m);
            if (self.open_keyboard) |*k| self.freeKeyboard(k);
            if (self.open_directory) |*d| self.freeDirectory(d);
            self.* = undefined;
        }

        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

        /// A NUL-terminated copy of `s`, for the library.
        fn dupeZ(gpa: Allocator, s: []const u8) Allocator.Error![:0]u8 {
            const z = try gpa.allocSentinel(u8, s.len, 0);
            @memcpy(z, s);
            return z;
        }

        // The handler

        fn handler(kind: c_int, par1: c_int, par2: c_int) callconv(.c) c_int {
            const self = &instance;
            return self.handle(@fromBackingInt(kind), par1, par2) catch |err| {
                log.err("event {d}: {t}", .{ kind, err });
                return 0;
            };
        }

        /// Delivers the event to the runtime, then runs the frames due.
        fn handle(self: *Self, event: inkview.Event, par1: c_int, par2: c_int) !c_int {
            if (self.in_runtime) return self.reentered(event);
            self.in_runtime = true;
            const result = self.dispatch(event, par1, par2);
            self.in_runtime = false;
            const taken = (try result) orelse return 0;
            try self.frames();
            return @intFromBool(taken);
        }

        /// An event delivered while the runtime is busy: `Message` pumps
        /// the library's loop until its box goes, and the events sent to
        /// this handler meanwhile (a post's wake, a repaint) arrive inside
        /// the frame that called it. The frame under way runs again once
        /// `Message` returns; nothing else can be taken now.
        fn reentered(self: *Self, event: inkview.Event) c_int {
            switch (event) {
                .show, .repaint => self.stale = self.showRefresh(),
                .foreground => {
                    self.active = true;
                    self.stale = self.showRefresh();
                },
                .background => self.active = false,
                _ => if (@backingInt(event) == wake_event) self.wake_pending.store(false, .release) else return 0,
                else => return 0,
            }
            self.deferred = true;
            return 1;
        }

        /// What the event means to the runtime: whether the app took it,
        /// or null for events that need no frame.
        fn dispatch(self: *Self, event: inkview.Event, par1: c_int, par2: c_int) !?bool {
            var taken = false;
            switch (event) {
                .init => {
                    try self.start();
                    return null;
                },
                .show, .repaint => {
                    self.stale = self.showRefresh();
                    return true;
                },
                .foreground => {
                    self.active = true;
                    self.stale = self.showRefresh();
                    return true;
                },
                .background => {
                    self.active = false;
                    if (self.pointer_down) {
                        self.pointer_down = false;
                        try self.runtime.cancelPointer();
                    }
                    return true;
                },
                .orientation => {
                    self.api.SetOrientation(@fromBackingInt(par1));
                    self.stale = .page;
                    return true;
                },
                .pointer_down => {
                    self.pointer_down = true;
                    taken = try self.runtime.mouse(.{ .position = self.point(par1, par2), .pressed = primary_down });
                },
                .pointer_move, .pointer_drag => {
                    if (!self.pointer_down) return null;
                    taken = try self.runtime.mouse(.{ .position = self.point(par1, par2), .pressed = primary_down });
                },
                .pointer_long => {
                    if (!self.pointer_down) return null;
                    taken = try self.runtime.mouse(.{ .position = self.point(par1, par2), .pressed = primary_down, .long_press = true });
                },
                .pointer_hold => return null,
                .pointer_up => {
                    if (!self.pointer_down) return null;
                    self.pointer_down = false;
                    taken = try self.runtime.mouse(.{ .position = self.point(par1, par2) });
                },
                .pointer_cancel => {
                    if (self.pointer_down) {
                        self.pointer_down = false;
                        try self.runtime.cancelPointer();
                    }
                    taken = true;
                },
                .key_press, .key_repeat, .key_release => {
                    const pressed: inkview.Key = @fromBackingInt(par1);
                    if (pressed == self.options.close_key) {
                        if (event == .key_press and try self.runtime.shouldClose(.quit)) self.api.CloseApp();
                        return true;
                    }
                    const key = self.options.keys.of(pressed) orelse return null;
                    taken = try self.runtime.key(.{ .key = key, .phase = switch (event) {
                        .key_repeat => .repeat,
                        .key_release => .release,
                        else => .press,
                    } });
                },
                .prev_page, .next_page => {
                    const key: app.KeyEvent.Key = if (event == .prev_page) .page_up else .page_down;
                    taken = try self.runtime.key(.{ .key = key });
                    _ = try self.runtime.key(.{ .key = key, .phase = .release });
                },
                // nothing can be refused at exit: the library is exiting
                .exit, .hide, .activate, .mt_sync, .update, .config_changed => return null,
                _ => {
                    if (@backingInt(event) != wake_event) return null;
                    self.wake_pending.store(false, .release);
                    taken = true;
                },
                else => return null,
            }
            return taken;
        }

        /// `EVT_INIT`: the screen is open, so its geometry can be read.
        fn start(self: *Self) !void {
            self.api.SetPanelType(switch (self.options.panel) {
                .hidden => .disabled,
                .shown => .{ .enabled = true },
            });
            if (self.options.orientation) |o| self.api.SetOrientation(o);
            self.screen.scale = self.options.scale orelse blk: {
                var dpi: f32 = @floatFromInt(self.options.dpi);
                if (self.api.get_screen_dpi) |f| {
                    const reported = f();
                    if (reported > 0) dpi = @floatFromInt(reported);
                }
                break :blk dpi / self.options.points_per_inch;
            };
            try self.readGeometry();
            log.info("screen {d}x{d} px, scale {d:.2}, viewport {d:.0}x{d:.0} pt, {s}", .{
                self.screen.width,        self.screen.height,
                self.screen.scale,        self.screen.viewport().x,
                self.screen.viewport().y, if (self.screen.canvas != null) "drawing into the task framebuffer" else "blitting a private buffer",
            });
        }

        fn showRefresh(self: *const Self) app.Refresh {
            return switch (self.options.show_refresh) {
                .full => .page,
                .partial => .content,
            };
        }

        /// Reads the screen's size and finds the framebuffer; the size
        /// changes with the orientation, the canvas may move.
        fn readGeometry(self: *Self) !void {
            const width: u32 = @intCast(@max(self.api.ScreenWidth(), 0));
            var height: u32 = @intCast(@max(self.api.ScreenHeight(), 0));
            if (self.options.panel == .shown) height -|= @intCast(@max(self.api.PanelHeight(), 0));
            self.screen.width = width;
            self.screen.height = height;
            self.screen.canvas = null;
            if (self.api.GetCanvas()) |canvas| {
                if (canvas.depth == 8 and canvas.addr != null and canvas.width >= width and canvas.height >= height and canvas.scanline >= width) {
                    self.screen.canvas = canvas;
                }
            }
            const needed: usize = if (self.screen.canvas == null) @as(usize, width) * height else 0;
            if (self.screen.private.len != needed) {
                self.gpa.free(self.screen.private);
                self.screen.private = try self.gpa.alloc(u8, needed);
                @memset(self.screen.private, 0xff);
            }
        }

        fn pixels(self: *const Self) layout.Surface.Pixels {
            if (self.screen.canvas) |canvas| {
                const stride: u32 = @intCast(canvas.scanline);
                return .{
                    .data = canvas.addr.?[0 .. @as(usize, stride) * self.screen.height],
                    .width = self.screen.width,
                    .height = self.screen.height,
                    .stride = stride,
                    .format = .gray8,
                    .scale = self.screen.scale,
                };
            }
            return .packedScaled(self.screen.private, self.screen.width, self.screen.height, .gray8, self.screen.scale);
        }

        fn point(self: *const Self, x: c_int, y: c_int) Vec2 {
            return .init(@as(f32, @floatFromInt(x)) / self.screen.scale, @as(f32, @floatFromInt(y)) / self.screen.scale);
        }

        /// The primary button down: what a finger on the panel is.
        const primary_down: app.MouseEvent.Buttons = blk: {
            var down: app.MouseEvent.Buttons = .empty;
            down.set(app.MouseEvent.primary);
            break :blk down;
        };

        fn now(self: *const Self) Io.Timestamp {
            if (self.options.clock) |clock| return clock();
            return Io.Clock.awake.now(self.io);
        }

        /// Whole milliseconds until `due`, at least one.
        fn millisUntil(self: *const Self, due: Io.Timestamp) c_int {
            const ns = self.now().durationTo(due).nanoseconds;
            const ms = @divFloor(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
            return @intCast(@min(@max(ms, 1), std.math.maxInt(c_int)));
        }

        // Frames

        /// Runs the frames due now and shows what changed, unless a modal
        /// UI is up or a frame is already running (a timer firing inside a
        /// blocking `Message`), in which case the frame waits.
        fn frames(self: *Self) !void {
            if (self.modal > 0) {
                self.held = true;
                return;
            }
            if (self.in_runtime) {
                self.deferred = true;
                return;
            }
            self.in_runtime = true;
            defer self.in_runtime = false;
            while (true) {
                self.deferred = false;
                // the screen may have turned or moved since the last frame
                try self.readGeometry();
                var count: usize = 0;
                while (self.runtime.nextFrame()) |due| {
                    const t = self.now();
                    if (due.nanoseconds > t.nanoseconds or count == 4) break;
                    _ = try self.runtime.frame(Root, self.props, self.screen.viewport(), t);
                    count += 1;
                    if (self.modal > 0) break;
                }
                if (self.stale != null and count == 0 and self.modal == 0) {
                    // the commands may be from before the screen changed
                    _ = try self.runtime.frame(Root, self.props, self.screen.viewport(), self.now());
                    count += 1;
                }
                if (self.modal > 0) {
                    // an update in the frame opened a dialog, menu or the
                    // keyboard, which the library has drawn: drawing the
                    // frame now would cover it. Everything is redrawn when
                    // it closes.
                    if (count > 0) self.held = true;
                    break;
                }
                if (count > 0) try self.present();
                if (!self.deferred) break;
            }
            self.armFrameTimer();
        }

        /// Draws the damage of the last frames and refreshes it.
        fn present(self: *Self) !void {
            var regions = try self.runtime.damage();
            var hint = self.runtime.refresh();
            const whole: [1]Rect = .{.init(0, 0, self.screen.viewport().x, self.screen.viewport().y)};
            if (self.stale) |at_least| {
                regions = &whole;
                hint = hint.strongest(at_least);
                self.stale = null;
            }
            if (regions.len == 0 or self.screen.width == 0 or self.screen.height == 0) return;
            try layout.draw(&self.renderer, self.runtime.commands(), .pixels, self.pixels(), regions);
            if (self.screen.canvas == null) {
                const w: c_int = @intCast(self.screen.width);
                const h: c_int = @intCast(self.screen.height);
                self.api.Stretch(self.screen.private.ptr, inkview.image_gray8, w, h, w, 0, 0, w, h, 0);
            }
            if (!self.active) return;
            const update = self.policy.decide(hint, self.now(), self.available());
            self.apply(update, regions);
            self.armA2Timer();
        }

        fn available(self: *const Self) refresh.Available {
            return .{ .a2 = self.api.DynamicUpdateA2 != null, .dynamic = self.api.DynamicUpdate != null };
        }

        /// Calls the update function for `regions`, in points.
        fn apply(self: *Self, update: refresh.Update, regions: []const Rect) void {
            switch (update) {
                .full => self.api.FullUpdate(),
                .partial => for (regions) |r| self.updateRect(self.api.PartialUpdate, r),
                .dynamic => for (regions) |r| self.updateRect(self.api.DynamicUpdate orelse self.api.PartialUpdate, r),
                .a2 => for (regions) |r| self.updateRect(self.api.DynamicUpdateA2 orelse self.api.PartialUpdate, r),
            }
        }

        fn updateRect(self: *const Self, f: *const fn (c_int, c_int, c_int, c_int) callconv(.c) void, r: Rect) void {
            const s = self.screen.scale;
            const x0: c_int = @intFromFloat(@max(@floor(r.x * s), 0));
            const y0: c_int = @intFromFloat(@max(@floor(r.y * s), 0));
            const x1: c_int = @intFromFloat(@min(@ceil((r.x + r.w) * s), @as(f32, @floatFromInt(self.screen.width))));
            const y1: c_int = @intFromFloat(@min(@ceil((r.y + r.h) * s), @as(f32, @floatFromInt(self.screen.height))));
            if (x1 <= x0 or y1 <= y0) return;
            f(x0, y0, x1 - x0, y1 - y0);
        }

        // Timers

        fn armFrameTimer(self: *Self) void {
            const due = self.runtime.nextFrame() orelse {
                if (self.frame_timer_armed) {
                    self.api.ClearTimer(frameTimer);
                    self.frame_timer_armed = false;
                }
                return;
            };
            const ms = self.millisUntil(due);
            const set = switch (self.options.frame_timer) {
                .hard => self.api.SetHardTimer,
                .weak => self.api.SetWeakTimer,
            };
            set("fabrum-frame", frameTimer, ms);
            self.frame_timer_armed = true;
        }

        fn frameTimer() callconv(.c) void {
            const self = &instance;
            self.frame_timer_armed = false;
            self.frames() catch |err| log.err("frame timer: {t}", .{err});
        }

        fn armA2Timer(self: *Self) void {
            const due = self.policy.exitDue() orelse return;
            const ms = self.millisUntil(due);
            // hard: the cleaning refresh must come even as the device dozes
            self.api.SetHardTimer("fabrum-a2", a2Timer, ms);
        }

        fn a2Timer() callconv(.c) void {
            const self = &instance;
            if (self.modal > 0) return;
            if (self.policy.idle(self.now())) |update| {
                if (self.active) self.apply(update, &.{});
            } else self.armA2Timer();
        }

        // Posts from other threads

        const platform_vtable: app.Platform.VTable = .{ .requestFrame = requestFrame };

        /// Wakes the loop with one event, however many posts arrive before
        /// it is delivered. Thread-safe as far as `SendEvent` is: libinkview
        /// documents it as the way for worker threads to reach the handler.
        fn requestFrame(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.wake_pending.swap(true, .acq_rel)) return;
            self.api.SendEvent(handler, wake_event, 0, 0);
        }

        // Services

        const services_vtable: app.platform.Services.VTable = .{
            .message = message,
            .confirm = confirm,
            .menu = menu,
            .editText = editText,
            .openDirectory = openDirectory,
            .quit = quit,
            .close = quit,
        };

        const Error = app.platform.Services.Error;

        fn iconOf(kind: app.platform.DialogKind) inkview.DialogIcon.Kind {
            return switch (kind) {
                .info => .information,
                .question => .question,
                .warning => .warning,
                .@"error" => .@"error",
            };
        }

        /// `Message`: blocks until the box goes (a timer, a tap). Timers
        /// keep running meanwhile, so a frame timer firing is deferred.
        fn message(ptr: *anyopaque, request: *const app.platform.MessageRequest) Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const title = try dupeZ(self.gpa, request.title);
            defer self.gpa.free(title);
            const text = try dupeZ(self.gpa, request.text);
            defer self.gpa.free(text);
            self.api.Message(.{ .kind = iconOf(request.kind) }, title, text, @intCast(@min(request.timeout_ms, std.math.maxInt(c_int))));
        }

        /// `Dialog3`: one at a time; answered 1–3 or -1 when dismissed.
        fn confirm(ptr: *anyopaque, request: *const app.platform.ConfirmRequest, reply: app.platform.IndexReply) Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.open_dialog != null or request.buttons.len == 0) return error.ServiceFailed;
            var d: Dialog = .{ .reply = reply, .strings = .{ null, null, null, null, null } };
            errdefer self.freeDialog(&d);
            d.strings[0] = try dupeZ(self.gpa, request.title);
            d.strings[1] = try dupeZ(self.gpa, request.text);
            for (request.buttons[0..@min(request.buttons.len, 3)], 2..) |label, i| d.strings[i] = try dupeZ(self.gpa, label);
            self.open_dialog = d;
            self.modal += 1;
            const icon: inkview.DialogIcon = .{ .kind = iconOf(request.kind), .default = @fromBackingInt(@as(u2, @intCast(@min(request.default, 2)))), .hw_button = true };
            self.api.Dialog3(icon, d.strings[0].?, d.strings[1].?, ptrOf(d.strings[2]), ptrOf(d.strings[3]), ptrOf(d.strings[4]), dialogAnswered);
        }

        fn dialogAnswered(button: c_int) callconv(.c) void {
            const self = &instance;
            var d = self.open_dialog orelse return;
            self.open_dialog = null;
            defer self.freeDialog(&d);
            d.reply.send(if (button >= 1 and button <= 3) @as(usize, @intCast(button - 1)) else null) catch |err| log.err("dialog reply: {t}", .{err});
            self.modalClosed();
        }

        fn ptrOf(s: ?[:0]u8) ?[*:0]const u8 {
            return if (s) |z| z.ptr else null;
        }

        fn freeDialog(self: *Self, d: *Dialog) void {
            for (d.strings) |s| if (s) |z| self.gpa.free(z);
        }

        /// `OpenMenu` with an `imenu` tree built from the items. Indices
        /// are positions in the tree plus one, mapped back to `MenuItem.id`
        /// when answered, since `imenu.index` is a `short`.
        fn menu(ptr: *anyopaque, request: *const app.platform.MenuRequest, reply: app.platform.IndexReply) Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.open_menu != null) return error.ServiceFailed;
            var m: Menu = .{ .reply = reply, .arena = .init(self.gpa), .ids = .empty };
            errdefer freeMenu(&m);
            const top = try buildMenu(&m, request.items);
            self.open_menu = m;
            self.modal += 1;
            const s = self.screen.scale;
            self.api.OpenMenu(top.ptr, 0, @intFromFloat(@round(request.at.x * s)), @intFromFloat(@round(request.at.y * s)), menuChosen);
        }

        fn buildMenu(m: *Menu, items: []const app.platform.MenuItem) Error![]inkview.MenuItem {
            const arena = m.arena.allocator();
            const array = try arena.alloc(inkview.MenuItem, items.len + 1);
            array[items.len] = .end;
            for (items, array[0..items.len]) |item, *entry| {
                try m.ids.append(arena, item.id);
                if (m.ids.items.len > std.math.maxInt(c_short)) return error.ServiceFailed;
                entry.* = .{
                    .type = switch (item.kind) {
                        .item => if (item.enabled) .active else .inactive,
                        .header => .header,
                        .separator => .separator,
                        .submenu => .submenu,
                    },
                    .index = @intCast(m.ids.items.len),
                    .text = (try dupeZ(arena, item.title)).ptr,
                    .submenu = null,
                };
                if (item.kind == .submenu) entry.submenu = (try buildMenu(m, item.submenu)).ptr;
            }
            return array;
        }

        fn menuChosen(index: c_int) callconv(.c) void {
            const self = &instance;
            var m = self.open_menu orelse return;
            self.open_menu = null;
            defer freeMenu(&m);
            const id: ?usize = if (index >= 1 and index <= m.ids.items.len) m.ids.items[@intCast(index - 1)] else null;
            m.reply.send(id) catch |err| log.err("menu reply: {t}", .{err});
            self.modalClosed();
        }

        fn freeMenu(m: *Menu) void {
            m.arena.deinit();
        }

        /// `OpenKeyboard` on the request's text, with the layout its flags
        /// ask for. The buffer is the host's until the callback.
        fn editText(ptr: *anyopaque, request: *const app.platform.TextRequest, reply: app.platform.Reply) Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.open_keyboard != null) return error.ServiceFailed;
            const max = if (request.max_len > 0) request.max_len else self.options.text_max_len;
            const buffer = try self.gpa.allocSentinel(u8, @max(max, request.initial.len), 0);
            errdefer self.gpa.free(buffer);
            @memset(buffer, 0);
            @memcpy(buffer[0..request.initial.len], request.initial);
            const title = try dupeZ(self.gpa, request.title);
            self.open_keyboard = .{ .reply = reply, .title = title, .buffer = buffer };
            self.modal += 1;
            self.api.OpenKeyboard(title, buffer.ptr, @intCast(@min(buffer.len, std.math.maxInt(c_int))), keyboardFlags(request.flags), keyboardClosed);
        }

        /// The keyboard's layout and options for a request: the URL,
        /// numeric or password layouts; the text is appended to rather
        /// than replaced; the closing refresh is left to the `EVT_SHOW`
        /// that follows.
        fn keyboardFlags(flags: app.platform.TextRequest.Flags) inkview.KeyboardFlags {
            return .{
                .layout = if (flags.numeric) .numeric else if (flags.url or flags.email) .url else .normal,
                .password = flags.password,
                .noselect = true,
                .no_update_after_close = true,
            };
        }

        fn keyboardClosed(text: ?[*:0]u8) callconv(.c) void {
            const self = &instance;
            var k = self.open_keyboard orelse return;
            self.open_keyboard = null;
            defer self.freeKeyboard(&k);
            k.reply.send(if (text) |t| std.mem.span(t) else null) catch |err| log.err("keyboard reply: {t}", .{err});
            self.modalClosed();
        }

        fn freeKeyboard(self: *Self, k: *Keyboard) void {
            self.gpa.free(k.title);
            self.gpa.free(k.buffer);
        }

        /// `OpenDirectorySelector`, on firmware that still has it (gone in
        /// 6.8). It only calls back on confirmation, so it doesn't count as
        /// a modal: a cancelled chooser answers nothing.
        fn openDirectory(ptr: *anyopaque, request: *const app.platform.FileRequest, reply: app.platform.Reply) Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const open = self.api.OpenDirectorySelector orelse return error.Unsupported;
            if (self.open_directory != null) return error.ServiceFailed;
            // the chooser writes the choice back over the starting path
            const start_dir = self.options.directory;
            const buffer = try self.gpa.allocSentinel(u8, @max(1024, start_dir.len), 0);
            errdefer self.gpa.free(buffer);
            @memcpy(buffer[0..start_dir.len], start_dir);
            @memset(buffer[start_dir.len..], 0);
            const title = try dupeZ(self.gpa, request.message);
            self.open_directory = .{ .reply = reply, .title = title, .buffer = buffer };
            open(title, buffer.ptr, @intCast(buffer.len), directoryChosen);
        }

        fn directoryChosen(path: ?[*:0]u8) callconv(.c) void {
            const self = &instance;
            var d = self.open_directory orelse return;
            self.open_directory = null;
            defer self.freeDirectory(&d);
            d.reply.send(if (path) |p| std.mem.span(p) else null) catch |err| log.err("directory reply: {t}", .{err});
            self.stale = .content;
            self.frames() catch |err| log.err("after the directory chooser: {t}", .{err});
        }

        fn freeDirectory(self: *Self, d: *Directory) void {
            self.gpa.free(d.title);
            self.gpa.free(d.buffer);
        }

        /// After a modal UI closed: the library restored the pixels under
        /// it, so if frames were held meanwhile, everything is redrawn.
        fn modalClosed(self: *Self) void {
            self.modal -= 1;
            if (self.held) {
                self.held = false;
                self.stale = .content;
            }
            self.frames() catch |err| log.err("after a dialog: {t}", .{err});
        }

        fn quit(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.api.CloseApp();
        }
    };
}

test "the keyboard flags follow the request" {
    const flags = App(struct {
        pub const State = struct {};
        pub const Msg = union(enum) { none };
        pub const Props = struct {};
        pub fn update(_: *State, _: Msg, _: *app.Update(@This())) !void {}
        pub fn view(_: *app.Ui, _: *const State, _: Props) !void {}
    }).keyboardFlags;
    try std.testing.expectEqual(.normal, flags(.{}).layout);
    try std.testing.expectEqual(.url, flags(.{ .url = true }).layout);
    try std.testing.expectEqual(.url, flags(.{ .email = true }).layout);
    try std.testing.expectEqual(.numeric, flags(.{ .numeric = true }).layout);
    try std.testing.expect(flags(.{ .password = true }).password);
    try std.testing.expect(!flags(.{}).password);
    try std.testing.expect(flags(.{}).noselect and flags(.{}).no_update_after_close);
}
