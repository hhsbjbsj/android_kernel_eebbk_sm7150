#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$KERNEL_DIR"

echo "=========================================================="
echo "== Syncing ReSukiSU from upstream main branch at build ==="
echo "=========================================================="

RESUKISU_REPO="https://github.com/Baka-SU/BakaSU.git"
UPSTREAM_DIR="${KERNELSU_UPSTREAM_DIR:-/tmp/ReSukiSU-upstream}"
DEST_DIR="$KERNEL_DIR/drivers/kernelsu"


# 1. Fetch / Clone ReSukiSU main with tags and commit history
if [ -d "$UPSTREAM_DIR/.git" ]; then
    echo "[+] Updating existing ReSukiSU clone..."
    git -C "$UPSTREAM_DIR" fetch --depth=2000 --tags origin main || git -C "$UPSTREAM_DIR" fetch --depth=2000 --tags https://github.com/ReSukiSU/ReSukiSU.git main
    git -C "$UPSTREAM_DIR" checkout -f origin/main
else
    echo "[+] Cloning latest ReSukiSU main branch with tags..."
    rm -rf "$UPSTREAM_DIR"
    git clone --depth=2000 --tags -b main "$RESUKISU_REPO" "$UPSTREAM_DIR" || git clone --depth=2000 --tags -b main "https://github.com/ReSukiSU/ReSukiSU.git" "$UPSTREAM_DIR"
fi

# 2. Extract authentic ReSukiSU metadata from upstream git
KSU_COMMIT=$(git -C "$UPSTREAM_DIR" rev-parse --short=8 HEAD)
KSU_COMMIT_FULL=$(git -C "$UPSTREAM_DIR" rev-parse HEAD)
KSU_TAG=$(git -C "$UPSTREAM_DIR" describe --abbrev=0 --tags 2>/dev/null || echo "v4.2.0-rc3")
KSU_COUNT=$(git -C "$UPSTREAM_DIR" rev-list --count HEAD 2>/dev/null || echo 1551)
KSU_VERCODE=$((30000 + KSU_COUNT + 700))
KSU_VERNAME="${KSU_TAG}-${KSU_COMMIT}@BakaSU"

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

echo "$KSU_COMMIT" > "$DEST_DIR/.resukisu_commit"
echo "$KSU_TAG" > "$DEST_DIR/.resukisu_tag"
echo "$KSU_VERCODE" > "$DEST_DIR/.resukisu_version"
echo "$KSU_VERNAME" > "$DEST_DIR/.resukisu_version_full"



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

# 7. Adapt Linux 4.14 user-pointer ABI and hide su for unauthorized UIDs
echo "[+] Adapting sucompat and apatch for Linux 4.14 + SUSFS..."
python3 -u - <<'PY'
from pathlib import Path

# 1. sucompat.h
h_path = Path("drivers/kernelsu/feature/sucompat.h")
if h_path.exists():
    h = h_path.read_text(encoding="utf-8")
    if "int ksu_handle_post_execve(int *fd, const char *filename, void *argv, void *envp, int *flags, int *retval);" not in h.split("#else")[0]:
        old_h = """#ifdef CONFIG_KSU_SUSFS
int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags);
int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);
#else"""
        new_h = """#ifdef CONFIG_KSU_SUSFS
int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags);
int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);
int ksu_handle_post_execve(int *fd, const char *filename, void *argv, void *envp, int *flags, int *retval);
#else"""
        if old_h in h:
            h = h.replace(old_h, new_h, 1)
            h_path.write_text(h, encoding="utf-8")
            print("  - Updated sucompat.h: exported ksu_handle_post_execve under CONFIG_KSU_SUSFS")

