//! Opt-in host spans. These measure CPU/host API time, never optical latency.
//! No allocation, clock reads or output when the sink is null. Callbacks run
//! synchronously on the loop thread: keep them short and do not reenter the host.
const std = @import("std");
const refresh = @import("refresh.zig");
const Io = std.Io;

pub const Phase = enum {
    event,
    /// Input dispatch includes synchronous application updates.
    dispatch_updates,
    frames,
    /// Runtime.frame exposes updates, views and layout as one operation.
    runtime_update_layout,
    damage,
    raster,
    /// Private framebuffer blit and native status-panel drawing.
    composite,
    /// InkView refresh API submission/return, including its blocking time.
    present,
    frame_timer,
    a2_timer,
    modal_resume,
};

pub const Sample = struct {
    id: u64,
    parent_id: u64,
    phase: Phase,
    started_ns: i96,
    elapsed_ns: i96 = 0,
    event_kind: ?c_int = null,
    /// Only present spans have a waveform and submitted rectangle statistics.
    update: ?refresh.Update = null,
    rectangles: u64 = 0,
    /// Sum of clipped submitted pixel rectangle areas, including overlaps.
    area_px: u64 = 0,
    /// FullUpdate includes the native status panel, if visible.
    screen_area_px: u64 = 0,
    failed: bool = false,
};

pub const Sink = struct {
    context: ?*anyopaque = null,
    emit: *const fn (?*anyopaque, Sample) void,
};

pub const Recorder = struct {
    sink: ?Sink = null,
    next_id: u64 = 0,
    parent_id: u64 = 0,

    pub fn begin(self: *Recorder, io: Io, clock: ?*const fn () Io.Timestamp, phase: Phase) ?Sample {
        if (self.sink == null) return null;
        self.next_id +%= 1;
        // Reserve zero for spans without a parent even after wraparound.
        if (self.next_id == 0) self.next_id = 1;
        const sample: Sample = .{
            .id = self.next_id,
            .parent_id = self.parent_id,
            .phase = phase,
            .started_ns = now(io, clock).nanoseconds,
        };
        self.parent_id = sample.id;
        return sample;
    }

    pub fn end(self: *Recorder, io: Io, clock: ?*const fn () Io.Timestamp, sample_: ?Sample) void {
        var sample = sample_ orelse return;
        sample.elapsed_ns = now(io, clock).nanoseconds - sample.started_ns;
        self.parent_id = sample.parent_id;
        const sink = self.sink.?;
        sink.emit(sink.context, sample);
    }

    fn now(io: Io, clock: ?*const fn () Io.Timestamp) Io.Timestamp {
        return if (clock) |read| read() else Io.Clock.awake.now(io);
    }
};

/// Convenient diagnostic sink. For lower perturbation, collect into a bounded
/// caller-owned buffer instead and write it outside the measured interaction.
pub fn log(_: ?*anyopaque, sample: Sample) void {
    std.debug.print("INKVIEW_TIMING id={d} parent={d} phase={t} start_ns={d} elapsed_ns={d} event={any} update={any} rects={d} area_px={d} screen_area_px={d} failed={any}\n", .{
        sample.id,         sample.parent_id, sample.phase,      sample.started_ns, sample.elapsed_ns,
        sample.event_kind, sample.update,    sample.rectangles, sample.area_px,    sample.screen_area_px,
        sample.failed,
    });
}

test "disabled timing reads no clock; nested spans restore parents including failed spans" {
    const T = struct {
        var reads: usize = 0;
        var samples: [3]Sample = undefined;
        var count: usize = 0;
        fn clock() Io.Timestamp {
            reads += 1;
            return .{ .nanoseconds = @as(i96, @intCast(reads)) * 1000 };
        }
        fn emit(_: ?*anyopaque, sample: Sample) void {
            samples[count] = sample;
            count += 1;
        }
    };
    T.reads = 0;
    T.count = 0;
    var recorder: Recorder = .{};
    recorder.end(std.testing.io, T.clock, recorder.begin(std.testing.io, T.clock, .event));
    try std.testing.expectEqual(0, T.reads);
    recorder.sink = .{ .emit = T.emit };
    const outer = recorder.begin(std.testing.io, T.clock, .event);
    var inner = recorder.begin(std.testing.io, T.clock, .runtime_update_layout);
    inner.?.failed = true;
    recorder.end(std.testing.io, T.clock, inner);
    const sibling = recorder.begin(std.testing.io, T.clock, .present);
    recorder.end(std.testing.io, T.clock, sibling);
    recorder.end(std.testing.io, T.clock, outer);
    try std.testing.expectEqual(3, T.count);
    try std.testing.expectEqual(1000, T.samples[0].elapsed_ns);
    try std.testing.expect(T.samples[0].failed);
    try std.testing.expectEqual(T.samples[2].id, T.samples[0].parent_id);
    try std.testing.expectEqual(T.samples[2].id, T.samples[1].parent_id);
    try std.testing.expectEqual(0, recorder.parent_id);
    try std.testing.expectEqual(5000, T.samples[2].elapsed_ns);
}
