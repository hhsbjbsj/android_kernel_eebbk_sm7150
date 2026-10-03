#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$KERNEL_DIR"

echo "=========================================================="
echo "== Syncing ReSukiSU from upstream main branch at build ==="
echo "=========================================================="

RESUKISU_REPO="https://github.com/ReSukiSU/ReSukiSU.git"
UPSTREAM_DIR="${KERNELSU_UPSTREAM_DIR:-/tmp/ReSukiSU-upstream}"
DEST_DIR="$KERNEL_DIR/drivers/kernelsu"
KPM_BACKUP="/tmp/kpm_backup"

# Backup existing KPM files if present
if [ -d "$DEST_DIR/kpm" ]; then
    rm -rf "$KPM_BACKUP"
    cp -r "$DEST_DIR/kpm" "$KPM_BACKUP"
fi

# 1. Fetch / Clone ReSukiSU main with tags and commit history
if [ -d "$UPSTREAM_DIR/.git" ]; then
    echo "[+] Updating existing ReSukiSU clone..."
    git -C "$UPSTREAM_DIR" fetch --depth=2000 --tags origin main
    git -C "$UPSTREAM_DIR" checkout -f origin/main
else
    echo "[+] Cloning latest ReSukiSU main branch with tags..."
    rm -rf "$UPSTREAM_DIR"
    git clone --depth=2000 --tags -b main "$RESUKISU_REPO" "$UPSTREAM_DIR"
fi

# 2. Extract authentic ReSukiSU metadata from upstream git
KSU_COMMIT=$(git -C "$UPSTREAM_DIR" rev-parse --short=8 HEAD)
KSU_COMMIT_FULL=$(git -C "$UPSTREAM_DIR" rev-parse HEAD)
KSU_TAG=$(git -C "$UPSTREAM_DIR" describe --abbrev=0 --tags 2>/dev/null || echo "v4.2.0-rc3")
KSU_COUNT=$(git -C "$UPSTREAM_DIR" rev-list --count HEAD 2>/dev/null || echo 1551)
KSU_VERCODE=$((30000 + KSU_COUNT + 700))
KSU_VERNAME="${KSU_TAG}-${KSU_COMMIT}@ReSukiSU"

echo "[+] Resolved Upstream ReSukiSU Metadata:"
echo "    Tag:         $KSU_TAG"
echo "    Commit:      $KSU_COMMIT ($KSU_COMMIT_FULL)"
echo "    CommitCount: $KSU_COUNT"
echo "    VersionCode: $KSU_VERCODE"
echo "    VersionName: $KSU_VERNAME"

# 3. Synchronize drivers/kernelsu
echo "[+] Syncing upstream kernel and uapi headers to drivers/kernelsu..."
rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"
cp -r "$UPSTREAM_DIR/kernel/"* "$DEST_DIR/"
rm -rf "$DEST_DIR/include/uapi"
mkdir -p "$DEST_DIR/include/uapi"
cp -r "$UPSTREAM_DIR/uapi/"* "$DEST_DIR/include/uapi/"

# Restore KPM files if backup exists
if [ -d "$KPM_BACKUP" ]; then
    echo "[+] Restoring KPM subsystem into drivers/kernelsu/kpm..."
    cp -r "$KPM_BACKUP" "$DEST_DIR/kpm"
fi

# 4. Patch Makefile
echo 'include $(srctree)/$(src)/Kbuild' > "$DEST_DIR/Makefile"

# 5. Patch Kbuild with exact resolved version numbers
echo "[+] Injected upstream version numbers into Kbuild..."
sed -i 's/LOCAL_GIT_EXISTS\s*:=.*/LOCAL_GIT_EXISTS := 1/g' "$DEST_DIR/Kbuild"
sed -i "s/KSU_LOCAL_VERSION\s*:=.*/KSU_LOCAL_VERSION := $KSU_COUNT/g" "$DEST_DIR/Kbuild"
sed -i "s/KSU_VERSION\s*:=.*/KSU_VERSION := $KSU_VERCODE/g" "$DEST_DIR/Kbuild"
sed -i "s/KSU_TAG_NAME\s*:=.*/KSU_TAG_NAME := $KSU_TAG/g" "$DEST_DIR/Kbuild"
sed -i "s/KSU_COMMIT_SHA\s*:=.*/KSU_COMMIT_SHA := $KSU_COMMIT/g" "$DEST_DIR/Kbuild"
sed -i "s/KSU_BRANCH_NAME\s*:=.*/KSU_BRANCH_NAME := main/g" "$DEST_DIR/Kbuild"

