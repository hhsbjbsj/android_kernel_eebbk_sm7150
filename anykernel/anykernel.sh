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
# shell variables
block=boot;
is_slot_device=auto;
ramdisk_compression=auto;
patch_vbmeta_flag=auto;

## AnyKernel methods (DO NOT CHANGE)
# import patching functions/variables - see for reference
. tools/ak3-core.sh;

## AnyKernel boot install
dump_boot;

# Set SELinux to permissive mode via cmdline
patch_cmdline "androidboot.selinux" "androidboot.selinux=permissive";
patch_cmdline "enforcing" "enforcing=0";

write_boot;
## end boot install
