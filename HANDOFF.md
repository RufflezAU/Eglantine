# HANDOFF — Deck OLED test state (2026-11-06)

This is the working handoff for the next agent. Everything below is on the Deck
(`/home/deck`); the fork is `RufflezAU/Eglantine`.

**Naming rule:** do not commit the game title or title ID. Use “the green boy with
the ocarina”. The public repo text was deliberately scrubbed on 2026-11-06.

## Goal

Run the green-boy title (Switch 2) on a **Steam Deck OLED** through Eglantine/nx2
at playable FPS, ideally without losing the videos or the UI.

## What is proven

| Milestone | State |
|---|---|
| Title screen / 2D UI | works |
| Audio | works (do not force `PULSE_SERVER=none`) |
| Intro videos (AV1) | play with sound |
| New Game past the intro | survives with `EDEN_NX2_TENSOR=stub` |
| Interactive gameplay | **not reached** |
| 3D world | **black** |
| Host process | can survive; can also SIGSEGV at world load |

Upstream evidence that the world **does** render on some configs:

- Eglantine PR #614 comment (RADV RX 7800 XT, **docked, 1x, no `EDEN_NX2_TENSOR`**):
  3D world renders in gameplay, 0 graphics programs rejected, 0 draws skipped;
  only the 11 HMMA compute programs are rejected, so the upscale stand-in runs.
- Lichii #117: gameplay at ~29 fps; **docked** fixed the black handheld screen.
- Lichii #134 / Eglantine #589: world renders but only Navi-lit areas, or goes
  black later — later-stage bugs, not “never loads”.

## Repository / CI

- Fork: `RufflezAU/Eglantine` (parent `Djihads80/Eglantine`)
- Remotes in `/tmp/opencode/egl614`: `origin` = upstream mirror, `fork` = token URL
- Token: `/tmp/gh_token` — **never print or commit it**
- Branches:
  - `test/deck-oled` — main test branch; head `5f90244581` (guard + query flush +
    `ShuffleIndex` SSBO fix + graphics SSBO sizing + neutral docs)
  - `test/deck-fog` — `3ba4df78` + neutral docs (guard + query flush)
  - `test/oot-full` — old branch, base build
