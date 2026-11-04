#!/bin/bash
# sby 'abc pdr' appends "-l" to pdr, which /usr/bin/abc (ABC 1.01) rejects. Strip it, then exec the real abc.
args=()
for a in "$@"; do args+=("${a//pdr -v -l/pdr -v}"); done
exec /usr/bin/abc "${args[@]}"
