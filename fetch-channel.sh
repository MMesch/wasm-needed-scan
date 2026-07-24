#!/usr/bin/env bash
# Download and extract the latest build of specific packages from a
# conda-style channel, ready for scan-needed.sh.
#
# Usage:
#   fetch-channel.sh PACKAGE [PACKAGE...]
#
# Env-vars (override defaults):
#   CHANNEL   — base URL. Default: https://prefix.dev/emscripten-forge-4x
#   SUBDIR    — arch subdir. Default: emscripten-wasm32
#   SCRATCH   — where to write. Default: /tmp/wasm-channel-scan
#
# Fetches only the packages you name — not the whole channel. Picks
# the highest (version, build_number) available. Extracts under
# $SCRATCH/extracted/<name>/ so you can point scan-needed.sh at
# $SCRATCH/extracted afterward.
#
# Needs: curl, jq, unzip, tar, zstd.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 PACKAGE [PACKAGE...]" >&2
    exit 2
fi

CHANNEL="${CHANNEL:-https://prefix.dev/emscripten-forge-4x}"
SUBDIR="${SUBDIR:-emscripten-wasm32}"
SCRATCH="${SCRATCH:-/tmp/wasm-channel-scan}"

for cmd in curl jq unzip tar zstd; do
    command -v "$cmd" >/dev/null || { echo "error: $cmd not on PATH" >&2; exit 2; }
done

mkdir -p "$SCRATCH"/{downloads,extracted}

if [ ! -f "$SCRATCH/repodata.json" ]; then
    echo "==> Fetching $CHANNEL/$SUBDIR/repodata.json"
    curl -sL "$CHANNEL/$SUBDIR/repodata.json" > "$SCRATCH/repodata.json"
fi

for want in "$@"; do
    # Pick highest (version, build_number) matching this name across both
    # .conda and .tar.bz2 records; prefer .conda when both exist for the
    # same build.
    pick=$(jq -r --arg want "$want" '
        ((.["packages.conda"] // {}) | to_entries | map({name: .value.name, ver: .value.version, build_number: (.value.build_number // 0), fname: .key, kind: "conda"})) +
        ((.packages         // {}) | to_entries | map({name: .value.name, ver: .value.version, build_number: (.value.build_number // 0), fname: .key, kind: "tarbz2"}))
        | map(select(.name == $want))
        | sort_by([.ver, .build_number, .kind == "conda"])
        | last
        | if . == null then "" else .fname + "\t" + .kind end
    ' "$SCRATCH/repodata.json")

    if [ -z "$pick" ]; then
        echo "warn: no package matching '$want' found in $CHANNEL/$SUBDIR" >&2
        continue
    fi

    fname="${pick%%$'\t'*}"
    kind="${pick##*$'\t'}"

    echo "==> $want -> $fname ($kind)"
    dest="$SCRATCH/downloads/$fname"
    [ -f "$dest" ] || curl -sSL -o "$dest" "$CHANNEL/$SUBDIR/$fname"

    extract_root="$SCRATCH/extracted/$want"
    rm -rf "$extract_root"
    mkdir -p "$extract_root"

    case "$kind" in
        conda)
            tmpdir=$(mktemp -d)
            unzip -q "$dest" -d "$tmpdir"
            for t in "$tmpdir"/pkg-*.tar.zst; do
                [ -f "$t" ] || continue
                zstd -d < "$t" | tar -x -C "$extract_root"
            done
            rm -rf "$tmpdir"
            ;;
        tarbz2)
            tar -xjf "$dest" -C "$extract_root"
            ;;
    esac
done

echo
echo "==> Done. Scan with:"
echo "     $(dirname "$0")/scan-needed.sh $SCRATCH/extracted"
