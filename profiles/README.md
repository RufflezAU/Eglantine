# Config-matrix profiles

These are **overlays**, not full configs. `run-profile.sh` merges an overlay into
a copy of a full base ini and launches `eden-cli`; the installed launcher and
its files are never modified.

Why overlays: every key must carry `key\default=false`. With
`key\default=true` the emulator resets the setting to its compiled default and
**ignores the value line**. That is why the installed `docked` profiles are
still Handheld and still use GPU ASTC. See `../WORKLOG.md` for the verified
round-trip.

## Use

```bash
cd /home/deck/opencode-agents/config

# inspect without launching
DRY_RUN=1 ./profiles/run-profile.sh p06-docked-1x-sync-high

# verify the emulator's post-read values (no game starts)
VERIFY=1 DRY_RUN=1 ./profiles/run-profile.sh p06-docked-1x-sync-high

# run (foreground; copies the log to /tmp/opencode/config-matrix/logs/)
./profiles/run-profile.sh p06-docked-1x-sync-high
```

Environment knobs: `BASE_INI` (default
`/home/deck/Applications/lichii/lichii-oot-docked.ini`), `LICHII_DIR`,
`EGLANTINE_ROMS`, `EGLANTINE_GAME`, `MATRIX_TMP`. `--windowed` after the
profile name drops `-f`.

The base ini supplies audio/CPU/controls so the matrix does not change them.
The merge writes to `$MATRIX_TMP` (default `/tmp/opencode/config-matrix`), so
the emulator's exit-time rewrite never touches a tracked file.

## Rows

| File | Docked | res | filter | gpu | async | accel ASTC | tensor | Purpose |
|---|---|---|---|---|---|---|---|---|
| `p01-handheld-075-stub.ini` | no | 0.75x | FSR | High | on | Gpu | stub | known video / black world control |
| `p02-handheld-1x-sync-high.ini` | no | 1x | ScaleForce | High | off | Gpu | unset | old working-video log, closest reproduction |
| `p03-handheld-1x-async-high.ini` | no | 1x | ScaleForce | High | on | Gpu | unset | async isolation (effective installed `docked`) |
| `p04-handheld-1x-async-low.ini` | no | 1x | ScaleForce | Low | on | Gpu | unset | reproduces the 41.9 s / 1-frame log |
| `p05-docked-1x-async-high.ini` | **yes** | 1x | ScaleForce | High | on | Gpu | unset | first true-docked async run |
| `p06-docked-1x-sync-high.ini` | **yes** | 1x | ScaleForce | High | off | Gpu | unset | upstream-analog config (start here) |
| `p07-docked-1x-async-low.ini` | **yes** | 1x | ScaleForce | Low | on | Gpu | unset | docked + split |
| `p08-docked-1x-sync-high-stub.ini` | **yes** | 1x | ScaleForce | High | off | Gpu | stub | docked + stub (video vs world) |
| `p09-handheld-1x-async-high-noreject.ini` | no | 1x | ScaleForce | High | on | Gpu | unset | without `EDEN_NX2_REJECT_HASH` |
| `p10-handheld-1x-async-high-astc-cpu.ini` | no | 1x | ScaleForce | High | on | **Cpu** | unset | forces ASTC CPU (installed value is ignored) |

All rows force `use_vsync=2` (Fifo), `astc_recompression=2` (Bc3),
`EDEN_NX2_SPLIT=2`, `EDEN_NX2_FENCE_BATCH=1`,
`EDEN_NX2_INLINE_PAGE_WRITES=0`, and the launcher's other common env; tensor and
reject-hash are per row (see the `# tensor:` / `# reject-hash:` header lines).

## After a run

The log is `/home/deck/.local/share/eden/log/eden_log.txt` (last session only).
`run-profile.sh` copies it to
`/tmp/opencode/config-matrix/logs/<profile>.txt`. Quick checks:

```bash
L=/home/deck/.local/share/eden/log/eden_log.txt
grep -c "GPU thread split" "$L"                 # 0 High, 1 Low
grep -c "Draw skipped (no pipeline)" "$L"       # 0 with sync
grep -c "Native compute shader rejected" "$L"   # 10 no-tensor, 0 stub
grep -E "DecodeLoop.*frame (1|600|1200) " "$L"  # decode alive?
grep -c "end of stream" "$L"
```

Record `video`, `world`, `audio`, `crash`, `split`, `Draw skipped` in the
matrix in `../WORKLOG.md`.
