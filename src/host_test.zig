//! The host driven by the fake InkView: events to runtime messages,
//! refresh modes per hint sequence, the framebuffer against a full
//! redraw, services to replies, the keyboard into a field, page keys,
//! orientation, timers and posts from other threads.
const std = @import("std");
const testing = std.testing;

const fabrum = @import("fabrum");
const app = fabrum.app;
const layout = fabrum.layout;
const widgets = app.widgets;
const Vec2 = fabrum.Vec2;
const Rect = fabrum.Rect;

const root = @import("root.zig");
const fake = root.fake;
const inkview = root.inkview;

/// A reader's screen in little: a title row with buttons that ask for
/// each service, a text field, and a list that scrolls with the page keys
/// (and a finger, as the runtime pans any drawn scroll container on a
/// touch screen), or a settings page.
const Probe = struct {
    pub const State = struct {
        picks: usize = 0,
        text: std.ArrayList(u8) = .empty,
        answer: ?usize = null,
        answers: usize = 0,
        chosen: ?usize = null,
        choices: usize = 0,
        page: enum { list, settings } = .list,
        dir: ?[]u8 = null,
        dir_answers: usize = 0,
        dir_error: ?app.platform.Services.Error = null,
        ticks: usize = 0,
        list_focused: bool = false,

        pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
            self.text.deinit(gpa);
            if (self.dir) |d| gpa.free(d);
        }
    };

    pub const Msg = union(enum) {
        pick,
        text: []const u8,
        ask,
        answered: ?usize,
        open_menu,
        chose: ?usize,
        key: app.KeyEvent,
        full,
        tick,
        focus_list,
        back,
        open_dir,
        worker_done: std.Io.Cancelable!void,
        dir: ?[]const u8,
    };

    pub const Props = struct { items: u8 = 30, tick: bool = false, worker: ?*ExitWorker = null };
    pub const PickKey = struct { pick: usize };

    pub fn update(state: *State, msg: Msg, ctx: *app.Update(Probe)) !void {
        switch (msg) {
            .worker_done => {},
            .pick => state.picks += 1,
            .text => |t| {
                state.text.clearRetainingCapacity();
                try state.text.appendSlice(ctx.gpa, t);
            },
            .ask => try ctx.confirm(.{ .title = "Quit?", .text = "Really quit?", .buttons = &.{ "Quit", "Cancel", "Later" }, .default = 1 }, ctx.handler(.answered)),
            .answered => |i| {
                state.answer = i;
                state.answers += 1;
                if (i == 0) try ctx.quit();
            },
            .open_menu => try ctx.menu(.{ .items = &.{
                .{ .title = "Reader", .kind = .header },
                .{ .title = "Settings", .id = 1 },
                .{ .kind = .separator },
                .{ .title = "Disabled", .id = 2, .enabled = false },
                .{ .title = "More", .kind = .submenu, .submenu = &.{.{ .title = "Big id", .id = 70000 }} },
                .{ .title = "About", .id = 3 },
                .{ .title = "Quit", .id = 4 },
            }, .at = .init(10, 20) }, ctx.handler(.chose)),
            .chose => |id| {
                state.chosen = id;
                state.choices += 1;
                if (id == 1) state.page = .settings;
                if (id == 3) try ctx.message(.{ .title = "About", .text = "Probe", .timeout_ms = 1500 });
                if (id == 4) try ctx.confirm(.{ .title = "Quit?", .text = "Really quit?", .buttons = &.{ "Quit", "Cancel" } }, ctx.handler(.answered));
            },
            .key => |e| if (e.phase == .press) switch (e.key) {
                .page_down => ctx.scrollTo("list", .{ .by = .init(0, 200) }, .{}),
                .page_up => ctx.scrollTo("list", .{ .by = .init(0, -200) }, .{}),
                else => {},
            },
            .full => ctx.refresh(.page),
            .tick => state.ticks += 1,
            .focus_list => {
                state.list_focused = true;
                ctx.focus("list");
            },
            .back => state.page = .list,
            .open_dir => ctx.openDirectory(.{ .message = "Pick a folder" }, ctx.handler(.dir)) catch |err| {
                state.dir_error = err;
            },
            .dir => |path| {
                state.dir_answers += 1;
                if (state.dir) |d| ctx.gpa.free(d);
                state.dir = if (path) |p| try ctx.gpa.dupe(u8, p) else null;
            },
        }
    }

    pub fn view(ui: *app.Ui, state: *const State, props: Props) !void {
        if (props.worker) |worker| try ui.task("exit-worker", .{}, ExitWorker.run, .{worker}, ui.messages(Probe).handler(.worker_done));
        const on = ui.messages(Probe);
        const theme = ui.use(app.native.Theme);
        const style: layout.text.Style = .{ .font_size = theme.font_size, .color = theme.text, .wrap_mode = .none };
        if (props.tick) try ui.every("tick", .fromMilliseconds(100), on.bind(.tick));
        if (!state.list_focused) try ui.after("focus", .fromMilliseconds(0), on.bind(.focus_list));

        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(8), .child_gap = 8 }, .background_color = theme.window_background });
        defer ui.close();
        {
            try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .child_gap = 6, .child_alignment = .center_left } });
            defer ui.close();
            try ui.text("Probe", .{ .font_size = 20, .color = theme.text, .wrap_mode = .none });
            ui.spacer();
            try widgets.button(ui, "menu", .{ .label = "Menu", .on_click = on.bind(.open_menu) });
            try widgets.button(ui, "ask", .{ .label = "Ask", .on_click = on.bind(.ask) });
            try widgets.button(ui, "full", .{ .label = "Full", .on_click = on.bind(.full) });
            try widgets.button(ui, "dir", .{ .label = "Dir", .on_click = on.bind(.open_dir) });
        }
        try widgets.textField(ui, "field", .{ .text = state.text.items, .placeholder = "Search", .on_change = on.handler(.text) });
        switch (state.page) {
            .settings => {
                try ui.text("Settings page", style);
                try widgets.button(ui, "back", .{ .label = "Back", .on_click = on.bind(.back) });
            },
            .list => {
                try ui.open("list", .{
                    .layout = .{ .sizing = .grow(.{}), .axis = .y, .child_gap = 6, .padding = .all(4) },
                    .scroll = .{ .y = true },
                    .focus = .{ .on_key = on.handler(.key), .keys = .all },
                });
                defer ui.close();
                for (0..props.items) |i| {
                    try ui.open(i, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .child_gap = 8, .child_alignment = .center_left, .padding = .all(4) }, .background_color = theme.control_background });
                    defer ui.close();
                    try ui.print(style, "Item {d}", .{i});
                    ui.spacer();
                    try widgets.button(ui, PickKey{ .pick = i }, .{ .label = "Pick", .on_click = on.bind(.pick) });
                }
            },
        }
    }
};