# 6. Enable allow_shell = true for ADB root
echo "[+] Enabling allow_shell = true in core/init.c..."
sed -i 's/bool allow_shell = false;/bool allow_shell = true;/g' "$DEST_DIR/core/init.c"

# 7. Adapt Linux 4.14 user-pointer ABI, hide su for unauthorized UIDs, and wire KPM
echo "[+] Adapting sucompat and wiring KPM for Linux 4.14 + SUSFS..."
python3 -u - <<'PY'
from pathlib import Path

# 1. sucompat.h
h_path = Path("drivers/kernelsu/feature/sucompat.h")
if h_path.exists():
    h = h_path.read_text(encoding="utf-8")
    target_h = "#ifdef CONFIG_KSU_SUSFS\nint ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags);"
    replace_h = "#if (LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)) && defined(CONFIG_KSU_SUSFS)\nint ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags);"
    if target_h in h:
        h = h.replace(target_h, replace_h, 1)
        h_path.write_text(h, encoding="utf-8")
        print("  - Updated sucompat.h: 4.14 user-pointer ABI guard installed")

# 2. sucompat.c
c_path = Path("drivers/kernelsu/feature/sucompat.c")
if c_path.exists():
    c = c_path.read_text(encoding="utf-8")
    fa_target = "#ifdef CONFIG_KSU_SUSFS\nint ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags)"
    fa_replace = "#if (LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)) && defined(CONFIG_KSU_SUSFS)\nint ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags)"
    stat_target = "#ifdef CONFIG_KSU_SUSFS\nint ksu_handle_stat(int *dfd, struct filename **filename, int *flags)"
    stat_replace = "#if (LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)) && defined(CONFIG_KSU_SUSFS)\nint ksu_handle_stat(int *dfd, struct filename **filename, int *flags)"
    if fa_target in c:
        c = c.replace(fa_target, fa_replace, 1)
    if stat_target in c:
        c = c.replace(stat_target, stat_replace, 1)

    target_fa = 'int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *__unused_flags)'
    idx_fa = c.find(target_fa)
    if idx_fa != -1:
        check = 'if (!ksu_is_allow_uid_for_current'
        next_brace = c.find('{', idx_fa)
        if check not in c[idx_fa:idx_fa+350]:
            c = c[:next_brace+1] + '\n    if (!ksu_is_allow_uid_for_current(ksu_get_uid_t(current_uid()))) {\n        return 0;\n    }\n' + c[next_brace+1:]

    target_st = 'int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags)'
    idx_st = c.find(target_st)
    if idx_st != -1:
        check = 'if (!ksu_is_allow_uid_for_current'
        next_brace = c.find('{', idx_st)
        if check not in c[idx_st:idx_st+350]:
            c = c[:next_brace+1] + '\n    if (!ksu_is_allow_uid_for_current(ksu_get_uid_t(current_uid()))) {\n        return 0;\n    }\n' + c[next_brace+1:]

    c_path.write_text(c, encoding="utf-8")
    print("  - Updated sucompat.c: 4.14 user-pointer ABI & authorized UID filter installed")

# 3. KPM 4.14 access_ok and pointer compatibility
kpm_path = Path("drivers/kernelsu/kpm/kpm.c")
if kpm_path.exists():
    ks = kpm_path.read_text(encoding="utf-8")
    anchor = "#define KPM_NAME_LEN 32\n"
    helper = """/* Linux 4.14 KPM userspace-pointer compatibility. */
static inline bool kpm_access_ok_read(unsigned long addr,
                                      unsigned long size)
{
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)
    return access_ok(VERIFY_READ, (void __user *)addr, size);
#else
    return access_ok((void __user *)addr, size);
#endif
}

static inline bool kpm_access_ok_write(unsigned long addr,
                                       unsigned long size)
{
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)
    return access_ok(VERIFY_WRITE, (void __user *)addr, size);
#else
    return access_ok((void __user *)addr, size);
#endif
}

"""
    if "kpm_access_ok_read" not in ks:
        ks = ks.replace("access_ok(", "kpm_access_ok_read(")
        ks = ks.replace(anchor, helper + anchor, 1)

    ks = ks.replace("if (!kpm_access_ok_read(arg2, len)) {", "if (!kpm_access_ok_write(arg1, len)) {")
    ks = ks.replace("if (!kpm_access_ok_read(arg2, size)) {", "if (!kpm_access_ok_write(arg2, size)) {")
    version_anchor = """        unsigned int outlen = (unsigned int)arg2;
        int len = strlen(buffer);"""
    version_repl = """        unsigned int outlen = (unsigned int)arg2;
        if (outlen == 0 || !kpm_access_ok_write(arg1, outlen)) {
            goto invalid_arg;
        }
        int len = strlen(buffer);"""
    if version_anchor in ks:
        ks = ks.replace(version_anchor, version_repl, 1)

    ks = ks.replace('char kernel_load_path[256];', 'char kernel_load_path[256] = { 0 };')
    ks = ks.replace('char kernel_args_buffer[256];', 'char kernel_args_buffer[256] = { 0 };')
    ks = ks.replace('char kernel_name_buffer[256];', 'char kernel_name_buffer[256] = { 0 };')
    ks = ks.replace('char buf[256];', 'char buf[256] = { 0 };')
    ks = ks.replace('char buf[1024];', 'char buf[1024] = { 0 };')
    ks = ks.replace('int size;\n', 'int size = 0;\n', 1)
    ks = ks.replace(
        'exit:\n    if (copy_to_user(result_code, &res, sizeof(res)) != 0)',
        'exit:\n    if (!kpm_access_ok_write(result_code, sizeof(res)) || copy_to_user((void __user *)result_code, &res, sizeof(res)) != 0)'
    )
    kpm_path.write_text(ks, encoding="utf-8")
    print("  - Updated kpm.c: 4.14 access_ok and pointer transfer fixes applied")