# 2. sucompat.c
c_path = Path("drivers/kernelsu/feature/sucompat.c")
if c_path.exists():
    c = c_path.read_text(encoding="utf-8")

    # Add su_xbin_path and is_su_binary_path helper
    if "is_su_binary_path" not in c:
        path_anchor = "static const char ksud_path[] = KSUD_PATH;\n"
        path_helper = """static const char su_xbin_path[] = "/system/xbin/su";

static inline bool is_su_binary_path(const char *name)
{
    if (unlikely(!name))
        return false;
    if (!memcmp(name, su_path, sizeof(su_path)))
        return true;
    if (!memcmp(name, su_xbin_path, sizeof(su_xbin_path)))
        return true;
    return false;
}
"""
        c = c.replace(path_anchor, path_anchor + path_helper, 1)

    # In do_ksu_handle_execveat_sucompat
    c = c.replace(
        "if (likely(memcmp(filename, su_path, sizeof(su_path))))",
        "if (likely(!is_su_binary_path(filename)))"
    )
    c = c.replace(
        "!static_branch_unlikely(&ksu_su_compat_enabled)",
        "!static_branch_likely(&ksu_su_compat_enabled)"
    )

    # In ksu_handle_faccessat under CONFIG_KSU_SUSFS
    fa_anchor = "int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags)\n{"
    if fa_anchor in c:
        fa_body = """int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags)
{
    const struct cred *old_cred;

#ifdef KSU_COMPAT_USE_STATIC_KEY
    if (!static_branch_likely(&ksu_su_compat_enabled)) {
        return 0;
    }
#else
    if (!ksu_su_compat_enabled) {
        return 0;
    }
#endif

    if (!ksu_is_allow_uid_for_current(ksu_get_uid_t(current_uid()))) {
        return 0;
    }

    if (susfs_is_current_proc_no_su()) {
        return 0;
    }

    if (unlikely(IS_ERR(*filename) || (*filename)->name == NULL))
        return 0;

    if (likely(!is_su_binary_path((*filename)->name)))
        return 0;

    old_cred = override_creds(ksu_cred);
    if (is_ksud_exists()) {
        pr_info("ksu_handle_faccessat su->sh!\\n");
        memcpy((void *)((*filename)->name), sh_path, sizeof(sh_path));
    } else {
        pr_info("no ksud found, don't process faccessat for su!\\n");
    }

    revert_creds(old_cred);
    return 0;
}"""
        fa_end = c.find("int ksu_handle_faccessat(int *dfd, const char __user **filename_user")
        if fa_end != -1:
            fa_prev = c[:c.find(fa_anchor)]
            fa_next = c[fa_end:]
            c = fa_prev + fa_body + "\n#else\n" + fa_next

    # In ksu_handle_stat under CONFIG_KSU_SUSFS
    stat_anchor = "int ksu_handle_stat(int *dfd, struct filename **filename, int *flags)\n{"
    if stat_anchor in c:
        stat_body = """int ksu_handle_stat(int *dfd, struct filename **filename, int *flags)
{
    const struct cred *old_cred;

#ifdef KSU_COMPAT_USE_STATIC_KEY
    if (!static_branch_likely(&ksu_su_compat_enabled)) {
        return 0;
    }
#else
    if (!ksu_su_compat_enabled) {
        return 0;
    }
#endif

    if (!ksu_is_allow_uid_for_current(ksu_get_uid_t(current_uid())))
        return 0;

    if (susfs_is_current_proc_no_su()) {
        return 0;
    }

    if (unlikely(IS_ERR(*filename) || (*filename)->name == NULL)) {
        return 0;
    }

    if (likely(!is_su_binary_path((*filename)->name))) {
        return 0;
    }

    old_cred = override_creds(ksu_cred);
    if (is_ksud_exists()) {
        pr_info("ksu_handle_stat: su->sh!\\n");
        memcpy((void *)((*filename)->name), sh_path, sizeof(sh_path));
    } else {
        pr_info("no ksud found, don't process stat for su!\\n");
    }

    revert_creds(old_cred);
    return 0;
}"""
        stat_end = c.find("int ksu_handle_stat(int *dfd, const char __user **filename_user")
        if stat_end != -1:
            stat_prev = c[:c.find(stat_anchor)]
            stat_next = c[stat_end:]
            c = stat_prev + stat_body + "\n#else\n" + stat_next

    c_path.write_text(c, encoding="utf-8")
    print("  - Updated sucompat.c: 4.14 SUSFS struct filename ABI & authorized UID filter installed")

# 3. Disable KPM conflict check to prevent kernel crash when clicking KPM in Manager
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

# 5. Comment out setenforce(true) to allow permissive mode
init_path = Path("drivers/kernelsu/core/init.c")
if init_path.exists():
    init_c = init_path.read_text(encoding="utf-8")
    old_enforce = 'if (!getenforce()) {\n            pr_info("Permissive SELinux, enforcing\\n");\n            setenforce(true);\n        }'
    new_enforce = 'if (!getenforce()) {\n            pr_info("Permissive SELinux, keeping permissive\\n");\n            // setenforce(true);\n        }'
    if old_enforce in init_c:
        init_c = init_c.replace(old_enforce, new_enforce, 1)
        init_path.write_text(init_c, encoding="utf-8")
        print("  - Updated core/init.c: permissive mode preserved")

