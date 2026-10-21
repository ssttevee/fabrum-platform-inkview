# fabrum gaps found while building this package

Building this package exposed a few things fabrum couldn't do yet. All of
them have since been fixed in fabrum.

- **Touch panning.** A drawn scroll container could only be moved with the
  mouse wheel, the scrollbar's thumb, or `scrollTo`. Apps had to declare
  `on_pointer` on the list and call
  `ctx.scrollTo("chapters", .{ .by = … }, .{})` from each drag. Now the
  runtime pans by itself when `Capabilities.pointer` is `touch`: a press on
  a list becomes a pan once it moves past the drag threshold, which cancels
  the tap even on a row's button. Apps declare nothing.
- **Refresh hints for app scrolls.** Scrolls the app asked for (`scrollTo`)
  were always `content`. They now take `ScrollOptions`, so a scroll that
  follows a gesture of the app's own can use
  `.{ .refresh = .interactive }`. The page keys keep the default, `content`:
  a quality partial update of the list, which is right for a page turn.
- **Layout capacity.** A list with more rows than `Context.Config.breadth`
  allowed crashed with `unreachable`. Now the frame fails with
  `error.LayoutCapacity`, and the log says which limit to raise.
  (`ReaderShell.layout_capacity` raises it.)