const Host = root.App(Probe);
const font = @embedFile("example/fonts/Go-Regular.ttf");

const Setup = struct {
    fake: fake.Options = .{},
    host: root.Options = .{},
    props: Probe.Props = .{},
};

fn start(setup: Setup) !void {
    try fake.init(testing.allocator, setup.fake);
    errdefer fake.deinit();
    var options = setup.host;
    options.fonts = &.{.{ .name = "Go", .data = font }};
    options.clock = fake.clock;
    try Host.run(testing.allocator, testing.io, fake.api(), setup.props, options);
}

fn stop() void {
    Host.instance.deinit();
    fake.deinit();
}

fn host() *Host {
    return &Host.instance;
}

fn probe() *Probe.State {
    return host().runtime.rootState(Probe).?;
}

fn scale() f32 {
    return host().screen.scale;
}

/// A place on the panel, in pixels.
const Px = struct {
    x: c_int,
    y: c_int,

    fn of(unit: *const layout.Unit) Px {
        const c = app.testing.center(unit);
        return .{ .x = @intFromFloat(c.x * scale()), .y = @intFromFloat(c.y * scale()) };
    }
};

/// Where `text` is on the panel.
fn locate(text: []const u8) !Px {
    return .of(app.testing.findText(Host.Runtime.Text, host().runtime.context(), text) orelse return error.NoSuchText);
}

fn element(key: anytype) layout.Unit.Id {
    return app.testing.rootInstance(Probe).element(key);
}

fn locateElement(key: anytype) !Px {
    return .of(host().runtime.context().getUnitById(element(key)) orelse return error.NoSuchElement);
}

fn tapText(text: []const u8) !void {
    const at = try locate(text);
    fake.tap(at.x, at.y);
}

fn listOffset() f32 {
    return host().runtime.scrollInfo(element("list")).?.offset.y;
}

/// Fails unless the fake's framebuffer is what redrawing everything gives.
fn checkFramebuffer() !void {
    const h = host();
    const w: usize = @intCast(fake.state.width);
    const rows: usize = @intCast(fake.state.height);
    const scratch = try testing.allocator.alloc(u8, w * rows);
    defer testing.allocator.free(scratch);
    try layout.draw(&h.renderer, h.runtime.commands(), .pixels, .packedScaled(scratch, @intCast(w), @intCast(rows), .gray8, scale()), null);
    for (0..rows) |y| {
        if (!std.mem.eql(u8, scratch[y * w ..][0..w], fake.row(y))) {
            std.debug.print("row {d} differs from a full redraw\n", .{y});
            return error.DamageMissed;
        }
    }
}

