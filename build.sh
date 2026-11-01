#!/usr/bin/env bash
# Build the OnePlus 13 (PJZ110, ColorOS 15.0.0.305) "Tier A" kernel.
#
# Tier A = the vendor's exported .config plus the smallest set of options that
# adds container/namespace plumbing WITHOUT moving a single byte of any struct
# the stock modules depend on:
#     SYSVIPC (+SYSVIPC_SYSCTL/COMPAT), IPC_NS, PID_NS,
#     NETFILTER_XT_MATCH_ADDRTYPE, SECURITY_LANDLOCK
# plus the vendor module-signing certificate, so the stock signed /system_dlkm
# modules pass signature verification and keep loading.
#
# Verified against the phone: 5718 symbols demanded by the 624 stock modules,
# 0 CRC mismatches, 0 unresolved.  scripts/verify-abi.py enforces this.
#
# Outputs (in $OUT_DIR):
#     Image  .config  Module.symvers  arch/arm64/boot/Image
# and, unless SKIP_AK3=1, dist/AK3-OnePlus13-PJZ110-TierA-<release>.zip
#
# Nothing is flashed, installed, or written outside $WORK_DIR/$OUT_DIR/dist.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$HERE"

SRC_REPO=${SRC_REPO:-OnePlusOSS/android_kernel_common_oneplus_sm8750}
SRC_COMMIT=${SRC_COMMIT:-03734e3049cb742786c513ab957f180cde305c9e}
AK3_REPO=${AK3_REPO:-osm0sis/AnyKernel3}
AK3_COMMIT=${AK3_COMMIT:-41f04bdb4ee30a44e429c2c1131d5e8bb32b15f1}

WORK_DIR=${WORK_DIR:-$HERE/.cache}
SRC="$WORK_DIR/src"
OUT=${OUT_DIR:-$HERE/out}

# net/netfilter has both xt_DSCP.c (target) and xt_dscp.c (match).  On a
# case-folded filesystem (f2fs casefold, exFAT) one of them is lost during
# extraction and the build dies with "no rule to make target xt_DSCP.o".
# Fail early with an actionable message instead of that confusing error.
check_case_sensitive() {
	local dir=$1 probe
	mkdir -p "$dir"
	probe="$dir/.case-probe.$$"
	mkdir -p "$probe"
	: >"$probe/A"
	: >"$probe/a"
	if [ "$(ls -1 "$probe" | wc -l)" -ne 2 ]; then
		rm -rf "$probe"
		return 1
	fi
	rm -rf "$probe"
}
if ! check_case_sensitive "$WORK_DIR" || ! check_case_sensitive "$OUT"; then
	echo "WORK_DIR/OUT_DIR must be on a case-sensitive filesystem" >&2
	echo "  WORK_DIR=$WORK_DIR" >&2
	echo "  OUT_DIR=$OUT" >&2
	echo "  use a case-sensitive path, or clear casefold with: chattr -F <dir>" >&2
	exit 1
fi

DIST="$HERE/dist"
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
EXPECTED_RELEASE=${EXPECTED_RELEASE:-6.6.30}

log() { printf '==> %s\n' "$*"; }

# ------------------------------------------------------------------ source
if [ ! -d "$SRC" ]; then
	log "fetching $SRC_REPO@$SRC_COMMIT"
	mkdir -p "$WORK_DIR"
	tmp="$WORK_DIR/src.tar.gz"
	curl -fsSL -o "$tmp" \
		"https://codeload.github.com/$SRC_REPO/tar.gz/$SRC_COMMIT"
	mkdir -p "$WORK_DIR/unpack"
	tar -xzf "$tmp" -C "$WORK_DIR/unpack"
	mv "$WORK_DIR/unpack/"*"$SRC_COMMIT" "$SRC"
	rm -rf "$tmp" "$WORK_DIR/unpack"
fi

