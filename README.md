# wasm-needed-scan

Static scanner for the "same library, two NEEDED strings" bug in wasm
package trees.

## The bug

Emscripten's dynamic linker keys its "already loaded?" table on the
exact NEEDED string a side module declares. It doesn't do the SONAME
normalization or realpath dedup that native `ld.so` uses. So if two
consumer `.so`s in the same environment declare NEEDED strings like
`libhdf5.so.310.5.1` and `libhdf5.so` for what turns out to be the
same library, both get instantiated. dlopen-time function-import
binding then routes each consumer's calls to its own NEEDED-chain
instance, and downstream state (file-scope statics, cache tags,
per-instance bookkeeping) silently splits.

See the reproducer at
<https://github.com/MMesch/wasm-soname-dedup-test> for a minimal
demonstration and full mechanism write-up.

## What this tool does

Walks a directory tree of built packages, extracts NEEDED strings
from every `.so` (via `wasm-objdump -x`), normalizes them to a base
library name (e.g. `libhdf5.so.310.5.1` → `libhdf5.so`), and reports
any base library where more than one distinct NEEDED string was
observed. For each divergence it lists every package and file that
emitted each NEEDED variant, so you know exactly which recipes need
fixing.

Native `.so` files fail `wasm-objdump` silently and get skipped, so
it's safe to point at a mixed tree.

## Usage

Two scripts, pick the one that matches your source:

### `scan-needed.sh` — scan a local tree

```
scan-needed.sh [--csv] [PATH]
```

For inspecting an on-disk tree of already-extracted packages.

- `PATH` defaults to `~/.cache/rattler/cache/pkgs` (rattler's local
  package cache — populated by pixi as you install/build things).
- Point at a pixi env prefix, a rattler-build output tree, or a
  scratch dir where you unpacked some `.conda`s to scan those instead.
- `--csv` emits raw `package,so_file,needed_string` rows for further
  processing.

### `scan-remote.sh` — download-scan-delete stream

```
scan-remote.sh [--all] [PACKAGE...]
```

Fetches packages from a channel one at a time, extracts to a temp
dir, records NEEDED strings, and deletes the archive + extracted
tree before moving to the next. Disk usage stays flat — the only
lasting file is a small CSV log (also deleted after the report,
unless `KEEP_CSV=1`).

- `--all` — scan every distinct package name in the channel (latest
  build each). Handy for a full ecosystem audit; runs in minutes and
  catches every NEEDED divergence, not just the one you thought
  to look for.
- `PACKAGE...` — scan only these named packages.
- Default channel: `https://prefix.dev/emscripten-forge-4x`. Override
  with `CHANNEL=... SUBDIR=... scan-remote.sh ...`.
- Emits the divergence report at the end automatically. Set
  `KEEP_CSV=1` to keep the intermediate CSV.

Note on `--all`: since the scan crosses packages that would never
coexist in one env (e.g., different Python versions, mutex-managed
BLAS backends), a couple of noise entries can appear alongside the
real bugs. Easy to eyeball past.

## Requirements

- `wasm-objdump` (from `wabt`, in nixpkgs and conda-forge).
- Any shell with `awk` and `find`.

Quick nix invocation:

```bash
nix shell nixpkgs#wabt -c bash scan-needed.sh
```

## Interpreting the output

A DIVERGENT NEEDED report block looks like:

```
DIVERGENT NEEDED strings for base library: libhdf5.so
  NEEDED = libhdf5.so.310.5.1
  referred by:
    hdf5-1.14.6-ha7c90dc_4    /home/…/hdf5-…/lib/libhdf5_hl.so
    netcdf-4.10.1-…           /home/…/netcdf-…/lib/libnetcdf.so

  NEEDED = libhdf5.so
  referred by:
    h5py-3.13.0-…             /home/…/h5py/_hl.cpython-…so
    h5py-3.13.0-…             /home/…/h5py/h5f.cpython-…so
```

Each block is one library whose consumers disagree on which NEEDED
name to use. Fix at the recipe level: usually the versioned side is
the one to change (drop `VERSION`/`SOVERSION` under emscripten so
CMake stops stamping the versioned filename into DT_NEEDED).

If no divergences exist the tool prints one line saying so.

## Caveats

- The base-name normalization strips one trailing version-suffix
  chain (`.so.N…` → `.so`). It doesn't handle embedded versions in
  the basename itself (`libfoo-2.so`).
- Two different libraries with genuinely different export sets
  wouldn't collide even if they happened to share a base name.
  Distinguishing "same library, two NEEDED strings" from "two
  libraries under confusingly-similar names" needs an extra pass
  comparing target file hashes; this tool doesn't attempt that.
- Legitimate interposition patterns (BLAS backends etc.) are
  typically resolved by conda mutex-features at env-solve time, so
  this scanner should not see them coexisting in a real env. If it
  does, that's an env bug, not a false positive.
