# Upstream-fix worklog — 2026-11-06

Target: Steam Deck OLED (Van Gogh, RADV), green boy with the ocarina.
Branch: `test/upstream-fixes`, base `1edb89b310` (deck-oled line: #614 set +
query flush + broadcast-pointer SSBO fix + graphics SSBO sizing).

## What was already in this tree at the start

| Upstream item | State here | Note |
|---|---|---|
| Eglantine #614 (11 commits, `b536a971a5`) | **in tree**, files byte-identical to `origin/pr614` | upscale stand-in + lowerings |
| `scratch/oot-shader-lab` `dbf3417099` (stand-in picks its own images) | in tree via #614 `b536a971a5` | same change |
| `scratch/oot-shader-lab` `29ed33831a` (FP16 pack) | in tree via #614 `dc3e912fb7` |  |
| `scratch/oot-shader-lab` `5c7da2713a` (64 KiB uniform bank per frame) | in tree via #614 `8de2d42a2e` |  |
| `scratch/oot-shader-lab` `405e5f7ac8` (graphics SSBO sizing) | in tree as `5f90244581` | ported earlier |
| `scratch/oot-shader-lab` `c58d474d32` (broadcast pointer tracking) | in tree as `5f90244581` | ported earlier |
| `scratch/oot-shader-lab` `d83a7a346d` / `oot-jojo` `50db8498` (query flush before MME DMA) | in tree as `2d8a06a38f` |  |
| Lab snapshot freshness | `git fetch origin scratch/oot-shader-lab` -> still `1789b05d94`, **no newer commits** | nothing new to pull |
| Eglantine #541 (conditional barriers one-liner) | not applied | tested on RDNA1 against #614 with no change; Windows/amdvlk only |

## Ported in this branch

| Issue / PR | Patch (commit here) | Expected effect | Applied? |
|---|---|---|---|
| Lichii #127 — AMD black scene, nested return + demote reorder | `ce8cace65b` (upstream `85d03631`) | `DemoteCombinationPass` counted `Epilogue` only at depth <= 1, so a nested early return let `if (P0) { if (P1) return; }` exit before the moved demote and write never-set (zero) colour. The half-res particle composite then multiplies the whole scene by zero. Counting returns at any depth keeps demotes in place. Directly targets "world black on AMD, fine on NVIDIA". | **yes** |
| Lichii #121 (1/2) — occlusion counter reset at submission | `aab08992dd` (upstream `e3cf9394`) | `EndPendingOperations` reset `ZPassPixelCount64` before every submission; a split-thread submission between the guest's reset and its report drops samples, the report reads low and the title treats the frame as occluded (white flash / blank). Pause (`CounterClose`) instead of reset. | **yes** |
| Lichii #121 (2/2) — bound the running query | `1af13050cc` (upstream `47e1e952`) | Needed by the pause: a title that counts without reset/report grew the host query to 16k slots over 64 banks, which hung AMD + `EDEN_NX2_SPLIT=2` right after picking a save (`WaitSubmitted` on a tick never submitted). Drop the count once it passes one bank (256 slots). | **yes** |
| Lichii #100 / lab `582ecc4568` — shadow `ISBEWR` data register | `cb74305ede` | The shadowing check never looked at `0x927`'s data operand, so a mesh store from R238/R240 read the emulator's UR mirror; the bad bit mask reads as NaN and bloom turns the geometry into a white glow. One-line opcode-list addition. | **yes** |
| Lichii #103/#104 / lab `575d0a5b`, `5d742e369e` — inline CPU page writes, Preflushable-only fence downloads | not applied | RADV report says frame time 37-55 ms -> 21-31 ms. Perf, not black-world, and it changes buffer ownership rules; keep as the next A/B once the world draws. | no |
| Lab `8dc1e6e9c4` — spin before idling cores | not applied | Perf only (targets the flat ~29 fps report, Lichii #117). CPU scheduling change, needs its own A/B. | no |
| Lab `1992f6ef99` (bind read-only SSBOs at end of mapping) | not applied | **reverted upstream** by `34f24ae551`; not a candidate. | no |
| Lab `b1a0e3fbf8` (fold multiply by 0/1) | not applied | **reverted upstream** by `270732f525`; not a candidate. | no |
| Lab gpu-split back-thread work (`727a9a4eb4`, `3087c1cf07`, `1789b05d94`) | not applied | Large scheduler restructuring + debug/lab tooling; out of scope for a small patch. | no |

## Evidence used

- Eglantine #614 comment (FabianZettl, CachyOS, RX 7800 XT, RADV, docked 1x, no
  tensor): #614 alone renders the world, 0 graphics rejections, 0 skipped draws;
  only the 11 HMMA compute programs are rejected so the stand-in runs. Also that
  `use_docked_mode` defaults to Handheld — relevant to the Deck config matrix.
- Same comment: on RADV, #103/#104 cut frame time to 21-31 ms and #100 fixed the
  translucent patches on the character. That is why #100 is in this set.
- Lichii #121 comment (Inc0rporate, RX 9070 XT, `EDEN_NX2_SPLIT=2`): the
  pause-only version hangs after the save pick; the 256-slot bound is the fix.
- Lichii #134 (RX 9070, docked 1x): "world black except where a light or particles
  touch it" matches the #127 demote-zeroing signature on AMD.
- Lichii #117 (RTX 50): handheld black, docked fixed it; gameplay flat at 29 fps.
  Config/CPU issue, not addressed by this branch.
- Lichii #123 (RTX 40): black right after the first cutscene in handheld, VHS-like
  filter in docked. Consistent with the occlusion/query path; #121 is the closest
  fix we have.

## Build

- CI: `pgo:none`, `publish:false`, platform `linux`, ref `test/upstream-fixes`.
- Run: https://github.com/RufflezAU/Eglantine/actions/runs/42068674108 — **success**
  at `ce4171953e`.
- Artifact: `eglantine-linux-x86_64-ce4171953efe4cf2972e15b022aaf76b9faf7819`
  (id 13438245302, non-PGO, 139 MB, not expired).
- Code diff: 4 files, +20 -7 — deliberately small so a failure is easy to bisect.

## Test order on the Deck

1. `EDEN_NX2_PROFILE=handheld` (known video): confirm videos + audio still work and
   the HUD still draws. A regression here means a patch is wrong, not the config.
2. Clear the title's shader cache before switching builds (documented trap: a
   `vulkan.*.bin` written by another binary stalls the next build silently).
3. `EDEN_NX2_PROFILE=docked` (1x, `EDEN_NX2_TENSOR` unset): the config that
   renders upstream on RADV. This is the primary black-world A/B.
4. Repeat docked with `EDEN_NX2_TENSOR=stub` only if the world appears and the
   stand-in path needs isolating.
5. If the world renders: measure FPS, then try `EDEN_NX2_INLINE_PAGE_WRITES=1`
   (see the #103/#104 row) as a separate build, then go PGO.

## Confidence

- #127: high for AMD black-world — same driver class (RADV) as the Deck, precise
  mechanism, one-file change.
- #121: medium-high for occlusion white flashes and possible blank frames; the
  bound is required on AMD and was added by the same author after an AMD hang.
- #100: medium — proven on RADV for the character/door artifact, not the main
  black-world cause.
- Combined odds that the Deck world renders: moderate. The strongest missing
  piece was already in the tree (#614), so this branch mostly removes AMD-specific
  zeroing/occlusion paths rather than adding new lowering coverage.
