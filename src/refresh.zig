//! Which e-ink update shows a frame's damage: fabrum's refresh hint
//! (`content`, `interactive`, `page`) to InkView's update functions, with
//! hysteresis around A2 and a periodic cleaning refresh.
//!
//! - `page` is `FullUpdate` (GC16 with a clearing flash), and resets
//!   everything.
//! - `interactive` (a drag, a scroll) starts with gray `DynamicUpdate`s
//!   (no flash, no collision re-pass), and after `Options.a2_enter_after`
//!   of them in a row switches to `DynamicUpdateA2`: black and white, the
//!   fastest waveform, which ghosts. A gesture of a frame or two never
//!   enters A2, so a tap-scroll doesn't pay the A2 entry and exit.
//! - Once in A2, the mode stays for `Options.a2_exit_delay` after the last
//!   interactive frame, re-armed by each; content frames meanwhile are
//!   gray dynamic updates. When the delay passes (`idle`), one `FullUpdate`
//!   wipes the ghosts (what `ExitUpdateA2` does), from a framebuffer that
//!   always holds full grays, since the host never dithers in place.
//! - `content` is `PartialUpdate` (GC16, no flash); every
//!   `Options.full_every` partial or gray dynamic updates, one `FullUpdate`
//!   clears the ghosting they leave, as readers do every few pages. A2
//!   frames do not advance this counter.
//!
//! The policy is a value: the host feeds it hints and the clock, and
//! calls the function it answers with.
const std = @import("std");
const fabrum = @import("fabrum");
const Refresh = fabrum.app.Refresh;
const Timestamp = std.Io.Timestamp;
const Duration = std.Io.Duration;

pub const Options = struct {
    /// How interactive damage is shown: with A2 after a run of frames, or
    /// always gray (`DynamicUpdate`), for apps that would rather see
    /// grays than speed.
    interactive: enum { a2, dynamic } = .a2,
    /// How many interactive frames in a row before A2 starts; 0 enters
    /// A2 on the first.
    a2_enter_after: u8 = 2,
    /// How long after the last interactive frame A2 ends with a cleaning
    /// full refresh.
    a2_exit_delay: Duration = .fromMilliseconds(700),
    /// Partial or gray dynamic updates between cleaning full refreshes,
    /// or 0 for never.
    full_every: u16 = 12,
};

/// What the host calls for a frame's damage.
pub const Update = enum {
    /// `FullUpdate()`: the whole screen, with a flash.
    full,
    /// `PartialUpdate` of each region.
    partial,
    /// `DynamicUpdate` of each region (`PartialUpdate` if the library
    /// lacks it).
    dynamic,
    /// `DynamicUpdateA2` of each region.
    a2,
};

/// Which update functions the library has.
pub const Available = struct {
    a2: bool = true,
    dynamic: bool = true,
};

pub const Policy = struct {
    options: Options = .{},
    /// Interactive frames in a row.
    run: u8 = 0,
    /// Whether A2 frames have been shown since the last full refresh.
    in_a2: bool = false,
    /// Partial or gray dynamic updates since the last full refresh.
    partials: u16 = 0,
    /// When A2 should end, if it is on.
    exit_due: ?Timestamp = null,

    /// The update for a frame's damage with hint `hint`, shown at `now`.
    pub fn decide(self: *Policy, hint: Refresh, now: Timestamp, available: Available) Update {
        switch (hint) {
            .page => {
                self.reset();
                return .full;
            },
            .interactive => {
                self.run +|= 1;
                const a2 = self.options.interactive == .a2 and available.a2 and self.run > self.options.a2_enter_after;
                if (a2 or self.in_a2) self.exit_due = now.addDuration(self.options.a2_exit_delay);
                if (a2) {
                    self.in_a2 = true;
                    return .a2;
                }
                return self.nonFlashing(if (available.dynamic) .dynamic else .partial);
            },
            .content => {
                self.run = 0;
                if (self.in_a2) {
                    // keep the gesture's exit pending: the cleaning refresh
                    // comes when the user is done
                    self.exit_due = now.addDuration(self.options.a2_exit_delay);
                    return self.nonFlashing(if (available.dynamic) .dynamic else .partial);
                }
                return self.nonFlashing(.partial);
            },
        }
    }

    /// Whether A2 is due to end at `now`, in which case the host does a
    /// `full` update; call it when the exit timer fires.
    pub fn idle(self: *Policy, now: Timestamp) ?Update {
        const due = self.exit_due orelse return null;
        if (now.nanoseconds < due.nanoseconds) return null;
        self.exit_due = null;
        if (!self.in_a2) return null;
        self.reset();
        return .full;
    }

    /// When the host should call `idle`, if A2 is on.
    pub fn exitDue(self: *const Policy) ?Timestamp {
        return self.exit_due;
    }

    fn nonFlashing(self: *Policy, update: Update) Update {
        self.partials += 1;
        if (self.options.full_every > 0 and self.partials >= self.options.full_every) {
            self.reset();
            return .full;
        }
        return update;
    }

    fn reset(self: *Policy) void {
        self.run = 0;
        self.in_a2 = false;
        self.partials = 0;
        self.exit_due = null;
    }
};