# ------------------------------------------------------------------ patches
# Idempotent: a patch that is already applied is skipped.
for p in patches/*.patch; do
	if patch -p1 -d "$SRC" --dry-run --batch --forward -s -f <"$p" >/dev/null 2>&1; then
		log "applying $(basename "$p")"
		patch -p1 -d "$SRC" --batch --forward -s <"$p"
	elif patch -p1 -d "$SRC" --dry-run -R -s -f <"$p" >/dev/null 2>&1; then
		log "already applied: $(basename "$p")"
	else
		echo "cannot apply $p — the source tree is not the expected revision" >&2
		exit 1
	fi
done

# ------------------------------------------------------------------ config
mkdir -p "$OUT" "$DIST"
if [ ! -e "$OUT/.config" ]; then
	cp configs/vendor-exported.config "$OUT/.config"
fi

if [ ! -e "$OUT/abi_symbollist.raw" ]; then
	python3 scripts/gen-whitelist.py "$SRC" "$OUT/abi_symbollist.raw"
fi

log "applying Tier A + Droidspaces configuration"
# Droidspaces GKI extras: self-contained options that do not resize core
# structures or change the stock modules' symbol CRCs.  Do NOT add
# CGROUP_PIDS/CFS_BANDWIDTH/NF_TABLES/BRIDGE_NETFILTER here: they resize
# cgroup/net/skbuff structures and break the vendor-module ABI.
"$SRC/scripts/config" --file "$OUT/.config" \
	-e SYSVIPC -e SYSVIPC_SYSCTL -e IPC_NS -e PID_NS \
	-e POSIX_MQUEUE -e POSIX_MQUEUE_SYSCTL -e DEVTMPFS \
	-e MACVLAN \
	-e IP6_NF_NAT -e IP6_NF_TARGET_MASQUERADE \
	-e TMPFS_POSIX_ACL -e TMPFS_XATTR \
	-e IP_NF_TARGET_REJECT -e IP6_NF_TARGET_REJECT \
	-e NETFILTER_XT_TARGET_LOG \
	-e NETFILTER_XT_MATCH_RECENT \
	-e IP_SET -e IP_SET_HASH_IP -e IP_SET_HASH_NET -e NETFILTER_XT_SET \
	-e SECURITY_LANDLOCK \
	-e NETFILTER_XT_MATCH_ADDRTYPE \
	-e DEBUG_INFO_BTF -e DEBUG_INFO_BTF_MODULES -e MODULE_ALLOW_BTF_MISMATCH \
	-d LOCALVERSION_AUTO \
	--set-str LOCALVERSION "" \
	--set-str UNUSED_KSYMS_WHITELIST "$OUT/abi_symbollist.raw" \
	--set-str SYSTEM_TRUSTED_KEYS "$HERE/certs/vendor-module-signing.x509"
# LOCALVERSION is deliberately empty: uname -r must read plain "6.6.30".
# Safe because every stock module carries __versions CRCs, and
# kernel/module/version.c:same_magic() skips the UTS_RELEASE token (only the
# "SMP preempt mod_unload modversions aarch64" tail is compared).
rm -f "$OUT/localversion"*

# ------------------------------------------------------------------ toolchain
# Toolchain: LLVM=1 uses clang from PATH; LLVM=/dir/ uses that prefix.
# Setting TOOLCHAIN to a self-contained LLVM tree (e.g. an unpacked Debian or
# Ubuntu llvm-18 + dwarves directory) makes the build independent of the host
# packages; CI uses the distro clang-18 instead.
if [ -n "${TOOLCHAIN:-}" ]; then
	LLVM="$TOOLCHAIN/usr/lib/llvm-18/bin/"
	export LD_LIBRARY_PATH="$TOOLCHAIN/usr/lib/aarch64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	# pahole lives in the unpacked tree too.  Keeping it on PATH is not cosmetic:
	# without pahole olddefconfig drops CONFIG_DEBUG_INFO_BTF, which changes
	# __user/__rcu type tags and with them thousands of module CRCs.
	PATH="$TOOLCHAIN/usr/bin:$PATH"
	HOSTCFLAGS="-I$TOOLCHAIN/usr/include -I$TOOLCHAIN/usr/include/aarch64-linux-gnu"
	HOSTLDFLAGS="-L$TOOLCHAIN/usr/lib/aarch64-linux-gnu -Wl,-rpath,$TOOLCHAIN/usr/lib/aarch64-linux-gnu"
	# Export the plain names: KBUILD_HOSTCFLAGS is recomputed by the top Makefile
	# from $(HOSTCFLAGS), and the tools/ build (resolve_btfids → libbpf) reads
	# HOSTCFLAGS straight from the environment.  Without this libelf.h/gelf.h are
	# not found and the BTF-enabled build stops at scripts.
	export HOSTCFLAGS HOSTLDFLAGS
	export KBUILD_ABS_SRCTREE=1 TMPDIR="$OUT/tmp"
	mkdir -p "$TMPDIR"
fi
if [ -z "${LLVM:-}" ] && [ -d /usr/lib/llvm-18/bin ]; then
	LLVM=/usr/lib/llvm-18/bin/
fi
log "toolchain: ${LLVM:-system clang}"
[ -z "${LLVM:-}" ] || PATH="${LLVM%/}:$PATH"
command -v clang >/dev/null || { echo 'clang not found — install clang-18 or set TOOLCHAIN' >&2; exit 1; }

run_make() {
	make -C "$SRC" O="$OUT" ARCH=arm64 LLVM="${LLVM:-1}" LLVM_IAS=1 \
		LOCALVERSION= "$@"
}

# ------------------------------------------------------------------ build
log "olddefconfig"
run_make olddefconfig

# CONFIG_DEBUG_INFO_BTF must survive olddefconfig: it does not only add BTF, it
# also defines __user/__rcu as btf_type_tag attributes (include/linux/compiler_types.h).
# Losing it rewrites the type of nearly every exported symbol and the stock
# modules then refuse to load — a failure that is invisible until boot.
if ! grep -qx 'CONFIG_DEBUG_INFO_BTF=y' "$OUT/.config"; then
	echo 'CONFIG_DEBUG_INFO_BTF was dropped by olddefconfig' >&2
	echo 'pahole (dwarves) is missing or too old — install dwarves or set TOOLCHAIN' >&2
	exit 1
fi

release=$(run_make -s kernelrelease)
if [ "$release" != "$EXPECTED_RELEASE" ]; then
	echo "unexpected kernel release '$release' (want '$EXPECTED_RELEASE')" >&2
	exit 1
fi
log "kernel release: $release"

log "building Image + modules with -j$JOBS"
run_make -j"$JOBS" prepare scripts
run_make -j"$JOBS" Image modules

# ------------------------------------------------------------------ verify
log "verifying the ABI against the stock .305 modules"
python3 scripts/verify-abi.py "$OUT"

image=$(ls -l "$OUT/arch/arm64/boot/Image" | awk '{print $5}')
log "Image: $OUT/arch/arm64/boot/Image ($image bytes)"

# ------------------------------------------------------------------ package
if [ "${SKIP_AK3:-0}" != 1 ]; then
	log "packaging AnyKernel3 zip"
	AK3_DIR="$WORK_DIR/AnyKernel3"
	if [ ! -d "$AK3_DIR" ]; then
		git clone -q "https://github.com/$AK3_REPO.git" "$AK3_DIR"
	fi
	git -C "$AK3_DIR" -c advice.detachedHead=false checkout -q "$AK3_COMMIT"
	python3 scripts/package-ak3.py "$OUT" "$AK3_DIR" "$DIST"
fi

log "done"
