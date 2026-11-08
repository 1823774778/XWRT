#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Adapted from VIKINGYFY/OpenWRT-CI (Copyright (C) 2026 VIKINGYFY).
set -euo pipefail

REPORT_DIR="${GITHUB_WORKSPACE:-$PWD}/build-reports"
mkdir -p "$REPORT_DIR"
git rev-parse HEAD > "$REPORT_DIR/source-commit.txt"
if [ -f .config ]; then
  cp .config "$REPORT_DIR/config.txt"
fi
./scripts/feeds list -fs > "$REPORT_DIR/feeds.buildinfo"

for TIME_LOG in "$REPORT_DIR"/*.tsv; do
  [ -f "$TIME_LOG" ] || continue
  if [ -f ./scripts/build-time-report.pl ]; then
    ./scripts/build-time-report.pl -n 30 "$TIME_LOG" > "${TIME_LOG%.tsv}-report.txt" ||
      printf 'Build time report unavailable for %s; raw events retained\n' "$TIME_LOG"
  fi
done

if [ -x ./staging_dir/host/bin/ccache ]; then
  CCACHE_DIR="$PWD/.ccache" ./staging_dir/host/bin/ccache -s > "$REPORT_DIR/ccache.txt"
fi
{
  for RUST_BIN in ./staging_dir/host/bin/rustc ./staging_dir/target-*/host/bin/rustc; do
    [ -x "$RUST_BIN" ] || continue
    readlink -f "$RUST_BIN"
    "$RUST_BIN" -vV
  done
} > "$REPORT_DIR/rust-after-build.txt"
{
  for GO_BIN in ./staging_dir/hostpkg/bin/go1.*; do
    [ -x "$GO_BIN" ] || continue
    readlink -f "$GO_BIN"
    "$GO_BIN" version
  done
} > "$REPORT_DIR/go-after-build.txt"
if [ -x ./staging_dir/hostpkg/bin/python3 ]; then
  ./staging_dir/hostpkg/bin/python3 -c \
    'import sys, sysconfig; print(sys.executable); print(sys.version); print(sysconfig.get_config_var("CONFIG_ARGS"))' \
    > "$REPORT_DIR/python-after-build.txt"
fi
df -h . > "$REPORT_DIR/disk-usage.txt"
