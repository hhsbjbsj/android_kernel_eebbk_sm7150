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
DEST_DIR="$KERNEL_DIR/drivers/kernelsu"
echo "[+] Syncing upstream kernel and uapi headers to drivers/kernelsu..."
rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"
cp -r "$UPSTREAM_DIR/kernel/"* "$DEST_DIR/"
rm -rf "$DEST_DIR/include/uapi"
mkdir -p "$DEST_DIR/include/uapi"
cp -r "$UPSTREAM_DIR/uapi/"* "$DEST_DIR/include/uapi/"

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

# 7. Adapt Linux 4.14 user-pointer ABI, hide su for unauthorized UIDs, and disable KPM
echo "[+] Adapting sucompat and apatch for Linux 4.14 + SUSFS..."
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

# 3. Disable KPM conflict check
ap_path = Path("drivers/kernelsu/compat/apatch_conflict.c")
if ap_path.exists():
    ap = ap_path.read_text(encoding="utf-8")
    target_start = "ksu_start_apatch_conflict_check"
    idx = ap.find(target_start)
    if idx != -1:
        next_brace = ap.find("{", idx)
        close_brace = ap.find("}", next_brace)
        if next_brace != -1 and close_brace != -1:
            ap = ap[:next_brace+1] + '\n    pr_info("KernelPatch KPM is disabled on built-in kernel\\n");\n    kernel_patch_type = KERNEL_PATCH_NOT_FOUND;\n' + ap[close_brace:]
            ap_path.write_text(ap, encoding="utf-8")
            print("  - Updated apatch_conflict.c: KPM disabled safely")

# 4. Support additional init.rc paths
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
PY

echo "[PASS] ReSukiSU successfully synchronized and adapted for Linux 4.14 + SUSFS."
