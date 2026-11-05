# Deck OLED test build — the green boy with the ocarina

This fork, branch and its releases exist for one target:

> **the green boy with the ocarina**, running on a Steam Deck OLED through the
> Eglantine / nx2 emulator.

It is **not** a build for Switch or Switch 2 hardware. The artifact is an
**x86_64 Linux AppImage** for SteamOS, using **RADV on Van Gogh**.

| | |
|---|---|
| Title | the green boy with the ocarina |
| Title ID | withheld |
| Host | Steam Deck OLED (Van Gogh APU, RADV) |
| Emulator | Eglantine (nx2) |
| Base | Eglantine `e736dfde` + PR #614 stand-in + vi2 method 201 |
| Branch | `test/deck-oled` |
| Asset | `eglantine-linux-x86_64-pgo.AppImage` |

## Current status

- Boots on the Deck; title screen, logo, menu and subtitles render.
- The 2D UI layer works.
- The 3D world and the intro video are still black.
- The guest emits a malformed new-engine (puller) command with an invalid surface
  format and an invalid image extent, and starting a new game previously aborted
  in `CreateImage`.

## Guards in this branch

1. `src/video_core/vulkan_common/vulkan_memory_allocator.cpp` — impossible image
   extents are clamped to a 1×1 placeholder instead of aborting the process.
2. `src/video_core/engines/puller.cpp` — unimplemented new-engine methods log and
   continue instead of terminating the process.

These are **crash guards, not a rendering fix**. They keep the game alive; the 3D
assets are still missing until the new-engine command / format is decoded correctly.

## Test configuration

- Handheld, 0.75× render scale, FSR, BC3
- GPU accuracy Normal, async shaders, CPU accuracy Unsafe
- `accelerate_astc=0`

## Install

Download the AppImage from the release, `chmod +x` it, and launch it on the Deck.
Do not install this build on a Switch.
