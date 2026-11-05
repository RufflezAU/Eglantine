# Puller investigation — 2026-11-06 (test/puller-fix)

Target: the green boy with the ocarina. No title or title ID in this file, commits,
branch names or artifacts.

## Hypothesis

The 252 s failure is one command-stream misparse, not several unrelated faults.

The Steam console log from the last run (`~/.local/share/Steam/logs/console-linux.txt`,
03:32:12) contains the pushbuffer dump for the failing submission:

- entry 2752 (`0x2129334fd4`, 61 words) ends with an `IncreaseOnce` header
  `a0050e08` that declares 5 arguments but has only 4 words left in the entry.
- The pusher carries the remaining 1 word into entry 2753 (`0x222e887520`,
  16 words) and consumes its first word `a0030e96` as method data.
- Entry 2753 is actually a complete command list of its own: `a0030e96`
  (method 0xE96, 3 args), `a0050e9a` (method 0xE9A, 5 args),
  `20020701` (method 0x701, 2 args), `20020180` (method 0x180, 2 args).
- Starting at word 1 the pusher instead sees `00000001` (method 1, count 0) and
  then `38800000`, which decodes as method 0 with count 6272. It consumes the
  rest of the entry as arguments: 0x3A400040 becomes a bind argument
  (`Unimplemented engine 3A400040`), then methods 0x1, 0x3, ... 0x35 run as
  puller methods until the process dies at 252.722 s. The last line is cut
  mid-write, so the host died during that burst.
- The earlier `3f800000` entry 2665 and the `0xA0040E20` bind are the same
  failure: constant/header words executed as methods. In the earlier 297 s dump
  entry 2664 (`91000002 911e0002 200406c0 ...`) parses cleanly, then entry 2665
  (`3f800000 a0040e20 11111111 ...`) is a data buffer: `3f800000` decodes as
  method 0 with count 8064, `a0040e20` is its first "argument" (low 16 bits
  0x0E20). Both dumps therefore hit the same guard: data read as a header after
  a clean entry, or after a false multi-entry split.

So the bogus depth format `0x200205f2` and the old `CreateImage` extent are
downstream symptoms of the same misparse. The crash itself is the method burst
(a bogus bind leaves engine state pointing at garbage); no host backtrace was
captured, and no debugger is installed on the Deck, so this is code+log reasoning.

## Fix

1. `src/video_core/dma_pusher.cpp` — `ProcessCommands` now rejects a header whose
   argument count cannot belong to the entry:
   - `BindObject` (method 0) always has one argument, so a count > 1 that does
     not fit is data;
   - any other method with count > 256 words and more than 256 words beyond the
     entry is data (a real split continues by a few words, not hundreds).

   `Inline` headers are exempt: their count field is the inline argument
   (`0x911e0002` is method 2, value 0x111e), so validating it would break real
   command lists. On a hit the parser logs the header, parsed method/count and
   the entry's first words once. If the entry began as the tail of a previous
   method and its first word looks like a command header, the entry is parsed
   again from word 0 (the split was false and its commands are recovered);
   otherwise the rest of the entry is dropped and the bogus count cleared so it
   cannot leak into the next entry.

2. `src/video_core/engines/puller.cpp` — `ProcessBindMethod` no longer installs an
   unknown class as the subchannel's engine. The Switch 2 argument is classified
   by its low 16 bits; a known Ampere class is mapped to the Maxwell engine as
   before, an unknown one logs a bounded warning (class 0x0E20 from 0xA0040E20,
   0x0040 from 0x3A400040) and keeps the previous valid binding. No assert.

3. `src/video_core/surface.cpp` — `PixelFormatFromDepthFormat` replaced the
   `UNIMPLEMENTED_MSG` assert with a bounded log per distinct value and the
   existing Z24 fallback, so `0x200205f2` cannot abort or produce an
   out-of-range `PixelFormat`.

4. `src/video_core/renderer_vulkan/vk_texture_cache.h` — `ViewFormats` bounds-checks
   the `PixelFormat` index before touching `view_formats` (`PixelFormat::Invalid`
   is 255, beyond `MaxPixelFormat`), returning an empty list instead.

## Commits / branch

- Branch: `test/puller-fix`
- `8c095e6fed` video_core: reject implausible pushbuffer headers and unknown binds
- `806905a45e` video_core: bound undecoded depth-format and view-format fallbacks

## CI

- Dispatch: `ci.yml` on `test/puller-fix`, `kind=branch`, `platforms=linux`,
  `pgo=none`, `publish=false`.
- Run: https://github.com/RufflezAU/Eglantine/actions/runs/42069536943
- Status: in progress (dispatch 2026-11-06).
- Linux x86_64 artifact: `eglantine-linux-x86_64-<sha>` (pending).

## Exact test

1. Extract the Linux x86_64 AppImage into a new
   `~/Applications/lichii/builds/eglantine-deck-puller-<sha>/` and point
   `current` at its `squashfs-root`; keep the old builds.
2. `EDEN_NX2_PROFILE=handheld /home/deck/Applications/lichii/lichii-oot.sh --auto --fidelity --fresh --capture --handheld`
   (videos/audio/no-tensor `stub` baseline), then let it run past 252 s.
3. Success criteria: the log has no `Special puller engine method 1..35` burst,
   no `Unimplemented engine 3A400040`, and either the world-load path stops on a
   different, real error or continues presenting. The one-shot diagnostic
   (`Suspicious command header ...`) should appear once and name the entry.
4. A/B with `EDEN_NX2_PROFILE=docked` (1x, `EDEN_NX2_TENSOR` unset) for the
   upstream-rendering configuration.

## Confidence

High that the 252 s SIGSEGV is this misparse: the dump reproduces the exact
burst (0x3A400040 bind, methods 1, 3, E..35) and the guard stops it before any
of those methods run. The same guard also rejects the earlier 297 s entry 2665
(0x3F800000 = method 0, count 8064) before the 0xA0040E20 bind and the garbage
CreateImage, which explains both reported failures with one rule. Medium that no
legitimate split entry is affected:
the gate needs a BindObject count that does not fit, or >256 words beyond the
entry, and the real entry 2752 parses cleanly under the same check. The surface
changes are defensive; the exact host faulting instruction is still unknown
(no gdb/core on the Deck).

## Next idea

If the burst is gone but the host still dies, enable `EDEN_NX2_PB_DUMP` on the
next run to replay that submission offline, and install a debug/coredump-capable
build to catch the host backtrace. If a real large split is rejected, raise
`MaxSplitWords` and add an entry-size-based allowance instead of dropping it.