sa_path = Path("drivers/kernelsu/kpm/super_access.c")
if sa_path.exists():
    sa = sa_path.read_text(encoding="utf-8")
    sa = sa.replace('#include <../fs/mount.h>', '#include "../../fs/mount.h"')
    sa = sa.replace('*out_offset = info->members[i].offset;', '*out_offset = info->members[i1].offset;')
    sa = sa.replace('*out_size = info->members[i].size;', '*out_size = info->members[i1].size;')
    sa_path.write_text(sa, encoding="utf-8")
    print("  - Updated super_access.c: mount.h header and loop indexing fixed")

# 4. Kbuild: Add KPM objects
kb_path = Path("drivers/kernelsu/Kbuild")
if kb_path.exists():
    kb = kb_path.read_text(encoding="utf-8")
    if "kpm/kpm.o" not in kb:
        addition = "\nifdef CONFIG_KPM\nkernelsu-objs += kpm/kpm.o\nkernelsu-objs += kpm/compact.o\nkernelsu-objs += kpm/super_access.o\nendif\n"
        anchor = "kernelsu-objs += compat/apatch_conflict.o\nendif\n"
        if anchor in kb:
            kb = kb.replace(anchor, anchor + addition, 1)
        else:
            kb = kb + addition
        kb_path.write_text(kb, encoding="utf-8")
        print("  - Updated Kbuild: KPM objects registered")

# 5. Kconfig: Add CONFIG_KPM
kc_path = Path("drivers/kernelsu/Kconfig")
if kc_path.exists():
    kc = kc_path.read_text(encoding="utf-8")
    if "config KPM" not in kc:
        block = """config KPM
    bool "Enable SukiSU KPM"
    depends on KSU && 64BIT
    default y
    help
      Enabling this option will activate the KPM feature of SukiSU.

"""
        kc = kc.replace("config KSU_DEBUG", block + "config KSU_DEBUG", 1)
        kc_path.write_text(kc, encoding="utf-8")
        print("  - Updated Kconfig: config KPM added")

# 6. supercall.h: Add KPM commands and ioctls
sc_path = Path("drivers/kernelsu/include/uapi/supercall.h")
if sc_path.exists():
    sc = sc_path.read_text(encoding="utf-8")
    if "KSU_IOCTL_ENABLE_KPM" not in sc:
        cmd_defs = """struct ksu_enable_kpm_cmd {
    __u8 enabled; // Output: true if KPM is enabled
};

DECLARE(__u32, SUKISU_KPM_LOAD, 1);
DECLARE(__u32, SUKISU_KPM_UNLOAD, 2);
DECLARE(__u32, SUKISU_KPM_NUM, 3);
DECLARE(__u32, SUKISU_KPM_LIST, 4);
DECLARE(__u32, SUKISU_KPM_INFO, 5);
DECLARE(__u32, SUKISU_KPM_CONTROL, 6);
DECLARE(__u32, SUKISU_KPM_VERSION, 7);

struct ksu_kpm_cmd {
    __aligned_u64 __user control_code;
    __aligned_u64 __user arg1;
    __aligned_u64 __user arg2;
    __aligned_u64 __user result_code;
};

"""
        sc = sc.replace("/* IOCTL command definitions */", cmd_defs + "/* IOCTL command definitions */", 1)
        sc = sc.replace(
            "// 102 = ENABLE_KPM (KernelPatch Module),deprecated",
            "DEFINE_KSU_UAPI_CONST(__u32, KSU_IOCTL_ENABLE_KPM, _IOC(_IOC_READ, 'K', 102, 0))"
        )
        sc = sc.replace(
            "// 200 = MANAGE_KPM,deprecated",
            "DEFINE_KSU_UAPI_CONST(__u32, KSU_IOCTL_KPM, _IOC(_IOC_READ | _IOC_WRITE, 'K', 200, 0))"
        )
        sc_path.write_text(sc, encoding="utf-8")
        print("  - Updated supercall.h: KPM structs and IOCTLs enabled")

