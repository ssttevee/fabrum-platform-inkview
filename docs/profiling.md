# Host timing without changing refresh policy

Timing is disabled by default. Opt in when constructing the host:

```zig
const ink = @import("fabrum-platform-inkview");
// In ink.Options:
.timing = .{ .emit = ink.timing.log },
```

This diagnostic sink writes one `INKVIEW_TIMING` line per finished span. For
less perturbation, supply `timing.Sink.context` and an `emit` callback that
copies `timing.Sample` values into a bounded preallocated buffer. Count dropped
samples; flush after the interaction. No buffer allocation, clock reads or
output are performed by timing when the sink is null. Enabled callbacks run
synchronously on the UI thread; they must not block or reenter the host.
Logging itself can dominate short spans on a low-end reader. Compare runs with
tracing disabled, and do not infer power or device speed from fake tests.

`id`/`parent_id` form a span tree. `started_ns` uses the host's monotonic awake
clock (or `Options.clock` in fake tests); `elapsed_ns` is inclusive elapsed
host time. Inner spans end first. Do not add a parent's duration to its children.
`event` includes dispatch and frames through refresh API return, and records
the InkView event number. Worker custom events use the same path. Timer and
modal-resume roots cover drawing without a new input event; reentrant events
retain their actual parent. Time before handler entry (including worker queue
wait) needs application/task timestamps and is not measured by the event span.

Phases:

- `dispatch_updates`: event dispatch and synchronous input-triggered updates.
- `runtime_update_layout`: queued task/timer updates, view construction, layout
  and runtime reconciliation, together. The current fabrum public `frame` API
  exposes no internal timing hook. These costs cannot be separated accurately
  in the platform alone; use a future fabrum hook for an update/layout split.
- `damage`: damage comparison; `raster`: drawing commands into the framebuffer.
- `composite`: private-buffer `Stretch`, if needed, and native panel drawing.
- `present`: InkView refresh API submission/return. It may block; it is **not**
  a measurement of pixels becoming visible or of panel settling.
- `frames`: the encompassing frame loop and host geometry/timer work.
- `frame_timer`, `a2_timer`, `modal_resume`: non-input entry points.

Present samples record the selected update, actual submitted rectangle count,
and sum of submitted pixel areas after scaling, rounding and clipping. Overlap
is counted again, not unioned. `FullUpdate` is one rectangle covering the entire
screen including the native status panel; partial rectangles retain the panel
coordinate offset. `screen_area_px` supplies the denominator for area ratios.
Empty/clipped rectangles are not counted. Background frames do not produce a
present sample because no refresh is submitted. Error-returning spans set
`failed`, and the original error still propagates.

Capture repeated identical operations with consistent firmware, power state,
content and cache state. Report distributions and outliers separately for task
completion, input-to-present-return, runtime, raster, submitted area and blocking
present calls. Measure optical input-to-visible/settled latency separately with
an external camera or sensor. Only change waveform or rectangle policy after
those profiles identify a bottleneck; this instrumentation changes neither.

# Completion rescue versus native wake verification

`task_poll_interval_ms = null` keeps native worker events primary, with an
adaptive hard-timer rescue (250 ms, then 500, 1000, capped at 2000 ms by default).
Configure `task_rescue.initial_ms`/`max_ms` for the desired tradeoff. Only pending
work/cleanup causes rescue ticks; sleep guards remain the app's responsibility.
The deadline bounds a chance to service completion while the loop runs, not
firmware suspend, a blocking SDK call, modal result collection, or worker duration.

A native-wake diagnostic must set **both** `task_poll_interval_ms = null` and
`task_rescue = null`. Otherwise a successful completion could have been rescued.
In PocketManga, update both host options blocks in `src/wake_probe.zig` when
pinning this platform revision; do not disable rescue in the production host
just because paired sleep-preventor symbols exist. The fake tests verify native
`SendEvent` coalescing and delivery without time advancement, lost-wake rescue,
backoff, held-modal ownership and final timer removal. They do not validate any
firmware event loop or physical sleep/wake behavior.
