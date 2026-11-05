#!/usr/bin/env bash
# Merge a config-matrix overlay into a copy of a full base ini and launch it.
# Never edits /home/deck/Applications/lichii or the launcher.
#
#   ./run-profile.sh <profile.ini|name> [--windowed]
#
#   DRY_RUN=1   print the command and effective keys, do not launch
#   VERIFY=1    also round-trip the merged file through eden-cli with no ROM,
#               which shows the values the emulator actually kept
#   BASE_INI=...  base full config (default: installed docked profile)
set -eu

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
profile="${1:-}"
if [ -z "$profile" ]; then
    echo "usage: $0 <profile-name|path.ini> [--windowed]" >&2
    exit 2
fi
shift || true
windowed=0
if [ "${1:-}" = "--windowed" ]; then
    windowed=1
    shift
fi

case "$profile" in
    */*) ini="$profile" ;;
    *) ini="$here/$profile"; [ -f "$ini" ] || ini="$here/$profile.ini" ;;
esac
[ -f "$ini" ] || { echo "no such profile: $profile" >&2; exit 2; }

lichii="${LICHII_DIR:-/home/deck/Applications/lichii}"
base="${BASE_INI:-$lichii/lichii-oot-docked.ini}"
if [ ! -f "$base" ]; then
    echo "missing base ini: $base (set BASE_INI)" >&2
    exit 1
fi

cli="$lichii/current/usr/bin/eden-cli"
[ -x "$cli" ] || cli="$lichii/squashfs-root/usr/bin/eden-cli"
[ -x "$cli" ] || { echo "missing eden-cli under $lichii" >&2; exit 1; }

outdir="${MATRIX_TMP:-/tmp/opencode/config-matrix}"
mkdir -p "$outdir"
name="$(basename "$ini" .ini)"
out="$outdir/$name.ini"

python3 - "$base" "$ini" "$out" <<'PY'
import collections
import sys

base_path, overlay_path, out_path = sys.argv[1:4]

def read_sections(path):
    sections = collections.OrderedDict()
    section = None
    with open(path, encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            stripped = line.strip()
            if stripped.startswith("[") and stripped.endswith("]"):
                section = stripped
                sections.setdefault(section, [])
            elif section is not None and "=" in stripped and not stripped.startswith(("#", ";")):
                key = stripped.split("=", 1)[0].strip()
                sections[section].append((key, line))
    return sections

overlay = read_sections(overlay_path)
overrides = collections.OrderedDict()
for section, entries in overlay.items():
    for key, line in entries:
        overrides[(section, key)] = line

out_lines = []
used = set()
seen_sections = set()
section = None

def flush(section):
    if section is None:
        return
    for (sec, key), line in overrides.items():
        if sec == section and (sec, key) not in used:
            out_lines.append(line)
            used.add((sec, key))

with open(base_path, encoding="utf-8", errors="replace") as handle:
    for raw in handle:
        line = raw.rstrip("\n")
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            flush(section)
            section = stripped
            seen_sections.add(section)
            out_lines.append(line)
            continue
        if section is not None and "=" in stripped and not stripped.startswith(("#", ";")):
            key = stripped.split("=", 1)[0].strip()
            if (section, key) in overrides:
                out_lines.append(overrides[(section, key)])
                used.add((section, key))
                continue
        out_lines.append(line)
flush(section)

for (sec, key), line in overrides.items():
    if (sec, key) in used:
        continue
    if sec not in seen_sections:
        out_lines.extend(["", sec])
        seen_sections.add(sec)
    out_lines.append(line)

with open(out_path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(out_lines) + "\n")
PY

tensor="$(sed -n 's/^# tensor: //p' "$ini" | head -n1)"
reject="$(sed -n 's/^# reject-hash: //p' "$ini" | head -n1)"

# The launcher's environment, reproduced without touching the launcher.
export HOME=/home/deck
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export EDEN_NX2_AUTO_STUB="${EDEN_NX2_AUTO_STUB:-1}"
export MESA_SHADER_CACHE_MAX_SIZE="${MESA_SHADER_CACHE_MAX_SIZE:-8G}"
export EDEN_NX2_VRAM_LIMIT_MIB="${EDEN_NX2_VRAM_LIMIT_MIB:-6144}"
export EDEN_NX2_ASTC_ARRAY_MIB="${EDEN_NX2_ASTC_ARRAY_MIB:-256}"
export EDEN_NX2_SPLIT="${EDEN_NX2_SPLIT:-2}"
export EDEN_NX2_FENCE_BATCH="${EDEN_NX2_FENCE_BATCH:-1}"
export EDEN_NX2_INLINE_PAGE_WRITES="${EDEN_NX2_INLINE_PAGE_WRITES:-0}"
unset PULSE_SERVER

if [ "$tensor" = "stub" ]; then
    export EDEN_NX2_TENSOR=stub
else
    unset EDEN_NX2_TENSOR
fi
if [ "$reject" = "unset" ]; then
    unset EDEN_NX2_REJECT_HASH
else
    export EDEN_NX2_REJECT_HASH="${EDEN_NX2_REJECT_HASH:-c72b6ea746c00433}"
fi

echo "profile: $name"
echo "base:    $base"
echo "merged:  $out"
echo "tensor:  ${EDEN_NX2_TENSOR:-<unset>}"
echo "reject:  ${EDEN_NX2_REJECT_HASH:-<unset>}"
echo "effective:"
grep -E '^(resolution_setup|scaling_filter|astc_recompression|accelerate_astc|use_asynchronous_shaders|gpu_accuracy|use_vsync|use_docked_mode)(\\default)?=' "$out" | sed 's/^/  /'

if [ "${VERIFY:-0}" = 1 ]; then
    cp "$out" "$out.readback"
    "$cli" -c "$out.readback" >/dev/null 2>&1 || true
    echo "after the emulator read it:"
    grep -E '^(resolution_setup|scaling_filter|astc_recompression|accelerate_astc|use_asynchronous_shaders|gpu_accuracy|use_vsync|use_docked_mode)(\\default)?=' "$out.readback" | sed 's/^/  /'
    rm -f "$out.readback"
fi

game="${EGLANTINE_GAME:-}"
if [ -z "$game" ]; then
    roms="${EGLANTINE_ROMS:-$HOME/Emulation/roms/switch2}"
    if [ -d "$roms" ]; then
        game="$(find "$roms" -maxdepth 2 -type f \( -name '*.nup' -o -name '*.nsp' \) 2>/dev/null | head -n1 || true)"
        if [ -z "$game" ]; then
            for candidate in "$roms"/*/; do
                if [ -f "${candidate}exefs/main" ]; then
                    game="${candidate%/}"
                    break
                fi
            done
        fi
    fi
fi
if [ -z "$game" ] || [ ! -e "$game" ]; then
    echo "no game found; set EGLANTINE_GAME or EGLANTINE_ROMS" >&2
    exit 1
fi

fullscreen="-f"
[ "$windowed" = 1 ] && fullscreen=""

if [ "${DRY_RUN:-0}" = 1 ]; then
    echo "DRY_RUN: $cli $fullscreen -c $out -g <game>"
    exit 0
fi

logdir="$outdir/logs"
mkdir -p "$logdir"
logsrc="$HOME/.local/share/eden/log/eden_log.txt"
cp -f "$logsrc" "$logdir/$name.previous.txt" 2>/dev/null || true

set +e
"$cli" $fullscreen -c "$out" -g "$game" "$@"
status=$?
set -e
cp -f "$logsrc" "$logdir/$name.txt" 2>/dev/null || true
echo "log: $logdir/$name.txt (exit $status)"
exit "$status"
