#!/bin/bash
# Copies the pre-fix RTL and host snapshot to build/verif/, where verif/scripts/prefix_check.sh,
# regress.py --prefix and run_formal.sh --prefix expect them. Run from the package root.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$ROOT/build/verif"
rm -rf "$ROOT/build/verif/rtl_prefix" "$ROOT/build/verif/host_prefix"
cp -r "$ROOT/prefix/rtl_prefix" "$ROOT/prefix/host_prefix" "$ROOT/build/verif/"
echo "pre-fix snapshot installed in build/verif/{rtl_prefix,host_prefix}"
