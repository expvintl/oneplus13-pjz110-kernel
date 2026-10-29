### AnyKernel3: OnePlus 13 (PJZ110) COS15.0.0.305 — Tier A container kernel
### 6.6.30  (vendor baseline + SYSVIPC / IPC_NS / PID_NS / xt_addrtype, mainline-style version)
properties() { '
kernel.string=OnePlus 13 PJZ110 .305 Tier A kernel (Linux 6.6.30)
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=OP5D0DL1
device.name2=PJZ110
supported.versions=15
supported.patchlevels=
supported.vendorpatchlevels=
'; }

# The kernel lives in `boot`; init_boot only carries the generic ramdisk.
BLOCK=boot;
IS_SLOT_DEVICE=1;
SLOT_SELECT=active;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=0;
NO_VBMETA_PARTITION_PATCH=1;
NO_MAGISK_CHECK=1;

. tools/ak3-core.sh;

# ---- hard target gates -------------------------------------------------------
[ "$(getprop ro.product.model)" = PJZ110 ] || abort "Only PJZ110 is supported.";
[ "$(getprop ro.product.device)" = OP5D0DL1 ] || abort "Unexpected product device.";
[ "$(getprop ro.build.display.id)" = 'PJZ110_15.0.0.305(CN01)' ] || abort "Only PJZ110_15.0.0.305(CN01) is supported.";
case "$SLOT" in _a|_b) ;; *) abort "Active A/B slot could not be verified.";; esac;
case "$BLOCK" in
  /dev/block/by-name/boot"$SLOT"|/dev/block/bootdevice/by-name/boot"$SLOT") ;;
  *) abort "Unexpected boot partition path: $BLOCK";;
esac;
[ -b "/dev/block/by-name/init_boot$SLOT" ] || [ -b "/dev/block/bootdevice/by-name/init_boot$SLOT" ] \
  || abort "Expected separate init_boot partition is missing.";
[ -b "/dev/block/by-name/vendor_boot$SLOT" ] || [ -b "/dev/block/bootdevice/by-name/vendor_boot$SLOT" ] \
  || abort "Expected vendor_boot partition is missing.";
sha256sum -c Image.sha256 || abort "Kernel checksum verification failed.";

ui_print "Target: $BLOCK (active slot only).";
ui_print "This writes the UNPATCHED kernel: any APatch/KernelSU patch in the";
ui_print "current boot image is replaced. Re-patch afterwards if you need root.";
ui_print "No init_boot, vendor_boot, dtbo or vbmeta partition changes.";
ui_print "Keep a stock boot backup and an unlock/fastboot recovery path.";

# Preserve the existing boot header/AVB filler; only the kernel payload changes.
split_boot;
flash_boot;
