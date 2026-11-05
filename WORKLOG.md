# WORKLOG — config matrix: video regression on Deck OLED (test/config-matrix)

Date: 2026-11-06. Branch: `test/config-matrix`. Scope: isolate the video
regression (docked/no-tensor run made videos audio-only) and produce a test
matrix + profile files. No launcher edits; no game title or title ID in this
file or in `profiles/`.

## TL;DR

1. **The installed profiles never changed some of the settings they name.** The
   emulator only applies a value when its companion line is
   `key\default=false`. With `key\default=true` it resets the setting to the
   compiled-in default and ignores the value line (verified by a no-ROM
   read/write round-trip of the installed inis, see below). Consequences:
   - every local "docked" profile is still **Handheld** (`use_docked_mode` was
     written as `\default=true` + value 1 and reads back as 0);
   - `accelerate_astc=0` in the new `docked` profiles is ignored and stays
     **Gpu**;
   - `gpu_accuracy`/`resolution_setup`/`scaling_filter` in the old
     `lichii-deck.ini` happen to equal their defaults, so they were harmless,
     but `docked` was not.
   So the upstream "docked, 1x, no tensor" configuration **has not actually
   been tested locally**. The failing run was Handheld + 1x + GPU Low
   (split on) + async + no tensor.
2. The failing 41.9 s log decodes **one** AV1 frame, then no frame 600 and no
   end-of-stream, while presents continue to #1200. The last known-good video
   log (evaluated with High accuracy and async shaders off) decodes **7200**
   frames. The failing log is the only one with
   `GPU thread split: engine methods run on a second thread` (GPU Low enables
   `EDEN_NX2_SPLIT=2`; GPU High disables it). **GPU Low/split is the prime
   suspect for the decode stall**, with async shaders the secondary one.
3. The upscale stand-in does **not** intercept `vi2` presents directly, but it
   does feed the frame that is finally composited: the final draws sample the
   stand-in output (`0x811344a000`) into the 1920x1080 composite and then into
   the 2560x1440 present images. Its chosen source (`0x216f941000`) read back
   all zero at 21.3 s, so no-tensor runs can blank both video and world while
   audio continues. `EDEN_NX2_TENSOR=stub` avoids the replacement blit.
4. `Draw skipped (no pipeline)` is **first-use async compile lag**, not a
   persistent failure: 11 skips, 11 distinct draw signatures, each immediately
   after a 2–15 ms GPU-thread pipeline build. Each skip has a different draw
   signature, so these are first uses, not a compile loop.
   `use_asynchronous_shaders=false` should make it 0.

## Ranked root-cause hypotheses

| # | Hypothesis | Evidence | Test |
|---|---|---|---|
| 1 | **GPU Low enables the GPU thread split and stalls video submission after one frame** | failing log: split line at 3.13 s, 1 decoded frame; known-good log: no split line, 7200 frames; all other renderer values (1x, ScaleForce, GPU ASTC, BC3, no tensor) match | p04 vs p02/p03 |
| 2 | **Async shaders alone drop the video/first world draws** | failing log: 11 first-use `Draw skipped`, each after an async pipeline build; known-good log: 0 (sync) | p03 vs p02 |
| 3 | **No-tensor + true docked: the replacement blit overwrites the frame with a blank source** | stand-in source 0/2024 non-zero, output 19/3597; final draws read the stand-in output; held-handed stub runs keep video | p05/p06 vs p08 |
| 4 | `EDEN_NX2_REJECT_HASH` (set by launcher, absent from the known-good GUI log) rejects the video/composite shader | only difference in launch env; not yet isolated | p09 |
| 5 | `accelerate_astc=Cpu` (intended in the new docked profiles, currently ignored) changes memory/pipeline timing | never actually active; Lichii #134 reports Low accuracy as the black-world trigger, not ASTC | p10 |

### Explicitly not the cause (from the two logs)

| Check | Known-good log | Failing log | Conclusion |
|---|---|---|---|
| `Storage buffer failed to track` | 544 | 0 | SSBO fix is not the video regression |
| `Read32 of unmapped` | 16 | 16 | the stand-in's debug sampler reads its six hard-coded RT addresses (`kepler_compute.cpp` ~1103); not game traffic |
| `SIGSEGV` / `Unimplemented` assert | 0 / 7 asserts | 0 / 2 | no host crash in the failing run |
| `PresentClientBuffer` | continues | continues to #1200 | present thread is not stalled |
| audio sink | pipewire, 48 kHz | pipewire, 48 kHz | audio path is fine |
| HMMA rejected | 10 | 10 | the stand-in runs in both |