test "init sets the panel and orientation up, and show draws everything with one full update" {
    try start(.{});
    defer stop();
    try testing.expectEqual(inkview.PanelType.disabled, fake.state.panel_type);
    try testing.expectEqualSlices(inkview.Orientation, &.{.portrait}, fake.state.orientation_sets.items);
    try testing.expectEqualSlices(fake.Update.Kind, &.{.full}, fake.kinds());
    // 212 dpi over 96 points per inch
    try testing.expectApproxEqAbs(2.208, scale(), 0.01);
    const viewport = host().screen.viewport();
    try testing.expectApproxEqAbs(758.0 / 2.208, viewport.x, 0.5);
    try testing.expect(host().screen.canvas != null);
    try testing.expectEqual(0, fake.state.stretches);
    try checkFramebuffer();
    // the first frame's timer focused the list; nothing else is due
    try testing.expect(probe().list_focused);
    try testing.expectEqual(@as(?fake.Timer, null), fake.timer("fabrum-frame"));
}

test "a tap clicks a button, and only its damage is refreshed, partially" {
    try start(.{});
    defer stop();
    fake.clearUpdates();
    const at = try locateElement(Probe.PickKey{ .pick = 0 });
    fake.tap(at.x, at.y);
    try testing.expectEqual(1, probe().picks);
    try testing.expect(fake.state.updates.items.len >= 1);
    var covered = false;
    for (fake.state.updates.items) |u| {
        try testing.expectEqual(fake.Update.Kind.partial, u.kind);
        try testing.expect(u.w < @divTrunc(fake.state.width, 2) and u.h < @divTrunc(fake.state.height, 4));
        if (at.x >= u.x and at.x < u.x + u.w and at.y >= u.y and at.y < u.y + u.h) covered = true;
    }
    try testing.expect(covered);
    try checkFramebuffer();
}

test "a pan scrolls the list with gray updates, then A2, then a cleaning full refresh when it ends" {
    try start(.{ .host = .{ .refresh = .{ .a2_enter_after = 2, .full_every = 100 } } });
    defer stop();
    fake.clearUpdates();
    const at = try locateElement("list");
    fake.drag(at.x, at.y + 150, at.x, at.y - 150, 6);
    try testing.expect(listOffset() > 100);
    const k = fake.kinds();
    try testing.expect(k.len >= 4);
    try testing.expectEqual(fake.Update.Kind.dynamic, k[0]);
    try testing.expectEqual(fake.Update.Kind.dynamic, k[1]);
    try testing.expectEqual(fake.Update.Kind.a2, k[2]);
    try testing.expectEqual(fake.Update.Kind.a2, k[k.len - 1]);
    try checkFramebuffer();
    // the exit is a hard timer, and ends A2 with a full refresh
    const exit = fake.timer("fabrum-a2").?;
    try testing.expect(exit.hard);
    try testing.expectEqual(700, exit.due_ms - fake.state.now_ms);
    fake.clearUpdates();
    fake.advance(699);
    try testing.expectEqual(0, fake.state.updates.items.len);
    fake.advance(1);
    try testing.expectEqualSlices(fake.Update.Kind, &.{.full}, fake.kinds());
    try testing.expectEqual(@as(?fake.Timer, null), fake.timer("fabrum-a2"));
}

test "without A2 or dynamic updates in the library, a pan is gray or partial" {
    try start(.{ .fake = .{ .has_a2 = false }, .host = .{ .refresh = .{ .a2_enter_after = 0 } } });
    fake.clearUpdates();
    var at = try locateElement("list");
    fake.drag(at.x, at.y + 100, at.x, at.y - 100, 3);
    for (fake.kinds()) |k| try testing.expectEqual(fake.Update.Kind.dynamic, k);
    try testing.expectEqual(@as(?fake.Timer, null), fake.timer("fabrum-a2"));
    stop();

    try start(.{ .fake = .{ .has_a2 = false, .has_dynamic = false }, .host = .{ .refresh = .{ .a2_enter_after = 0 } } });
    defer stop();
    fake.clearUpdates();
    at = try locateElement("list");
    fake.drag(at.x, at.y + 100, at.x, at.y - 100, 3);
    for (fake.kinds()) |k| try testing.expectEqual(fake.Update.Kind.partial, k);
}

test "every nth non-flashing update is a full one, and the app can ask for one" {
    try start(.{ .host = .{ .refresh = .{ .full_every = 3 } } });
    defer stop();
    fake.clearUpdates();
    const at = try locateElement(Probe.PickKey{ .pick = 1 });
    fake.tap(at.x, at.y);
    fake.tap(at.x, at.y);
    fake.tap(at.x, at.y);
    const k = fake.kinds();
    try testing.expectEqual(fake.Update.Kind.partial, k[0]);
    try testing.expectEqual(fake.Update.Kind.full, k[k.len - 1]);
    fake.clearUpdates();
    // the press shows the button pressed (partial), the click asks for a page
    try tapText("Full");
    try testing.expectEqualSlices(fake.Update.Kind, &.{ .partial, .full }, fake.kinds());
}

