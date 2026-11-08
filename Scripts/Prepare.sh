#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Adapted from VIKINGYFY/OpenWRT-CI (Copyright (C) 2026 VIKINGYFY).
set -euo pipefail

REPORT_DIR="${GITHUB_WORKSPACE:-$PWD}/build-reports"
mkdir -p "$REPORT_DIR"

GO_ROOT=$(go env GOROOT)
test -x "$GO_ROOT/bin/go"
sed -i '/^CONFIG_DEVEL=/d; /^# CONFIG_DEVEL is not set$/d; /^CONFIG_GOLANG_BUILD_BOOTSTRAP=/d; /^# CONFIG_GOLANG_BUILD_BOOTSTRAP is not set$/d; /^CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT=/d' .config
printf 'CONFIG_DEVEL=y\n# CONFIG_GOLANG_BUILD_BOOTSTRAP is not set\nCONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT="%s"\n' "$GO_ROOT" >> .config

PYTHON_MAKEFILE=feeds/packages/lang/python/python3/Makefile
sed -i '/^HOST_CONFIGURE_ARGS[[:space:]]*+=/,/^$/s/--enable-optimizations/--disable-optimizations/' "$PYTHON_MAKEFILE"
HOST_PYTHON_ARGS=$(make --no-print-directory -s \
  -C feeds/packages/lang/python/python3 -f Makefile -f - TOPDIR="$PWD" xwrt-host-python-args <<'MAKE'
.PHONY: xwrt-host-python-args
xwrt-host-python-args:
	@printf '%s\n' '$(HOST_CONFIGURE_ARGS)'
MAKE
)
case " $HOST_PYTHON_ARGS " in
  *" --enable-optimizations "*)
    printf 'Host Python PGO is still enabled\n' >&2
    exit 1
    ;;
  *" --disable-optimizations "*) ;;
  *)
    printf 'Host Python optimization setting was not found\n' >&2
    exit 1
    ;;
esac

LLVM_ROOT=$(llvm-config --prefix)
for tool in clang llc opt llvm-dis llvm-strip; do
  test -x "$LLVM_ROOT/bin/$tool"
done
LLVM_SMOKE=$(mktemp -d "${RUNNER_TEMP:-/tmp}/xwrt-bpf.XXXXXX")
trap 'rm -rf "$LLVM_SMOKE"' EXIT
printf 'int xwrt_bpf_smoke(void) { return 0; }\n' > "$LLVM_SMOKE/smoke.c"
"$LLVM_ROOT/bin/clang" --target=bpfel -O2 -emit-llvm -c \
  "$LLVM_SMOKE/smoke.c" -o "$LLVM_SMOKE/smoke.bc"
"$LLVM_ROOT/bin/opt" -O2 -mtriple=bpfel \
  < "$LLVM_SMOKE/smoke.bc" > "$LLVM_SMOKE/smoke.opt"
"$LLVM_ROOT/bin/llvm-dis" \
  < "$LLVM_SMOKE/smoke.opt" > "$LLVM_SMOKE/smoke.S"
"$LLVM_ROOT/bin/llc" -march=bpfel -mcpu=v3 -filetype=obj \
  -o "$LLVM_SMOKE/smoke.o" < "$LLVM_SMOKE/smoke.S"
"$LLVM_ROOT/bin/llvm-strip" --strip-debug "$LLVM_SMOKE/smoke.o"
sed -i '/^CONFIG_BPF_TOOLCHAIN_/d; /^# CONFIG_BPF_TOOLCHAIN_.* is not set$/d' .config
printf 'CONFIG_BPF_TOOLCHAIN_HOST=y\nCONFIG_BPF_TOOLCHAIN_HOST_PATH="%s"\n' "$LLVM_ROOT" >> .config

I2C_MAKEFILE=feeds/packages/utils/i2c-tools/Makefile
if ! grep -Fqx 'PKG_CONFIG_DEPENDS:=CONFIG_PACKAGE_python3-smbus' "$I2C_MAKEFILE"; then
  # shellcheck disable=SC2016 # Preserve literal OpenWrt Make expressions.
  sed -i \
    -e 's/^PKG_BUILD_DEPENDS:=python-setuptools\/host$/PKG_CONFIG_DEPENDS:=CONFIG_PACKAGE_python3-smbus\nPKG_BUILD_DEPENDS:=PACKAGE_python3-smbus:python-setuptools\/host/' \
    -e 's/^\t$(call Py3Build\/Compile)$/\t$(if $(CONFIG_PACKAGE_python3-smbus),$(call Py3Build\/Compile))/' \
    -e 's/^\t$(call Py3Build\/Install)$/\t$(if $(CONFIG_PACKAGE_python3-smbus),$(call Py3Build\/Install))/' \
    -e 's/^  DEPENDS:=+libi2c +python3-light$/  DEPENDS:=+libi2c +PACKAGE_python3-smbus:python3-light/' \
    "$I2C_MAKEFILE"
fi
grep -Fqx 'PKG_CONFIG_DEPENDS:=CONFIG_PACKAGE_python3-smbus' "$I2C_MAKEFILE"
grep -Fqx 'PKG_BUILD_DEPENDS:=PACKAGE_python3-smbus:python-setuptools/host' "$I2C_MAKEFILE"
grep -Fqx '  DEPENDS:=+libi2c +PACKAGE_python3-smbus:python3-light' "$I2C_MAKEFILE"
grep -Fqx $'\t$(if $(CONFIG_PACKAGE_python3-smbus),$(call Py3Build/Compile))' "$I2C_MAKEFILE"
grep -Fqx $'\t$(if $(CONFIG_PACKAGE_python3-smbus),$(call Py3Build/Install))' "$I2C_MAKEFILE"

{
  "$GO_ROOT/bin/go" version
  printf 'Go bootstrap root: %s\n' "$GO_ROOT"
  printf 'Host Python PGO: disabled\nBPF LLVM prefix: %s\n' "$LLVM_ROOT"
  "$LLVM_ROOT/bin/clang" --version
} | tee "$REPORT_DIR/host-toolchains.txt"