## Code paths

### 1. Present and composite (`src/core/hle/service/nx2_gsv.h`)

- `INx2Vi2Session::PresentClientBuffer` (1724–1819): waits the frame fence,
  calls `Composite(w[5], ~w[22], w[24], w[7])`, paces to vblank, replies with
  all buffer slots free.
- `Composite` (1953–2047): looks up the present image in `m_objects->images`,
  computes the block-linear layout from preference words
  (`Nx2CalculateImageLayout`, 1486–1503: word 4 = block-height log2, word 5 =
  pitch in 64-byte GOBs), reads the format from preference word 6 (1 = RGBA8,
  4 = RGB10A2), crops (handheld clamps to 1920×1080 at 1993–1995) and submits a
  `FramebufferConfig` to `GPU().RequestComposite`. This path does **not** run
  any upscale; it scans out an image as-is.
- Decoder output images are a different layout family:
  `Nx2CalculateDecoderImageLayout` (1592–1617), code 1/4 = NV12, pitch-linear
  rows, half-height chroma plane padded to 128 rows. They are written by
  `DecodeLoop`/`WriteImage` (2721–2910), not by `Composite`.

### 2. Upscale stand-in / temporal upscale / E5B9G9R9
(`src/video_core/engines/kepler_compute.cpp`)

- A rejected HMMA program that reaches `DispatchCompute` calls
  `UpscaleInsteadOfNativeProgram` (582–603). `stub` makes HMMA `D = C`, so the
  program is never rejected and the stand-in never runs.
