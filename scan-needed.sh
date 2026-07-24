#!/usr/bin/env bash
# Scan a tree of built wasm packages for NEEDED-string divergence.
#
# The bug this catches: two side modules that record different NEEDED
# strings for what turns out to be the same library. Under emscripten
# there's no SONAME normalization and no realpath dedup, so the loader
# treats the two strings as different libraries and instantiates both.
# For dlopen'd consumers, each one's function-call imports then bind
# to whichever instance satisfied its own NEEDED chain, and the
# process ends up with silently-split state.
#
# Usage:
#   scan-needed.sh [--csv] [PATH]
#
# PATH defaults to ~/.cache/rattler/cache/pkgs -- the rattler pkg
# cache, which is where locally-downloaded conda packages live after
# extraction. Point at a pixi env prefix, a build output dir, or an
# unpacked channel dump to scan those instead.
#
# Modes:
#   (default)  human-readable report: only lists library base-names
#              where multiple distinct NEEDED strings were observed,
#              plus every (package, .so file) that emitted each.
#   --csv      raw dump: package,so_file,needed_string per line.
#              Useful for feeding into other tools.
#
# Native .so files fail wasm-objdump silently and get skipped -- so
# this is safe to point at trees that mix native and wasm packages.

set -euo pipefail

MODE=report
if [ "${1:-}" = "--csv" ]; then
    MODE=csv
    shift
fi

CACHE="${1:-$HOME/.cache/rattler/cache/pkgs}"

if [ ! -d "$CACHE" ]; then
    echo "error: scan root not found: $CACHE" >&2
    exit 2
fi

command -v wasm-objdump >/dev/null || {
    echo "error: wasm-objdump not found on PATH (nixpkgs#wabt or conda-forge wabt provides it)" >&2
    exit 2
}

# Collect every (package, so_file, needed_string) tuple.
collect() {
    find "$CACHE" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | while read -r pkgdir; do
        pkg="$(basename "$pkgdir")"
        find "$pkgdir" -name '*.so*' -type f 2>/dev/null | while read -r so; do
            # Skip non-wasm files silently.
            wasm-objdump -x "$so" 2>/dev/null \
                | awk -v p="$pkg" -v s="$so" '
                    /needed_dynlibs/{f=1; next}
                    f && /^ *- / { gsub(/^ *- /, ""); print p "," s "," $0 }
                    f && !/^ *- /{f=0}
                  '
        done
    done
}

case "$MODE" in
    csv)
        echo "package,so_file,needed_string"
        collect
        ;;
    report)
        collect | awk -F, '
            {
                base = $3
                # libhdf5.so.310.5.1 -> libhdf5.so
                sub(/\.so\.[0-9].*$/, ".so", base)
                # libfoo-1.14.so -> libfoo.so (best-effort for embedded versions)
                # (kept conservative to avoid over-matching)

                raw = $3
                pkg = $1
                so  = $2

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
                        # de-dup and list raw strings
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
                    print "no divergent NEEDED strings found -- every base library reference is consistent."
                }
            }'
        ;;
esac