test "tapping the field opens the system keyboard, whose text comes back into the field" {
    try start(.{});
    defer stop();
    fake.clearUpdates();
    try tapText("Search");
    try testing.expectEqual(1, fake.state.keyboards.items.len);
    const kb = fake.state.keyboards.items[0];
    try testing.expectEqualStrings("Search", kb.title);
    try testing.expectEqualStrings("", std.mem.span(kb.buffer));
    try testing.expect(kb.flags.no_update_after_close);
    try testing.expect(kb.flags.noselect);
    try testing.expectEqual(1, host().modal);
    // nothing is drawn or refreshed while the keyboard is up
    const before = fake.state.updates.items.len;
    fake.advance(50);
    try testing.expectEqual(before, fake.state.updates.items.len);

    fake.keyboardResult("hello");
    try testing.expectEqual(0, host().modal);
    try testing.expectEqualStrings("hello", probe().text.items);
    try testing.expect(app.testing.findText(Host.Runtime.Text, host().runtime.context(), "hello") != null);
    // the EVT_SHOW after the keyboard redraws and refreshes the whole screen
    const k = fake.kinds();
    try testing.expectEqual(fake.Update.Kind.full, k[k.len - 1]);
    try checkFramebuffer();

    // the text comes back as the initial text, and a cancel changes nothing
    try tapText("hello");
    try testing.expectEqualStrings("hello", std.mem.span(fake.state.keyboards.items[0].buffer));
    fake.keyboardResult(null);
    try testing.expectEqualStrings("hello", probe().text.items);
    try checkFramebuffer();
}

test "Ask opens Dialog3; its answer is a message; the first button quits" {
    try start(.{});
    defer stop();
    try tapText("Ask");
    try testing.expectEqual(1, fake.state.dialogs.items.len);
    const d = fake.state.dialogs.items[0];
    try testing.expectEqualStrings("Really quit?", d.text);
    try testing.expectEqualStrings("Quit", d.buttons[0].?);
    try testing.expectEqualStrings("Cancel", d.buttons[1].?);
    try testing.expectEqualStrings("Later", d.buttons[2].?);
    try testing.expectEqual(.second, d.icon.default);
    try testing.expect(d.icon.hw_button);
    try testing.expectEqual(.question, d.icon.kind);
    // a second dialog while one is up is refused, not stacked
    try testing.expectEqual(0, fake.state.dialogs.items.len - 1);

    fake.answerDialog(2);
    try testing.expectEqual(@as(?usize, 1), probe().answer);
    try testing.expect(!fake.state.closed);
    try tapText("Ask");
    fake.answerDialog(-1);
    try testing.expectEqual(@as(?usize, null), probe().answer);
    try testing.expectEqual(2, probe().answers);
    try tapText("Ask");
    fake.answerDialog(1);
    try testing.expectEqual(@as(?usize, 0), probe().answer);
    try testing.expect(fake.state.closed);
    try testing.expect(host().exiting);
    // InkView is exiting; its restored pixels must not be drawn over.
}

test "frames are held while a dialog is up, and everything is redrawn after it closes" {
    try start(.{});
    defer stop();
    try tapText("Ask");
    fake.clearUpdates();
    // a post from elsewhere while the dialog is up: no drawing under it
    try host().runtime.post(app.testing.rootInstance(Probe).handler(Probe, .pick), {});
    fake.pump();
    // messages are delivered by frames, and none ran
    try testing.expectEqual(0, probe().picks);
    try testing.expectEqual(0, fake.state.updates.items.len);
    try testing.expect(host().held);
    fake.answerDialog(2);
    try testing.expectEqual(1, probe().picks);
    // the library's own full update on closing, then our quiet redraw of
    // the whole screen
    const k = fake.kinds();
    try testing.expectEqual(2, k.len);
    try testing.expectEqual(fake.Update.Kind.full, k[0]);
    const last = fake.state.updates.items[1];
    try testing.expectEqual(fake.Update.Kind.partial, last.kind);
    try testing.expectEqual(fake.state.width, last.w);
    try testing.expectEqual(fake.state.height, last.h);
    try checkFramebuffer();
}

test "Menu opens an imenu tree answered by the item's id, big ids included" {
    try start(.{});
    defer stop();
    try tapText("Menu");
    try testing.expectEqual(1, fake.state.menus.items.len);
    const m = fake.state.menus.items[0];
    try testing.expectEqual(@as(c_int, @intFromFloat(@round(10 * scale()))), m.x);
    const top = m.top();
    try testing.expectEqual(7, top.len);
    try testing.expectEqual(.header, top[0].type);
    try testing.expectEqualStrings("Settings", std.mem.span(top[1].text.?));
    try testing.expectEqual(.active, top[1].type);
    try testing.expectEqual(.separator, top[2].type);
    try testing.expectEqual(.inactive, top[3].type);
    try testing.expectEqual(.submenu, top[4].type);
    const sub = top[4].submenu.?;
    try testing.expectEqualStrings("Big id", std.mem.span(sub[0].text.?));
    try testing.expectEqual(.end, sub[1].type);
    // every item in the tree has its own index
    try testing.expectEqual(6, sub[0].index);
    try testing.expectEqual(7, top[5].index);

    fake.chooseMenu(sub[0].index);
    try testing.expectEqual(@as(?usize, 70000), probe().chosen);
    try tapText("Menu");
    fake.chooseMenu(2);
    try testing.expectEqual(@as(?usize, 1), probe().chosen);
    try testing.expectEqual(.settings, probe().page);
    try testing.expect(app.testing.findText(Host.Runtime.Text, host().runtime.context(), "Settings page") != null);
    try checkFramebuffer();
    try tapText("Menu");
    fake.chooseMenu(-1);
    try testing.expectEqual(@as(?usize, null), probe().chosen);
    try testing.expectEqual(3, probe().choices);
    try testing.expectEqual(0, host().modal);
}