- `UpscaleInsteadOfNativeProgram` (937–1195) picks a source/destination:
  1. 0x90/0xa0 (title 4), 2. 0x328/0x348 (Fortune's Weave), 3. handles found in
  the program's own TEX/TLD/SUST instructions (`NativeImageHandles`, 901–935),
  4. first same-format upscale pair in cbuf0+0x80..0x11c.
- E5B9G9R9 has no 2D surface format; the source is blitted as B10G11R11 and
  `VideoCommon::g_blit_source_format` makes the texture cache sample it as
  E5B9G9R9 (1021–1026, 1157–1162).
- Temporal upscale (FSR 3.1 or the temporal stand-in) only runs for the
  Fortune's Weave signature (`fortunes_weave`, 1140–1156); it cannot touch this
  title's video. FSR 3.1 also resets its history after a >250 ms gap (movies),
  `vk_texture_cache.cpp` ~1544.
- **Interception:** none at `Composite`. The interception is one level earlier:
  the game draws the stand-in output (2560×1440 at `0x811344a000`) into the
  1920×1080 composite (`0x81252ff000`), then into both 2560×1440 present
  images. Failing log at 21.46 s:
  `draw rt0 0x81252ff000 ... fs[8] = 0x811344a000 2560x1440`, then
  `draw rt0 0x210ba74000/0x210c974000 ... fs[8] = 0x81252ff000`.
  Sampling the stand-in source gave `0/2024` non-zero, output `19/3597`, so the
  composite and both present images are blank.

### 3. Why the decode stall is a separate bug

`DecodeLoop` (2721–2815) is independent of presentation: submit → libdav1d →
WriteImage into a decoder image → push output → `IncrementGuest(syncpoint)`.
The client must keep submitting for frame 600/end-of-stream to appear. In the
failing log only frame 1 is written and there is no end-of-stream line, so the
game stopped feeding the decoder (or the frame-1 fence never completed for it)
even though presents continued. The stand-in cannot cause that. The only
configuration-level difference from the 7200-frame log is GPU accuracy Low
(split on) and async shaders on.

## Log comparison

| Item | `eden_log.txt.old.txt` (known-good video) | `eden_log.txt` (failing run) |
|---|---|---|
| frontend | Qt GUI, `/home/user/.config/eden/qt-config.ini` | eden-cli, lichii inis |
| build | 5f90244581 | 5f90244581 |
| resolution | Res1X | 1x (present 2560×1440, drawn 1920×1080) |
| use_docked_mode | Handheld | Handheld in the effective file (see below) |
| gpu_accuracy | High | Low (`GPU thread split` logged) |
| async shaders | false | true |
| scaling filter | ScaleForce | ScaleForce/FSR (present path identical) |
| tensor | unset | unset |
| HMMA rejected | 10 | 10 |
| AV1 frames decoded | 7200 | **1** |
| `Draw skipped (no pipeline)` | 0 | 11 (first-use; one per draw signature) |
| stand-in source | `0x216ff41000`, 0/2024 non-zero | `0x216f941000`, 0/2024 non-zero |
| `Storage buffer failed to track` | 544 | 0 |
| crash | none | none |

## The `\default` trap (verified)

`Config::ReadSettingGeneric` (`src/frontend_common/config.cpp:909–932`) reads
`key\default`; when it is true it calls `LoadString("")`, i.e. resets to the
compiled default and **ignores `key=value`**. Only `key\default=false` applies
the value. A no-ROM round-trip with the installed binary (`eden-cli -c
<copy>`; it reads the config before failing on the missing ROM, then rewrites
it) shows:

| Installed file | Written | Read back / effective |
|---|---|---|
| `lichii-deck.ini` | `use_docked_mode\default=true`, `use_docked_mode=0` | Handheld |
| `lichii-oot-docked.ini` | `use_docked_mode\default=true`, `use_docked_mode=1` | **Handheld (docked ignored)** |
| `lichii-oot-docked-sync.ini` | same | **Handheld (docked ignored)** |
| `lichii-oot-docked.ini` | `accelerate_astc\default=true`, `accelerate_astc=0` | **Gpu (CPU ignored)** |
| `lichii-deck.ini` | `gpu_accuracy\default=false`, `gpu_accuracy=0` | Low (applied) |
| `lichii-oot-fidelity.ini` | `resolution_setup\default=false`, `=2` | 0.75x (applied) |

Therefore the old "docked" test was effectively Handheld + 1x + ScaleForce +
Low + async + GPU ASTC + no tensor, and the new `docked`/`docked-sync`
profiles are effectively Handheld + 1x + ScaleForce + High + (async|sync) +
GPU ASTC + no tensor. **All profiles in this worktree set
`key\default=false` for every matrix key.**

`profiles/run-profile.sh` merges an overlay into a copy of a full base ini
(so audio/CPU/controls stay known), sets the launcher's common environment,
and launches. It never edits `/home/deck/Applications/lichii`.

## Test matrix

`profiles/` contains one overlay per row. `D` = `use_docked_mode`,
`res` = `resolution_setup`, `f` = `scaling_filter`, `acc` = `accelerate_astc`,
`gpu` = `gpu_accuracy`, `async` = `use_asynchronous_shaders`,
`astc` = `astc_recompression` (BC3 in every row), `tensor` = `EDEN_NX2_TENSOR`.
Every row forces `use_vsync=2` (Fifo) so vsync is not a variable.

| Profile | D | res | f | gpu | async | acc | tensor | video (expect) | world (expect) | audio | crash | split log | Draw skipped |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| p01-handheld-075-stub | 0 | 0.75x (2) | FSR (6) | High | on | Gpu | `stub` | yes (known) | black (known) | yes | no | no | ~11 first-use |
| p02-handheld-1x-sync-high | 0 | 1x (3) | ScaleForce (5) | High | off | Gpu | unset | yes (old log) | black | yes | no | no | 0 |
| p03-handheld-1x-async-high | 0 | 1x (3) | ScaleForce (5) | High | on | Gpu | unset | ? | black | yes | no | no | ~11 |
| p04-handheld-1x-async-low | 0 | 1x (3) | ScaleForce (5) | **Low** | on | Gpu | unset | **no** (1 frame, repro) | black | yes | no | **yes** | ~11 |
| p05-docked-1x-async-high | **1** | 1x (3) | ScaleForce (5) | High | on | Gpu | unset | ? | ? | yes | ? | no | ~11 |
| p06-docked-1x-sync-high | **1** | 1x (3) | ScaleForce (5) | High | off | Gpu | unset | ? | ? (upstream analog) | yes | ? | no | 0 |
| p07-docked-1x-async-low | **1** | 1x (3) | ScaleForce (5) | **Low** | on | Gpu | unset | ? | ? | yes | ? | **yes** | ~11 |
| p08-docked-1x-sync-high-stub | **1** | 1x (3) | ScaleForce (5) | High | off | Gpu | `stub` | yes? | black (stub) | yes | ? | no | 0 |
| p09-handheld-1x-async-high-noreject | 0 | 1x (3) | ScaleForce (5) | High | on | Gpu | unset | ? | ? | yes | no | no | ~11 |
| p10-handheld-1x-async-high-astc-cpu | 0 | 1x (3) | ScaleForce (5) | High | on | **Cpu (0)** | unset | ? | ? | yes | no | no | ~11 |

`?` = unknown until the morning. Fill the observed column in after each run.

### Check after each run (last session only)

```bash
L=/home/deck/.local/share/eden/log/eden_log.txt
grep -c "GPU thread split"                          "$L"   # 0 = High, 1 = Low
grep -c "DecodeLoop.*frame 1 "                      "$L"   # exactly 1 expected
grep -cE "DecodeLoop.*frame (600|1200|1800) "       "$L"   # >0 = decode alive
grep -c "end of stream"                             "$L"   # 1 = movie completed
grep -c "Draw skipped (no pipeline)"                "$L"   # 0 with sync
grep -c "Native compute shader rejected"            "$L"   # 10 with no tensor, 0 with stub
grep -c "Storage buffer failed to track"            "$L"   # 0 expected
grep -c "SIGSEGV"                                   "$L"   # 0 expected
```

A run that "works" should show `DecodeLoop frame 600`, `frame 1200`, … (or
`end of stream`), no split line, and either 0 HMMA rejects (stub) or the 10
HMMA stand-in blits (no tensor). Video visibility is separate from decode
count: watch for the `Upscale fallback ... 1920x1080 ... -> ... 2560x1440`
line and whether the frame after it is non-black.

## Exact env (same as the launcher, for direct `eden-cli` runs)

```
HOME=/home/deck
XDG_CACHE_HOME=$HOME/.cache  XDG_CONFIG_HOME=$HOME/.config  XDG_DATA_HOME=$HOME/.local/share
EDEN_NX2_AUTO_STUB=1
MESA_SHADER_CACHE_MAX_SIZE=8G
EDEN_NX2_VRAM_LIMIT_MIB=6144
EDEN_NX2_ASTC_ARRAY_MIB=256
EDEN_NX2_REJECT_HASH=c72b6ea746c00433      # p09 unsets it
EDEN_NX2_SPLIT=2                            # honored only when gpu_accuracy=Low
EDEN_NX2_FENCE_BATCH=1
EDEN_NX2_INLINE_PAGE_WRITES=0
# EDEN_NX2_TENSOR: stub (p01/p08) or unset (all others)
# PULSE_SERVER: leave unset (forcing none muted the Deck)
```

## Exact config keys (overlays use these values)

```
[Renderer]
resolution_setup\default=false           ; 2 = 0.75x, 3 = 1x
scaling_filter\default=false             ; 5 = ScaleForce, 6 = Fsr
astc_recompression\default=false         ; 2 = Bc3
accelerate_astc\default=false            ; 0 = Cpu, 1 = Gpu
use_asynchronous_shaders\default=false   ; true/false
gpu_accuracy\default=false               ; 0 = Low (split on), 1 = High (split off)
use_vsync\default=false                  ; 2 = Fifo

[System]
use_docked_mode\default=false            ; 0 = Handheld, 1 = Docked
```

## First three tests for the morning

Run each to the first world-load frame (or ~60 s), then copy the log before the
next run.

1. **`p06-docked-1x-sync-high`** — the actual upstream analog (true docked, 1x,
   GPU High/split off, sync, no tensor). This is the configuration PR #614
   describes, and it has never been exercised locally because `use_docked_mode`
   was being ignored. Look for `DecodeLoop frame 600`, no split line, 0
   `Draw skipped`, and whether the world is non-black.
2. **`p02-handheld-1x-sync-high`** — identical renderer settings with the only
   difference being Handheld. If p06 keeps video/world and p02 does not, docked
   mode is the variable. If both work, the old 1-frame regression was
   Low/split + async.
3. **`p03-handheld-1x-async-high`** — identical to p02 except async shaders.
   If video stalls at one frame here, async is the killer; if it plays 600+
   frames, GPU Low/split was the killer and p04 is the positive control.

If 1–3 are inconclusive, run **p04-handheld-1x-async-low** to reproduce the
41.9 s signature, then **p05/p07/p08** for true docked / stub.

## Artifacts

- Profiles + runner: `profiles/` (see `profiles/README.md`).
- No code change was made: the root cause is configuration (effective
  `use_docked_mode` never applied; GPU Low/split and async not isolated), not a
  small code bug in the present/stand-in paths. No build or CI artifact.
