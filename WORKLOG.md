# WORKLOG — upscale stand-in on Steam Deck OLED (RADV Van Gogh)

Branch: `test/upscale-fix`
Base: `1edb89b310` (docs handoff), source of `src/video_core/engines/kepler_compute.cpp`
matches `origin/pr614` (`b536a971a5`).

## Question

The green boy with the ocarina reaches gameplay (videos + audio, New Game survives), but
the 3D world stays black. Upstream PR #614 reports that on RADV RX 7800 XT (docked, 1x,
tensor unset) the world renders, with only the 11 HMMA compute programs rejected and the
upscale stand-in drawing the final image. Why does the same stand-in not produce a visible
world on the Deck's RADV Van Gogh build?

## Evidence from the Deck log

Log: `/home/deck/.local/share/eden/log/eden_log.txt` (41.9 s run, docked 1x, tensor unset)
and `eden_log.txt.old.txt` (longer run).

- The 11 HMMA programs are rejected and the stand-in runs:
  `Upscale fallback for program 0x216c8b0500: plain copy`.
- The chosen pair in both runs is **1920x1080 -> 2560x1440** and the blit is reported as
  `blitted`:
  - new log: `0x216f941000 1920x1080 ... -> 0x811344a000 2560x1440 ...`
  - old log: `0x216ff41000 1920x1080 ... -> 0x811344a000 2560x1440 ...`
- The chosen **source reads as zero**: `Upscale fallback image 0x216f941000: 0/2024
  sampled words non-zero, mean channel 0` (old log: same for `0x216ff41000`).
- `0x216f941000` / `0x216ff41000` is exactly the GPU address the video decoder service is
  handed at `nx2:vdecsvc TIPC 6 Start` in the same run. In other words the stand-in was
  copying a decoder buffer, not the rendered scene, so the 1440p image stayed black. The
  output address `0x811344a000` is real: the very next draw samples it
  (`fs handle[8] = ... 0x811344a000 2560x1440`), so a correct source would be presented.
- The case the PR fixed (`cbuf0+0x80..0x11c` picking a 4x4 / 120x67 image) is already
  handled in our tree; the remaining failure mode is a *zero* image that still passes the
  geometry/format tests.

## Hypothesis

The stand-in's pair selection accepts the first plausible geometry/format candidate even
when the candidate holds no pixels. On the Deck run a video-decoder image (1920x1080,
A8B8G8R8, same format as the 1440p output) wins over the real DLSS input, which is blank at
the title/attract screen but rendered in gameplay. The world is not black because the
stand-in is missing; it is black because the stand-in copies an empty buffer.

Secondary hypothesis from the PR body (final pass rejected for a texture gather rather than
a matrix multiply) is also covered: our tree had no such rejection in these logs, but the
stand-in now runs for any rejected program that has a sensible image pair.

## Changes

`src/video_core/engines/kepler_compute.cpp`, `kepler_compute.h`:

1. **The stand-in fires for any rejection, not only `matrix multiply`.** In
   `DispatchNativeCompute`, every rejection whose program offers a plausible image pair
   calls `UpscaleInsteadOfNativeProgram()`. Matrix-multiply rejections still dump
   `DescribeNativeResources` first. The function returns false when there is nothing to
   copy, so unrelated rejected programs are not given a bogus blit.
2. **Content-aware pair selection.** The fixed slots (`+0x90/+0xa0`, `+0x328/+0x348`), the
   program's own TEX/TLD/TLD4 reads and SUST.P stores, and the cbuf scan now produce
   candidate pairs. A cheap, cached 16-word probe (`ImageHasContent`) prefers a pair whose
   source has pixels; zero sources are re-probed at most every 30 fallbacks so the common
   path does not flush every frame. Video-decoder / untouched buffers lose to the rendered
   scene.
3. **Never leave the final image unwritten.** If no upscale pair exists, the largest
   blit-able read image is stretched into the largest blit-able store image. If the chosen
   formats cannot be blitted, the program is logged and the old fall-through is kept.