test "a dialog, menu or keyboard an update opens isn't drawn over by the rest of its frame" {
    try start(.{});
    defer stop();
    try tapText("Ask");
    try testing.expect(fake.modalShown());
    fake.answerDialog(2);
    try tapText("Menu");
    try testing.expect(fake.modalShown());
    // a dialog opened by the menu's answer: the frame that runs the answer
    // had held the redraw of the whole screen
    fake.chooseMenu(8);
    try testing.expectEqual(1, fake.state.dialogs.items.len);
    try testing.expect(fake.modalShown());
    fake.answerDialog(2);
    try testing.expectEqual(0, host().modal);
    try checkFramebuffer();
    try tapText("Search");
    try testing.expect(fake.modalShown());
    fake.keyboardResult(null);
    try checkFramebuffer();
}

test "About shows a blocking Message; frames a timer asked for meanwhile run after it" {
    try start(.{ .props = .{ .tick = true } });
    defer stop();
    try testing.expect(fake.timer("fabrum-frame") != null);
    try tapText("Menu");
    const ticks = probe().ticks;
    fake.chooseMenu(7);
    try testing.expectEqual(1, fake.state.messages.items.len);
    try testing.expectEqualStrings("Probe", fake.state.messages.items[0].text);
    try testing.expectEqual(1500, fake.state.messages.items[0].timeout);
    // the fake pumped 1.5 s of timers inside Message: the ticks they
    // delivered ran once the frame that opened it was over
    try testing.expect(probe().ticks > ticks);
    try testing.expect(!host().in_runtime);
    try checkFramebuffer();
}

test "a timer frame is armed with InkView as a hard timer, and fires" {
    try start(.{ .props = .{ .tick = true } });
    defer stop();
    const t = fake.timer("fabrum-frame").?;
    try testing.expect(t.hard);
    try testing.expect(t.due_ms - fake.state.now_ms <= 100);
    fake.advance(100);
    try testing.expectEqual(1, probe().ticks);
    fake.advance(100);
    try testing.expectEqual(2, probe().ticks);
    stop();

    try start(.{ .props = .{ .tick = true }, .host = .{ .frame_timer = .weak } });
    try testing.expect(!fake.timer("fabrum-frame").?.hard);
}

test "the page keys scroll the focused list; unmapped keys are left to the library" {
    try start(.{});
    defer stop();
    try testing.expectEqual(0, listOffset());
    try testing.expectEqual(1, fake.pressKey(.next));
    try testing.expectEqual(200, listOffset());
    try testing.expectEqual(1, fake.pressKey(.next2));
    try testing.expectEqual(400, listOffset());
    try testing.expectEqual(1, fake.pressKey(.prev));
    try testing.expectEqual(200, listOffset());
    try testing.expectEqual(0, fake.pressKey(.power));
    try testing.expectEqual(0, fake.pressKey(.home));
    // the gesture events turn pages too
    try testing.expectEqual(1, fake.send(.next_page, 0, 0));
    try testing.expectEqual(400, listOffset());
    // a scroll the app asks for is content: a quality partial update of
    // the list alone
    fake.clearUpdates();
    _ = fake.pressKey(.next);
    try testing.expectEqualSlices(fake.Update.Kind, &.{.partial}, fake.kinds());
    try testing.expect(fake.state.updates.items[0].h < fake.state.height);
    try checkFramebuffer();
}

test "a close key asks the app first, then closes" {
    try start(.{ .host = .{ .close_key = .back } });
    defer stop();
    try testing.expectEqual(1, fake.pressKey(.back));
    try testing.expect(fake.state.closed);
}