const testing = std.testing;

fn at(ms: i64) Timestamp {
    return Timestamp.zero.addDuration(.fromMilliseconds(ms));
}

test "content is partial, page is full and resets the count" {
    var p: Policy = .{ .options = .{ .full_every = 3 } };
    try testing.expectEqual(Update.partial, p.decide(.content, at(0), .{}));
    try testing.expectEqual(Update.partial, p.decide(.content, at(1), .{}));
    try testing.expectEqual(Update.full, p.decide(.content, at(2), .{}));
    try testing.expectEqual(Update.partial, p.decide(.content, at(3), .{}));
    try testing.expectEqual(Update.full, p.decide(.page, at(4), .{}));
    try testing.expectEqual(0, p.partials);
    try testing.expectEqual(Update.partial, p.decide(.content, at(5), .{}));
}

test "a short gesture stays gray; a long one enters A2 and leaves it after the delay" {
    var p: Policy = .{ .options = .{ .a2_enter_after = 2, .a2_exit_delay = .fromMilliseconds(700) } };
    // two frames: gray dynamic updates, nothing to exit
    try testing.expectEqual(Update.dynamic, p.decide(.interactive, at(0), .{}));
    try testing.expectEqual(Update.dynamic, p.decide(.interactive, at(16), .{}));
    try testing.expectEqual(@as(?Timestamp, null), p.exitDue());
    try testing.expectEqual(@as(?Update, null), p.idle(at(2000)));
    // the third enters A2, and each frame pushes the exit out
    try testing.expectEqual(Update.a2, p.decide(.interactive, at(32), .{}));
    try testing.expectEqual(at(732), p.exitDue().?);
    try testing.expectEqual(Update.a2, p.decide(.interactive, at(48), .{}));
    try testing.expectEqual(at(748), p.exitDue().?);
    try testing.expectEqual(@as(?Update, null), p.idle(at(700)));
    try testing.expectEqual(Update.full, p.idle(at(748)).?);
    try testing.expect(!p.in_a2);
    try testing.expectEqual(@as(?Timestamp, null), p.exitDue());
    // a new gesture starts gray again
    try testing.expectEqual(Update.dynamic, p.decide(.interactive, at(1000), .{}));
}

test "content during A2 is gray and keeps the exit pending; page ends A2 at once" {
    var p: Policy = .{ .options = .{ .a2_enter_after = 0 } };
    try testing.expectEqual(Update.a2, p.decide(.interactive, at(0), .{}));
    try testing.expectEqual(Update.dynamic, p.decide(.content, at(100), .{}));
    try testing.expectEqual(at(800), p.exitDue().?);
    try testing.expectEqual(Update.full, p.idle(at(800)).?);

    try testing.expectEqual(Update.a2, p.decide(.interactive, at(1000), .{}));
    try testing.expectEqual(Update.full, p.decide(.page, at(1001), .{}));
    try testing.expectEqual(@as(?Update, null), p.idle(at(5000)));
}

test "without A2 or dynamic updates in the library, gestures are partial" {
    var p: Policy = .{ .options = .{ .a2_enter_after = 0 } };
    try testing.expectEqual(Update.dynamic, p.decide(.interactive, at(0), .{ .a2 = false }));
    try testing.expectEqual(Update.partial, p.decide(.interactive, at(1), .{ .a2 = false, .dynamic = false }));
    try testing.expect(!p.in_a2);
    var gray: Policy = .{ .options = .{ .interactive = .dynamic, .a2_enter_after = 0 } };
    try testing.expectEqual(Update.dynamic, gray.decide(.interactive, at(0), .{}));
}

test "the periodic full refresh counts interactive frames too, and never with full_every 0" {
    var p: Policy = .{ .options = .{ .full_every = 2, .a2_enter_after = 5 } };
    try testing.expectEqual(Update.dynamic, p.decide(.interactive, at(0), .{}));
    try testing.expectEqual(Update.full, p.decide(.interactive, at(1), .{}));
    var never: Policy = .{ .options = .{ .full_every = 0 } };
    for (0..100) |i| try testing.expectEqual(Update.partial, never.decide(.content, at(@intCast(i)), .{}));
}
