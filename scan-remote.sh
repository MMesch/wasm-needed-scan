#!/usr/bin/env bash
# Stream NEEDED strings from a conda-style channel without leaving
# archives or extracted trees behind. For each package: download,
# extract to a temp dir, wasm-objdump every .so, emit CSV rows, delete.
# After all packages, run the divergence aggregator on the accumulated
# CSV (which is a single small text file kept in /tmp).
#
# Usage:
#   scan-remote.sh PACKAGE [PACKAGE...]
#
# Env-vars:
#   CHANNEL   — base URL. Default: https://prefix.dev/emscripten-forge-4x
#   SUBDIR    — arch subdir. Default: emscripten-wasm32
#   CSV_OUT   — where to write CSV log. Default: /tmp/scan-remote.csv
#   KEEP_CSV  — if set (any value), keep the CSV. Otherwise delete after report.
#
# Needs: curl, jq, unzip, tar, zstd, wasm-objdump.

set -euo pipefail

ALL=0
if [ "${1:-}" = "--all" ]; then
    ALL=1
    shift
fi

if [ $ALL -eq 0 ] && [ $# -lt 1 ]; then
    echo "usage: $0 [--all] [PACKAGE...]" >&2
    echo "  --all           scan every distinct package name in the channel (latest build each)" >&2
    echo "  PACKAGE...      scan only these named packages" >&2
    exit 2
fi

CHANNEL="${CHANNEL:-https://prefix.dev/emscripten-forge-4x}"
SUBDIR="${SUBDIR:-emscripten-wasm32}"
CSV_OUT="${CSV_OUT:-/tmp/scan-remote.csv}"

for cmd in curl jq unzip tar zstd wasm-objdump; do
    command -v "$cmd" >/dev/null || { echo "error: $cmd not on PATH" >&2; exit 2; }
done

repodata=$(mktemp)
trap 'rm -f "$repodata"' EXIT

echo "==> Fetching $CHANNEL/$SUBDIR/repodata.json" >&2
curl -sL "$CHANNEL/$SUBDIR/repodata.json" > "$repodata"

if [ $ALL -eq 1 ]; then
    set -- $(jq -r '
        ((.["packages.conda"] // {}) | to_entries | map(.value.name)) +
        ((.packages         // {}) | to_entries | map(.value.name))
        | unique | .[]
    ' "$repodata")
    echo "==> --all: scanning ${#} distinct package names" >&2
fi

echo "package,so_file,needed_string" > "$CSV_OUT"

for want in "$@"; do
    pick=$(jq -r --arg want "$want" '
        ((.["packages.conda"] // {}) | to_entries | map({name: .value.name, ver: .value.version, build_number: (.value.build_number // 0), fname: .key, kind: "conda"})) +
        ((.packages         // {}) | to_entries | map({name: .value.name, ver: .value.version, build_number: (.value.build_number // 0), fname: .key, kind: "tarbz2"}))
        | map(select(.name == $want))
        | sort_by([.ver, .build_number, .kind == "conda"])
        | last
        | if . == null then "" else .fname + "\t" + .kind end
    ' "$repodata")

    if [ -z "$pick" ]; then
        echo "warn: '$want' not found in $CHANNEL/$SUBDIR" >&2
        continue
    fi

    fname="${pick%%$'\t'*}"
    kind="${pick##*$'\t'}"

    echo "==> $want -> $fname ($kind)" >&2

    workdir=$(mktemp -d)

    # Everything below is best-effort: if download or extract fails for
    # one package, log a warning and skip to the next. Otherwise a single
    # bad archive would kill a channel-wide sweep.
    (
        set +e
        dest="$workdir/$fname"
        if ! curl -sSL --fail -o "$dest" "$CHANNEL/$SUBDIR/$fname"; then
            echo "     skip: curl failed for $fname" >&2
            exit 0
        fi

        extract_root="$workdir/extracted"
        mkdir -p "$extract_root"
        case "$kind" in
            conda)
                if ! unzip -q "$dest" -d "$workdir/unzipped" 2>/dev/null; then
                    echo "     skip: unzip failed for $fname" >&2
                    exit 0
                fi
                for t in "$workdir/unzipped"/pkg-*.tar.zst; do
                    [ -f "$t" ] || continue
                    if ! zstd -dq < "$t" | tar -x -C "$extract_root" 2>/dev/null; then
                        echo "     skip: zstd/tar failed for $fname" >&2
                        exit 0
                    fi
                done
                ;;
            tarbz2)
                if ! tar -xjf "$dest" -C "$extract_root" 2>/dev/null; then
                    echo "     skip: tar failed for $fname" >&2
                    exit 0
                fi
                ;;
        esac

        find "$extract_root" -name '*.so*' -type f 2>/dev/null | while read -r so; do
            rel="${so#$extract_root/}"
            wasm-objdump -x "$so" 2>/dev/null \
                | awk -v p="$want" -v s="$rel" '
                    /needed_dynlibs/{f=1; next}
                    f && /^ *- / { gsub(/^ *- /, ""); print p "," s "," $0 }
                    f && !/^ *- /{f=0}
                  '
        done >> "$CSV_OUT" || true

        exit 0
    ) || true

    rm -rf "$workdir"
done

echo
echo "==> CSV log: $CSV_OUT ($(wc -l < "$CSV_OUT") rows)"
echo
echo "==> Divergence report:"

tail -n +2 "$CSV_OUT" | awk -F, '
    {
        base = $3
        sub(/\.so\.[0-9].*$/, ".so", base)
        raw = $3; pkg = $1; so  = $2

        if (!(base "|" raw in seen_raw)) {
            seen_raw[base "|" raw] = 1
            raw_count[base]++
        }
        referrers[base "|" raw] = referrers[base "|" raw] pkg "\t" so "\n"
        all_raw[base] = all_raw[base] raw "\n"
        bases[base] = 1
    }
    END {
        any = 0
        for (base in bases) {
            if (raw_count[base] > 1) {
                any = 1
                print "----------------------------------------------------------------"
                print "DIVERGENT NEEDED strings for base library: " base
                print "----------------------------------------------------------------"
                n = split(all_raw[base], arr, "\n")
                delete seen
                for (i = 1; i <= n; i++) {
                    r = arr[i]
                    if (r == "" || (r in seen)) continue
                    seen[r] = 1
                    print "  NEEDED = " r
                    print "  referred by:"
                    m = split(referrers[base "|" r], refs, "\n")
                    delete seen_ref
                    for (j = 1; j <= m; j++) {
                        if (refs[j] == "" || (refs[j] in seen_ref)) continue
                        seen_ref[refs[j]] = 1
                        print "    " refs[j]
                    }
                    print ""
                }
            }
        }
        if (!any) {
            print "no divergent NEEDED strings across scanned packages."
        }
    }'

if [ -z "${KEEP_CSV:-}" ]; then
    rm -f "$CSV_OUT"
fi