test "rotating re-lays out, redraws and refreshes the whole screen" {
    try start(.{});
    defer stop();
    fake.clearUpdates();
    fake.rotate(.landscape_90);
    try testing.expectEqualSlices(inkview.Orientation, &.{ .portrait, .landscape_90 }, fake.state.orientation_sets.items);
    try testing.expectEqual(1024, fake.state.width);
    try testing.expectEqual(1024, host().screen.width);
    try testing.expectEqual(758, host().screen.height);
    try testing.expectApproxEqAbs(1024.0 / scale(), host().screen.viewport().x, 0.5);
    try testing.expectEqualSlices(fake.Update.Kind, &.{.full}, fake.kinds());
    try checkFramebuffer();
    // and the list is still there to tap
    const at = try locateElement(Probe.PickKey{ .pick = 0 });
    fake.tap(at.x, at.y);
    try testing.expectEqual(1, probe().picks);
}

test "coming back to the foreground redraws and refreshes; the background drops updates" {
    try start(.{ .host = .{ .show_refresh = .partial } });
    defer stop();
    fake.clearUpdates();
    _ = fake.send(.background, 0, 0);
    const at = try locateElement(Probe.PickKey{ .pick = 0 });
    fake.tap(at.x, at.y);
    try testing.expectEqual(1, probe().picks);
    try testing.expectEqual(0, fake.state.updates.items.len);
    _ = fake.send(.foreground, 0, 0);
    const k = fake.kinds();
    try testing.expectEqual(1, k.len);
    try testing.expectEqual(fake.Update.Kind.partial, k[0]);
    try testing.expectEqual(fake.state.width, fake.state.updates.items[0].w);
    try checkFramebuffer();
}