# 7. supercall/dispatch.c: Add do_enable_kpm and do_kpm
dp_path = Path("drivers/kernelsu/supercall/dispatch.c")
if dp_path.exists():
    dp = dp_path.read_text(encoding="utf-8")
    if "do_enable_kpm" not in dp:
        handler_funcs = """#ifdef CONFIG_KPM
#include "kpm/kpm.h"

static int do_enable_kpm(void __user *arg)
{
    struct ksu_enable_kpm_cmd cmd;

    cmd.enabled = IS_ENABLED(CONFIG_KPM);

    if (copy_to_user(arg, &cmd, sizeof(cmd))) {
        pr_err("enable_kpm: copy_to_user failed\\n");
        return -EFAULT;
    }

    return 0;
}
#endif
"""
        anchor_dp = "static const struct ksu_ioctl_cmd_map ksu_ioctl_handlers[] = {"
        dp = dp.replace(anchor_dp, handler_funcs + "\n" + anchor_dp, 1)

        table_entries = """#ifdef CONFIG_KPM
    { 
        .cmd = KSU_IOCTL_ENABLE_KPM,
        .name = "GET_ENABLE_KPM",
        .handler = do_enable_kpm,
        .perm_check = manager_or_root
    },
    { 
        .cmd = KSU_IOCTL_KPM,
        .name = "KPM_OPERATION",
        .handler = do_kpm,
        .perm_check = manager_or_root
    },
#endif
"""
        sentinel = "    { \n        .cmd = 0, \n        .name = NULL,"
        if sentinel in dp:
            dp = dp.replace(sentinel, table_entries + sentinel, 1)
        else:
            sentinel2 = "    {\n        .cmd = 0,"
            dp = dp.replace(sentinel2, table_entries + sentinel2, 1)
        dp_path.write_text(dp, encoding="utf-8")
        print("  - Updated dispatch.c: KPM handlers wired into ioctl table")

# 8. Support additional init.rc paths
ksud_path = Path("drivers/kernelsu/runtime/ksud_integration.c")
if ksud_path.exists():
    ksud = ksud_path.read_text(encoding="utf-8")
    for old_cmp in [
        'if (!!strcmp(dpath, "/init.rc") && !strcmp(dpath, "/system/etc/init/hw/init.rc"))',
        'if (!!strcmp(dpath, "/init.rc") && !!strcmp(dpath, "/system/etc/init/hw/init.rc"))',
    ]:
        if old_cmp in ksud:
            new_cmp = 'if (!!strcmp(dpath, "/init.rc") && !!strcmp(dpath, "/system/etc/init/hw/init.rc") && !!strcmp(dpath, "/system/etc/init/init.rc"))'
            ksud = ksud.replace(old_cmp, new_cmp, 1)
            ksud_path.write_text(ksud, encoding="utf-8")
            print("  - Updated ksud_integration.c: added /system/etc/init/init.rc support")
            break

# 9. Comment out setenforce(true) to allow permissive mode
init_path = Path("drivers/kernelsu/core/init.c")
if init_path.exists():
    init_c = init_path.read_text(encoding="utf-8")
    old_enforce = 'if (!getenforce()) {\n            pr_info("Permissive SELinux, enforcing\\n");\n            setenforce(true);\n        }'
    new_enforce = 'if (!getenforce()) {\n            pr_info("Permissive SELinux, keeping permissive\\n");\n            // setenforce(true);\n        }'
    if old_enforce in init_c:
        init_c = init_c.replace(old_enforce, new_enforce, 1)
        init_path.write_text(init_c, encoding="utf-8")
        print("  - Updated core/init.c: permissive mode preserved")
PY

echo "[PASS] ReSukiSU successfully synchronized and adapted for Linux 4.14 + SUSFS + KPM."
