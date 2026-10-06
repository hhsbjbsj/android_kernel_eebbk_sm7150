### AnyKernel3 Workspace
### begin properties
properties() { '
kernel.string=EEBBK-S6-ReSukiSU-SUSFS-2.3.0
do.devicecheck=0
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=sm6150
device.name2=sm7150
device.name3=s6
device.name4=H130
device.name5=P20H130
supported.versions=
supported.patchlevels=
'; } # end properties

### AnyKernel setup
# shell variables (AnyKernel3 requires UPPERCASE variable names)
BLOCK=boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;
NO_MAGISK_CHECK=1;

# lowercase fallback aliases
block=boot;
is_slot_device=auto;
ramdisk_compression=auto;
patch_vbmeta_flag=auto;
no_magisk_check=1;

## AnyKernel methods (DO NOT CHANGE)
# import patching functions/variables - see for reference
. tools/ak3-core.sh;

## AnyKernel boot install
dump_boot;

# Set SELinux to permissive mode via cmdline
patch_cmdline "androidboot.selinux" "androidboot.selinux=permissive";
patch_cmdline "enforcing" "enforcing=0";

# Force early ADB and unauthenticated debugging via cmdline
patch_cmdline "androidboot.usbconfig" "androidboot.usbconfig=adb";
patch_cmdline "androidboot.debuggable" "androidboot.debuggable=1";
patch_cmdline "androidboot.adb.secure" "androidboot.adb.secure=0";

write_boot;
## end boot install