test "a post from another thread wakes the loop with one event, and runs a frame" {
    try start(.{});
    defer stop();
    fake.clearUpdates();
    const handler = app.testing.rootInstance(Probe).handler(Probe, .pick);
    const Worker = struct {
        fn post(poster: app.Poster, h: @TypeOf(handler)) void {
            for (0..3) |_| poster.post(h, {}) catch unreachable;
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.post, .{ host().runtime.poster(), handler });
    thread.join();
    try testing.expectEqual(1, fake.state.queue.items.len);
    try testing.expectEqual(root.wake_event, fake.state.queue.items[0].kind);
    try testing.expectEqual(0, probe().picks);
    fake.pump();
    try testing.expectEqual(3, probe().picks);
    try testing.expect(!host().wake_pending.load(.acquire));
    // the next post sends a wake again
    try host().runtime.post(handler, {});
    try testing.expectEqual(1, fake.state.queue.items.len);
}

test "openDirectory is unsupported where the library lacks the selector, and answers where it has it" {
    try start(.{});
    try tapText("Dir");
    try testing.expectEqual(error.Unsupported, probe().dir_error.?);
    stop();

    try start(.{ .fake = .{ .has_directory_selector = true } });
    defer stop();
    try tapText("Dir");
    try testing.expectEqual(1, fake.state.directory_requests);
    try testing.expectEqualStrings("/mnt/ext1", probe().dir.?);
}

test "a framebuffer that isn't gray8 is blitted from a private buffer" {
    try start(.{ .fake = .{ .depth = 24 } });
    defer stop();
    try testing.expect(host().screen.canvas == null);
    try testing.expectEqual(1, fake.state.stretches);
    const at = try locateElement(Probe.PickKey{ .pick = 0 });
    fake.tap(at.x, at.y);
    // the press and the release each redraw and blit
    try testing.expectEqual(3, fake.state.stretches);
}

test "the status panel's height is left out of the viewport when it is shown" {
    try start(.{ .host = .{ .panel = .shown } });
    defer stop();
    try testing.expectEqual(inkview.PanelType{ .enabled = true }, fake.state.panel_type);
    try testing.expectEqual(1024 - 40, host().screen.height);
    try testing.expectApproxEqAbs((1024.0 - 40) / scale(), host().screen.viewport().y, 0.5);
}

test "an explicit scale and a library without get_screen_dpi" {
    try start(.{ .fake = .{ .has_dpi = false }, .host = .{ .dpi = 300 } });
    try testing.expectApproxEqAbs(300.0 / 96.0, scale(), 0.01);
    stop();
    try start(.{ .host = .{ .scale = 1 } });
    defer stop();
    try testing.expectEqual(1, scale());
    try testing.expectEqual(758, @as(u32, @intFromFloat(host().screen.viewport().x)));
    try checkFramebuffer();
}

test "directory cancellation answers null, releases the modal, and allows another chooser" {
    try start(.{ .fake = .{ .has_directory_selector = true, .confirm_directory_immediately = false } });
    defer stop();
    try tapText("Dir");
    try testing.expectEqual(1, host().modal);
    try testing.expectEqual(0, probe().dir_answers);
    fake.directoryResult(null);
    try testing.expectEqual(1, probe().dir_answers);
    try testing.expect(probe().dir == null);
    try testing.expect(host().open_directory == null);
    try testing.expectEqual(0, host().modal);
    try tapText("Dir");
    fake.directoryResult("/mnt/ext1/Books");
    try testing.expectEqual(2, probe().dir_answers);
    try testing.expectEqualStrings("/mnt/ext1/Books", probe().dir.?);
    try checkFramebuffer();
}

test "a lost directory callback is answered null when the next request replaces it" {
    try start(.{ .fake = .{ .has_directory_selector = true, .confirm_directory_immediately = false } });
    defer stop();
    try tapText("Dir");
    fake.loseDirectoryReply();
    // A request queued as the handler returns must also get through.
    try host().runtime.post(app.testing.rootInstance(Probe).handler(Probe, .open_dir), {});
    fake.pump();
    try testing.expectEqual(2, fake.state.directory_requests);
    try testing.expectEqual(1, probe().dir_answers);
    try testing.expect(probe().dir == null);
    try testing.expectEqual(1, host().modal);
    fake.directoryResult("/mnt/ext1/New");
    try testing.expectEqual(2, probe().dir_answers);
    try testing.expectEqualStrings("/mnt/ext1/New", probe().dir.?);
    try testing.expectEqual(0, host().modal);
}

test "returning from a directory UI without a callback resolves cancellation on the next event" {
    try start(.{ .fake = .{ .has_directory_selector = true, .confirm_directory_immediately = false } });
    defer stop();
    try tapText("Dir");
    fake.loseDirectoryReply();
    _ = fake.send(.show, 0, 0);
    try testing.expectEqual(1, probe().dir_answers);
    try testing.expect(probe().dir == null);
    try testing.expectEqual(0, host().modal);
    try testing.expect(host().open_directory == null);
    try tapText("Dir");
    fake.directoryResult("/mnt/ext1/Again");
    try testing.expectEqual(2, probe().dir_answers);
}

test "a replacement requested inside the runtime releases a stale directory reply" {
    try start(.{ .fake = .{ .has_directory_selector = true, .confirm_directory_immediately = false } });
    defer stop();
    try tapText("Dir");
    _ = fake.send(.repaint, 0, 0);
    try testing.expectEqual(0, probe().dir_answers);
    fake.loseDirectoryReply();
    try host().runtime.post(app.testing.rootInstance(Probe).handler(Probe, .open_dir), {});
    // Exercise the service's own fallback before the host checks the handler.
    host().in_runtime = true;
    _ = try host().runtime.frame(Probe, host().props, host().screen.viewport(), fake.clock());
    host().in_runtime = false;
    fake.pump();
    try testing.expectEqual(2, fake.state.directory_requests);
    try testing.expectEqual(1, probe().dir_answers);
    try testing.expect(probe().dir == null);
    fake.directoryResult(null);
    try testing.expectEqual(2, probe().dir_answers);
    try testing.expectEqual(0, host().modal);
}

const ExitWorker = struct {
    started: std.Io.Event = .unset,
    finished: std.atomic.Value(bool) = .init(false),

    fn run(task: *app.Task, self: *ExitWorker) std.Io.Cancelable!void {
        defer self.finished.store(true, .release);
        self.started.set(task.io);
        while (true) {
            try task.checkCancel();
            try task.io.sleep(.fromMilliseconds(60_000), .awake);
        }
    }
};

test "EVT_EXIT cancels and joins a running task, even inside a blocking runtime call" {
    for ([_]bool{ false, true }) |reentered| {
        var worker: ExitWorker = .{};
        try start(.{ .props = .{ .worker = &worker } });
        defer stop();
        try worker.started.wait(testing.io);
        try testing.expect(!worker.finished.load(.acquire));
        fake.clearUpdates();
        host().in_runtime = reentered;
        _ = fake.send(.exit, 0, 0);
        host().in_runtime = false;
        try testing.expect(worker.finished.load(.acquire));
        try testing.expect(host().exiting);
        _ = fake.send(.exit, 0, 0);
        _ = fake.send(.show, 0, 0);
        try testing.expectEqual(0, fake.state.updates.items.len);
    }
}

test "host close paths join runtime tasks before returning from CloseApp" {
    for ([_]bool{ false, true }) |service| {
        var worker: ExitWorker = .{};
        try start(.{ .props = .{ .worker = &worker } });
        defer stop();
        try worker.started.wait(testing.io);
        host().options.close_key = .back;
        if (service) {
            try tapText("Ask");
            fake.answerDialog(1);
        } else {
            _ = fake.pressKey(host().options.close_key.?);
        }
        try testing.expect(fake.state.closed);
        try testing.expect(worker.finished.load(.acquire));
        try testing.expect(host().exiting);
    }
}

test "host watchdog options reach the runtime, including both disable values" {
    try testing.expectEqual(@as(?u32, 16), (root.Options{}).watchdog_ms);
    for ([_]?u32{ 16, 250, null, 0 }) |budget| {
        try start(.{ .host = .{ .watchdog_ms = budget } });
        defer stop();
        try testing.expectEqual(budget, host().runtime.core.watchdog_ms);
    }
}

const WakeWorker = struct {
    started: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    fn run(task: *app.Task, worker: *WakeWorker) std.Io.Cancelable!void {
        worker.started.set(task.io);
        worker.release.waitUncancelable(task.io);
        try task.checkCancel();
    }
};
const WakeProbe = struct {
    pub const State = struct { finished: bool = false, ticks: usize = 0 };
    pub const Props = struct { worker: *WakeWorker, tick_ms: ?i64 = null };
    pub const Msg = union(enum) { done: std.Io.Cancelable!void, tick };
    pub fn update(state: *State, msg: Msg, _: *app.Update(WakeProbe)) !void {
        switch (msg) {
            .done => |result| {
                try result;
                state.finished = true;
            },
            .tick => state.ticks += 1,
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, props: Props) !void {
        const on = ui.messages(WakeProbe);
        try ui.task("worker", .{}, WakeWorker.run, .{props.worker}, on.handler(.done));
        if (props.tick_ms) |ms| try ui.every("tick", .fromMilliseconds(ms), on.bind(.tick));
        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}) }, .background_color = if (state.finished) .black else .white });
        ui.close();
    }
};
const WakeHost = root.App(WakeProbe);
var task_activity_current: bool = false;
var task_activity_true_calls: usize = 0;
fn observeTaskActivity(pending: bool) void {
    task_activity_current = pending;
    if (pending) task_activity_true_calls += 1;
}
fn dropWorkerWake(_: inkview.Handler, _: c_int, _: c_int, _: c_int) callconv(.c) void {}

