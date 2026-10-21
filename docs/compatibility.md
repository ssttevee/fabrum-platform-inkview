# Device build and firmware compatibility

What the device build produces, which firmware it runs on, and how that was
checked. PocketBook readers run old Linux kernels and C libraries, so a
binary has to be careful about which system functions it uses. The
[README](../README.md) covers building and deploying.

## The device build

`zig build` and `zig build app` build for the PocketBook Verse (Allwinner
B288) no matter what `-Dtarget` or `-Dcpu` says:

- target `arm-linux-gnueabi`, glibc 2.23, dynamically linked;
- CPU `cortex_a7`;
- `ReleaseSmall` by default.

`-Ddevice-optimize=small|safe|fast|debug` chooses the device build's
optimization. `safe` keeps safety checks and symbols, which helps with crash
traces from the device. `-Doptimize` controls the host tests, the public
module and the emulator instead.

The output, checked with `file` and `llvm-readelf`, is a 32-bit ARM EABI5
executable:

- soft-float (`e_flags 0x5000200`, no `Tag_ABI_VFP_args`);
- interpreter `/lib/ld-linux.so.3`;
- no InkView symbols linked in (`libinkview.so` is loaded at start-up with
  `dlopen`).

Its size depends on the optimization mode and the app.

## C library versions

The highest glibc symbol version the binary needs is `GLIBC_2.17`, for the
clock functions. That's within firmware 6.8's glibc 2.23. There is no 6.9
SDK, but the official Verse 6.9.862 firmware's root filesystem also has
glibc 2.23.

`NEEDED` lists `libc.so.6`, `ld-linux.so.3`, `libpthread.so.0` and
`libdl.so.2`. The last two supply std's threaded `Io` functions and
`dlopen`/`dlsym` on glibc 2.23, and all their required versions are
`GLIBC_2.4`. No `librt` is needed: the clock functions are in libc at
`GLIBC_2.17`. On glibc 2.39 (6.10), libc itself supplies the old pthread
and dl symbols, and the compatibility libraries keep their version nodes.

The versioned imports in the checked build were checked against the 6.8 and
6.10 B288 sysroots, and against the official Verse
[U629.6.9.862](https://download.pocketbook-int.com/fw/Liangyan/629/user/20250814/sw_20250814_U629_6.9.862_user.zip)
and [U629.6.10.1461 firmware images](https://download.pocketbook-int.com/fw/Liangyan/629/user/20250826/sw_20250826_U629_6.10.1461_accessibility_eink_user.zip).
The 6.10 image's root filesystem contains `/lib/libpthread.so.0` and
`/lib/libdl.so.2`, byte-identical to the 6.10 B288 SDK copies. The
libinkview docs say 6.10 "dropped" them, but that describes libinkview's
own `NEEDED` list, not their removal from the filesystem. Other firmware
images have not been checked.

The RK3566 6.11 SDK is hard-float, and is a different target.

## Randomness

ReaderShell, this host, fabrum and z2d don't ask for random numbers. Hash
maps use fixed seeds, and `std.process.Init` constructs `std.Io.Threaded`
without seeding its random generator.

The `Io` vtable still brings std's entropy code into the binary. With Zig
0.17, libc linked and glibc pinned below 2.25, that code reads
`/dev/urandom` rather than calling the `getrandom` syscall. The device build
checks this choice at compile time. Its ELF has no `getrandom`,
`getentropy` or `arc4random` import, and no ARM `getrandom` syscall. No
std override or fabrum change is needed.

That doesn't make future uses of `io.randomSecure` work on the B288's 3.10
kernel. std's `/dev/urandom` path first checks the file with `statx`, which
that kernel also lacks, and returns `error.EntropyUnavailable` if the check
fails. `io.random` then falls back to std's weaker PID/time/address seed. An
app that needs secure randomness needs its own `/dev/urandom` reader that
works without `statx`.

## File sizes and metadata

`std.Io.Threaded` asks for a file's size and metadata with the `statx`
syscall (Linux 4.11+), whatever the kernel. So `File.length`, `File.stat`,
`Dir.statFile`, and anything that calls them, fail on the B288's 3.10
kernel. Opening, reading and writing files don't use `statx` and work fine.

The example reads no files (its font is embedded). An app that needs file
sizes or metadata needs a `std.Io` whose stat functions use
`fstat`/`fstatat`, which glibc 2.23 has.

## Launcher environment

`ReaderShell-log.app` sets `GLIBC_TUNABLES=glibc.rtld.execstack=2`.
Firmware 6.11.1480 refuses to `dlopen` a library with an executable stack
without it. It's harmless elsewhere.