4. **Bounded diagnostics** (first 12 programs, first 8 decisions): each candidate handle
   with TIC index, address, size, format and block-linear flag, and the chosen pair with
   the decision (`pair with content`, `pair without content`, `no pair, stretched largest
   read`) and source emptiness. This is what the next Deck log should be read against.
5. **E5B9G9R9 / format handling** is preserved for the input (32-bit placeholder surface +
   `g_blit_source_format`), and candidate pairs now require a blit-able source and
   destination, so an unsupported format can no longer be selected only to fail later.
   Same-address pairs are still rejected by `UpscaleImagePair`; the stretch fallback also
   refuses to copy an image onto itself.

No new environment variable; the existing `EDEN_NX2_TENSOR`/`EDEN_NX2_DLSS_REPLACEMENT`
switches are untouched.

## Addendum: `Draw skipped (no pipeline)` at world load

Checked as requested:

- No `Skipping shader`, `HasBrokenPattern`, or `Shader <Error>` lines in the 41.9 s log.
  The graphics shaders of the world-load draws are not rejected by shader translation.
- The skips occur immediately after `Graphics pipeline built on the GPU thread in 2-15 ms`
  and match the asynchronous-shader path: `PipelineCache::BuiltPipeline()` returns null
  while a newly created pipeline is not `IsBuilt()` yet (async driver compile), for
  `zeta_enable == false` and a draw with more than 6 indices. Each logged `(vs, ps)` is a
  first use and the reporter logs each pair once; there is no repeated permanent miss and
  no panic.
- Therefore this is *not* the black-world root cause by itself, but it can cost the first
  frame(s) of a newly seen world shader. The existing `docked-sync` launcher profile
  (`lichii-oot-docked-sync.ini`, `use_asynchronous_shaders=false`) is the A/B test; no
  pipeline-cache change was made here.

## How to test on the Deck

1. Install the `linux-x86_64` artifact from the CI run (see the final report for URL/name),
   extract the AppImage with `--appimage-extract`, put it under
   `/home/deck/Applications/lichii/builds/<name>/` and point `current` at its
   `squashfs-root` (keep the old builds).
2. Run the upstream working config first:
   `EDEN_NX2_PROFILE=docked ./lichii-oot.sh --auto --capture` (1x, no
   `EDEN_NX2_TENSOR`).
3. In the log look for:
   - `Upscale candidates for program ...` with read/store handles (new),
   - `Upscale fallback (pair with content, source has content): ...` and a non-zero
     `Upscale fallback output after blit`,
   - no `Upscale fallback ... source is empty` for the chosen pair.
4. If the world is still black, repeat with `EDEN_NX2_PROFILE=docked-sync` to remove the
   async first-use skips, then with the handheld profile to compare video behaviour.

## Confidence

Medium. The chosen source being a zero decoder buffer is proven from two logs; preferring
a non-empty, program-referenced image is the smallest change that can turn the existing
stand-in into a visible world. It does not rely on a new env var and keeps the old
behaviour when no non-empty candidate exists. The remaining risk is that the real input is
not among the program's handles on this title; the new candidate log will show that
immediately.

## If it still fails

- Read the new `Upscale candidates` block for the rejected program and compare the
  `format/size/address` of reads vs. stores. If the real scene (expected 1920x1080,
  E5B9G9R9 or B10G11R11) is absent, extend `NativeImageHandles` (TEX/TLD binding != 0 and
  bindless/TEXS forms) and re-check the cbuf offset field width against the Ampere
  lowering (`insn.Bits(40,14)` -> Maxwell `Bits(36,...)`).
- If the source is the right image but the blit still reads black, check
  `g_blit_source_format`/E5B9G9R9 on RADV Van Gogh and try the stride/pitch-linear case
  (the stand-in currently requires block-linear on both sides).
- If the world draws are only ever skipped, test `docked-sync` (async shaders off) before
  touching the pipeline cache.