fn startWakeProbe(worker: *WakeWorker, tick_ms: ?i64) !void {
    var api = fake.api();
    api.SendEvent = dropWorkerWake;
    try WakeHost.run(testing.allocator, testing.io, api, .{ .worker = worker, .tick_ms = tick_ms }, .{
        .clock = fake.clock,
        .task_activity = observeTaskActivity,
    });
}

test "pending tasks reach the framebuffer within 100ms when worker wakes are lost" {
    try fake.init(testing.allocator, .{ .width = 64, .height = 64 });
    defer fake.deinit();
    task_activity_current = false;
    task_activity_true_calls = 0;
    var worker: WakeWorker = .{};
    try startWakeProbe(&worker, null);
    defer WakeHost.instance.deinit();
    defer worker.release.set(testing.io);
    try worker.started.wait(testing.io);
    try testing.expect(task_activity_current);
    try testing.expect(fake.timer("fabrum-frame").?.hard);
    try testing.expect(fake.timer("fabrum-frame").?.due_ms <= 100);
    fake.advance(100); // The activity hook renews an outstanding sleep ban.
    try testing.expect(task_activity_true_calls >= 2);
    const record = WakeHost.instance.runtime.core.tasks.records.items[0];
    worker.release.set(testing.io);
    for (0..5000) |_| {
        if (record.done.load(.acquire)) break;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expect(record.done.load(.acquire));
    try testing.expect(!WakeHost.instance.runtime.rootState(WakeProbe).?.finished);
    fake.advance(100);
    try testing.expect(WakeHost.instance.runtime.rootState(WakeProbe).?.finished);
    try testing.expectEqual(@as(u8, 0), fake.state.framebuffer[0]);
    try testing.expect(!task_activity_current);
    try testing.expect(fake.timer("fabrum-frame") == null);
    try testing.expect(!WakeHost.instance.wake_pending.load(.acquire));
    fake.clearUpdates();
    _ = fake.send(@fromBackingInt(root.wake_event), 0, 0); // A late queued wake is harmless.
    try testing.expectEqual(@as(usize, 0), fake.state.updates.items.len);
    try testing.expect(fake.timer("fabrum-frame") == null);
}

test "pending task fallback preserves earlier declared timer deadlines" {
    try fake.init(testing.allocator, .{ .width = 64, .height = 64 });
    defer fake.deinit();
    var worker: WakeWorker = .{};
    try startWakeProbe(&worker, 40);
    defer WakeHost.instance.deinit();
    defer worker.release.set(testing.io);
    try worker.started.wait(testing.io);
    try testing.expect(fake.timer("fabrum-frame").?.due_ms <= 40);
    fake.advance(40);
    try testing.expectEqual(@as(usize, 1), WakeHost.instance.runtime.rootState(WakeProbe).?.ticks);
    fake.advance(40);
    try testing.expectEqual(@as(usize, 2), WakeHost.instance.runtime.rootState(WakeProbe).?.ticks);
}

test "task activity ends after exit has joined the running worker" {
    task_activity_current = false;
    var worker: ExitWorker = .{};
    try start(.{ .props = .{ .worker = &worker }, .host = .{ .task_activity = observeTaskActivity } });
    defer stop();
    try worker.started.wait(testing.io);
    try testing.expect(task_activity_current);
    _ = fake.send(.exit, 0, 0);
    try testing.expect(worker.finished.load(.acquire));
    try testing.expect(!task_activity_current);
    try testing.expect(fake.timer("fabrum-frame") == null);
}