- Releases:
  - `deck-test-13034afe` — base (#614 + 201), known crash
  - `deck-guard-83c1a00` — guard build, tested: videos/audio, world black
  - `deck-fog-3ba4df78` — guard + query/fog fix
- CI dispatch (Linux, fast test):
  ```bash
  TOKEN=$(cat /tmp/gh_token)
  curl -s -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Accept: application/vnd.github+json' \
    https://api.github.com/repos/RufflezAU/Eglantine/actions/workflows/ci.yml/dispatches \
    -d '{"ref":"<branch>","inputs":{"kind":"branch","platforms":"linux","pgo":"none","publish":false}}'
  ```
  `pgo` is `none|both`; a cold PGO build is ~46 min, non-PGO ~34 min.
  Artifacts: `GET /repos/RufflezAU/Eglantine/actions/runs/<id>/artifacts`.

## Installed builds

- `current` → `builds/eglantine-deck-ssbo-5f90244/squashfs-root` (non-PGO, run 6)
- Known-video build: `builds/eglantine-deck-oled-83c1a00` (PGO, run 4)
- Fog build: `builds/eglantine-deck-fog-3ba4df78`
- Launcher: `/home/deck/Applications/lichii/lichii-oot.sh`
- Steam shortcut runs: `lichii-oot.sh --auto --fidelity --fresh --capture --handheld`

## Launcher profiles (A/B)

`lichii-oot.sh` now selects a profile from `EDEN_NX2_PROFILE` (default
`handheld`):

- `handheld` — `lichii-oot-fidelity.ini` (0.75x/FSR/BC3), `EDEN_NX2_TENSOR=stub`.
  Known result: videos + audio, world black.
- `docked` — `lichii-deck.ini` (1x), `EDEN_NX2_TENSOR` unset.
  Known result (last test): videos audio-only, world black. This is the config
  the upstream RADV report says should render the world.

Set `EDEN_NX2_PROFILE=docked` in the Steam launch options or the environment to
switch. Do not hardcode one profile again; the next agent needs both.

## Log signatures (current evidence)

Log: `/home/deck/.local/share/eden/log/eden_log.txt`

- Handheld/0.75/stub, guard build (`83c1a00`): 18 compute programs rejected at
  ~46 s with `native matrix multiply (set EDEN_NX2_TENSOR to emulate)`; the
  intro video decodes 1200 frames; at the world load the game loops on
  `Read32 of unmapped GPU address 0x200120ad21143a9a`, then presents stop.
- SSBO build (`5f90244`) with stub: the `0x200120ad` loop is **gone**, but at
  ~252 s a puller burst logs `Special puller engine method 25..3F not
  implemented`, then:
  ```
  assert Unimplemented format=537003506   (0x200205f2)
  Unhandled SIGSEGV at 0x000055d5cc488793
  ```
  This is a **host** crash, not a guest panic.
- Earlier crash that the guards fixed: `CreateImage` with
  `2147484640x2432696322x1`, format `0x8001054c`; `assert Unimplemented engine
  -5FFBF1E0` (0xA0040E20); pushbuffer entry `2665` at `0x212a7351d8` begins with
  `3f800000`, parsed as `method 0, count 8064`.
- Video-only regression in the docked/1x/no-tensor run: audio plays, no video.
  The same build played video in handheld/0.75/stub. This is config-dependent,
  not a build regression.

## Working hypotheses

1. **`stub` prevents the upscale stand-in.** The stand-in only runs when the
   HMMA network programs are **rejected**. `stub` completes them as `D=C`, so
   the final image is never drawn. The working upstream config leaves the env
   unset. But no-tensor + docked made video audio-only, so isolate one variable
   at a time.
2. **Stand-in image selection is wrong on Van Gogh.** Check the 11 HMMA
   programs, `UpscaleInsteadOfNativeProgram`, `NativeImageHandles`, the chosen
   input/output TIC entries (format/size/address), and E5B9G9R9.
3. **Puller/command-stream misparse.** The `3f800000` false header and the
   `0xA0040E20` bind argument look like constant data parsed as commands. A
   safe parser guard may also stop the host SIGSEGV.
4. **Missing upstream fixes.** Lichii #121 (occlusion counter pause) and #127
   (nested returns / AMD black scene) are unmerged candidates; #589/#134 have
   more data.

## Parallel investigation branches (created for the morning)

Each agent works in its own worktree and pushes its own branch:

- `test/upscale-fix` — `/tmp/opencode/agent-upscale`
- `test/puller-fix` — `/tmp/opencode/agent-puller`
- `test/upstream-fixes` — `/tmp/opencode/agent-upstream`
- `test/config-matrix` — `/tmp/opencode/agent-config`

They build with `pgo:none, publish:false` so the morning has artifacts to test.
Install an artifact by extracting the AppImage with `--appimage-extract` into
`/home/deck/Applications/lichii/builds/<name>/` and pointing `current` at its
`squashfs-root`. Keep the old builds intact.

## Morning test matrix

1. `EDEN_NX2_PROFILE=handheld` (known video) — confirms video/audio still work.
2. `EDEN_NX2_PROFILE=docked` (1x, no tensor) — the upstream “world renders”
   config. If video is audio-only, isolate docked vs 1x vs tensor.
3. Each agent build with the profile that gave the best video result.
4. If the world appears, measure FPS and then build PGO.

## Constraints

- No game title or title ID in commits, branches, releases, README or docs.
- Do not modify `/home/deck/Applications/lichii/lichii-oot.sh` from an agent;
  copy it or use env profiles.
- Do not print `/tmp/gh_token`.
- Keep each candidate as its own commit and branch so it can be bisected.