# 6. Preserve multi-manager signatures
sign_h_path = Path("drivers/kernelsu/manager/manager_sign.h")
if sign_h_path.exists():
    sign_h = sign_h_path.read_text(encoding="utf-8")
    extra_sign_defs = """// 5ec1cff/KernelSU
#define EXPECTED_SIZE_5EC1CFF 384
#define EXPECTED_HASH_5EC1CFF "7e0c6d7278a3bb8e364e0fcba95afaf3666cf5ff3c245a3b63c8833bd0445cc4"

// rsuntk/KernelSU
#define EXPECTED_SIZE_RSUNTK 0x396
#define EXPECTED_HASH_RSUNTK "f415f4ed9435427e1fdf7f1fccd4dbc07b3d6b8751e4dbcec6f19671f427870b"

// SukiSU-Ultra/SukiSU-Ultra
#define EXPECTED_SIZE_SUKISU 0x35c
#define EXPECTED_HASH_SUKISU "947ae944f3de4ed4c21a7e4f7953ecf351bfa2b36239da37a34111ad29993eef"

// Custom Manager (User Customized)
#ifndef EXPECTED_SIZE
#define EXPECTED_SIZE 0x38b
#endif
#ifndef EXPECTED_HASH
#define EXPECTED_HASH "aaf4f7590df8e55068503e29c58f7e9d5699f0c72bd31a7561cc36c0d044af11"
#endif

#define EXPECTED_SIZE_CUSTOM 0x38b
#define EXPECTED_HASH_CUSTOM "aaf4f7590df8e55068503e29c58f7e9d5699f0c72bd31a7561cc36c0d044af11"
"""
    if "EXPECTED_SIZE_SUKISU" not in sign_h:
        guard_end = sign_h.rfind("#endif")
        if guard_end != -1:
            sign_h = sign_h[:guard_end] + extra_sign_defs + "\n" + sign_h[guard_end:]
            sign_h_path.write_text(sign_h, encoding="utf-8")
            print("  - Updated manager_sign.h: preserved multi-manager signatures")

apk_sign_c_path = Path("drivers/kernelsu/manager/apk_sign.c")
if apk_sign_c_path.exists():
    apk_sign_c = apk_sign_c_path.read_text(encoding="utf-8")
    old_keys_entry = """#ifdef CONFIG_KSU_MULTI_MANAGER_SUPPORT
    { EXPECTED_SIZE_OFFICIAL, EXPECTED_HASH_OFFICIAL }, // tiann/KernelSU
    { EXPECTED_SIZE_KOWX712, EXPECTED_HASH_KOWX712 },"""
    extra_keys_entry = """#ifdef CONFIG_KSU_MULTI_MANAGER_SUPPORT
    { EXPECTED_SIZE_OFFICIAL, EXPECTED_HASH_OFFICIAL }, // tiann/KernelSU
    { EXPECTED_SIZE_5EC1CFF, EXPECTED_HASH_5EC1CFF }, // 5ec1cff/KernelSU
    { EXPECTED_SIZE_RSUNTK, EXPECTED_HASH_RSUNTK }, // rsuntk/KernelSU
    { EXPECTED_SIZE_SUKISU, EXPECTED_HASH_SUKISU }, // SukiSU-Ultra/SukiSU-Ultra
    { EXPECTED_SIZE_KOWX712, EXPECTED_HASH_KOWX712 },
    { EXPECTED_SIZE_CUSTOM, EXPECTED_HASH_CUSTOM }, // Custom Manager (User Customized)"""
    if old_keys_entry in apk_sign_c:
        apk_sign_c = apk_sign_c.replace(old_keys_entry, extra_keys_entry, 1)
        apk_sign_c_path.write_text(apk_sign_c, encoding="utf-8")
        print("  - Updated apk_sign.c: preserved multi-manager signature table")

# 7. Align KERNEL_SU_UAPI_VERSION to 4
uapi_h_path = Path("drivers/kernelsu/include/uapi/supercall.h")
if uapi_h_path.exists():
    uapi_h = uapi_h_path.read_text(encoding="utf-8")
    uapi_h = uapi_h.replace("static const __u32 KERNEL_SU_UAPI_VERSION = 5;", "static const __u32 KERNEL_SU_UAPI_VERSION = 4;")
    uapi_h_path.write_text(uapi_h, encoding="utf-8")
    print("  - Updated supercall.h: aligned KERNEL_SU_UAPI_VERSION to 4")

# 8. Set default KSU_EXPECTED_SIZE and KSU_EXPECTED_HASH in Kbuild
kbuild_path = Path("drivers/kernelsu/Kbuild")
if kbuild_path.exists():
    kbuild = kbuild_path.read_text(encoding="utf-8")
    if "KSU_EXPECTED_SIZE := 0x38b" not in kbuild:
        old_signs = "# Custom Signs\nifdef KSU_EXPECTED_SIZE"
        new_signs = """# Custom Signs
ifndef KSU_EXPECTED_SIZE
KSU_EXPECTED_SIZE := 0x38b
endif
ifndef KSU_EXPECTED_HASH
KSU_EXPECTED_HASH := aaf4f7590df8e55068503e29c58f7e9d5699f0c72bd31a7561cc36c0d044af11
endif

ifdef KSU_EXPECTED_SIZE"""
        if old_signs in kbuild:
            kbuild = kbuild.replace(old_signs, new_signs, 1)
            kbuild_path.write_text(kbuild, encoding="utf-8")
            print("  - Updated Kbuild: set default KSU_EXPECTED_SIZE and KSU_EXPECTED_HASH")

PY

echo "[PASS] ReSukiSU successfully synchronized and adapted for Linux 4.14 + SUSFS."
