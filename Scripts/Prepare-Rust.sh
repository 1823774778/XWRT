#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Adapted from VIKINGYFY/OpenWRT-CI (Copyright (C) 2026 VIKINGYFY).
set -euo pipefail

if grep -q '^CONFIG_USE_RUST_TOOLCHAIN=y$' .config; then
  printf 'Using the Rust toolchain selected by the source tree\n'
  exit 0
fi
RUST_FEED="$PWD/feeds/packages/lang/rust"
RUST_MAKEFILE="$RUST_FEED/Makefile"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPORT_DIR="${GITHUB_WORKSPACE:-$PWD}/build-reports"
mkdir -p "$REPORT_DIR"

RUST_TARGET=$(make --no-print-directory -s -f - TOPDIR="$PWD" xwrt-rust-target <<'MAKE'
include $(TOPDIR)/rules.mk
include $(TOPDIR)/feeds/packages/lang/rust/rust-values.mk
.PHONY: xwrt-rust-target
xwrt-rust-target:
	@printf '%s\n' '$(RUSTC_TARGET_ARCH)'
MAKE
)
RUST_VERSION=$(sed -n 's/^PKG_VERSION:=//p' "$RUST_MAKEFILE")
RUSTUP_BIN=$(command -v rustup)
PATH="$(dirname "$RUSTUP_BIN"):$PATH"
export PATH
rustup toolchain install "$RUST_VERSION" --profile minimal --no-self-update
rustup target add --toolchain "$RUST_VERSION" "$RUST_TARGET"
RUST_ROOT=$(rustup run "$RUST_VERSION" rustc --print sysroot)
test -d "$RUST_ROOT/lib/rustlib/$RUST_TARGET/lib"
for tool in cargo rustc rustdoc; do
  test -x "$RUST_ROOT/bin/$tool"
done

{
  printf 'CI_RUST_ROOT:=%s\n' "$RUST_ROOT"
  cat "$SCRIPT_DIR/rust-prebuilt.mk"
} > "$RUST_FEED/ci-prebuilt.mk"
# shellcheck disable=SC2016 # Match literal OpenWrt Make expressions.
sed -i '/^include \.\/ci-prebuilt.mk$/d; /^$(eval $(call HostBuild))$/i include ./ci-prebuilt.mk' "$RUST_MAKEFILE"
grep -Fxq 'include ./ci-prebuilt.mk' "$RUST_MAKEFILE"
{
  printf 'Rust target: %s\n' "$RUST_TARGET"
  "$RUST_ROOT/bin/rustc" --version
  sha256sum "$RUST_MAKEFILE"
} | tee "$REPORT_DIR/rust-toolchain.txt"
