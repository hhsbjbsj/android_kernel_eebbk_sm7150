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
DEST_DIR="${KERNELSU_DEST_DIR:-$KERNEL_DIR/drivers/kernelsu}"

# 1. Fetch / Clone ReSukiSU main with tags and full commit history
if [ -d "$UPSTREAM_DIR/.git" ]; then
    echo "[+] Updating existing ReSukiSU clone..."
    if [ "${KERNELSU_OFFLINE_SYNC:-0}" != "1" ]; then
        if [ -f "$UPSTREAM_DIR/.git/shallow" ]; then
            git -C "$UPSTREAM_DIR" fetch --unshallow --tags origin main || git -C "$UPSTREAM_DIR" fetch --unshallow --tags https://github.com/ReSukiSU/ReSukiSU.git main
        else
            git -C "$UPSTREAM_DIR" fetch --tags origin main || git -C "$UPSTREAM_DIR" fetch --tags https://github.com/ReSukiSU/ReSukiSU.git main
        fi
        git -C "$UPSTREAM_DIR" checkout -f origin/main
    fi
else
    echo "[+] Cloning latest ReSukiSU main branch with full history and tags..."
    rm -rf "$UPSTREAM_DIR"
    git clone --tags -b main "$RESUKISU_REPO" "$UPSTREAM_DIR" || git clone --tags -b main "https://github.com/ReSukiSU/ReSukiSU.git" "$UPSTREAM_DIR"
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
echo "[+] Syncing upstream kernel and uapi headers to $DEST_DIR..."
rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"
cp -r "$UPSTREAM_DIR/kernel/"* "$DEST_DIR/"
rm -rf "$DEST_DIR/include/uapi"
mkdir -p "$DEST_DIR/include/uapi"
cp -r "$UPSTREAM_DIR/uapi/"* "$DEST_DIR/include/uapi/"

echo "$KSU_COMMIT" > "$DEST_DIR/.resukisu_commit"
echo "$KSU_COMMIT_FULL" > "$DEST_DIR/.resukisu_commit_full"
echo "$KSU_TAG" > "$DEST_DIR/.resukisu_tag"
echo "$KSU_VERCODE" > "$DEST_DIR/.resukisu_version"
echo "$KSU_VERNAME" > "$DEST_DIR/.resukisu_version_full"

# 4. Patch Makefile
echo 'include $(srctree)/$(src)/Kbuild' > "$DEST_DIR/Makefile"

# 5. Adapt ReSukiSU / BakaSU for Linux 4.14 + SUSFS 2.3.0 + Run 152 parity
echo "[+] Applying Linux 4.14 + SUSFS 2.3.0 + Manager Handshake adaptations..."
export DEST_DIR KSU_COUNT KSU_VERCODE KSU_TAG KSU_COMMIT
PYTHON_BIN=""
for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys" >/dev/null 2>&1; then
        PYTHON_BIN="$cand"
        break
    fi
done
if [ -z "$PYTHON_BIN" ]; then
    echo "[FATAL] python3 / python not found" >&2
    exit 1
fi
if command -v cygpath >/dev/null 2>&1; then
    DEST_DIR="$(cygpath -m "$DEST_DIR")"
    export DEST_DIR
fi
"$PYTHON_BIN" -u - <<'PY'
import os
import re
from pathlib import Path

dest = Path(os.environ["DEST_DIR"])
ksu_count = os.environ["KSU_COUNT"]
ksu_vercode = os.environ["KSU_VERCODE"]
ksu_tag = os.environ["KSU_TAG"]
ksu_commit = os.environ["KSU_COMMIT"]

# 0. Kbuild metadata & default Custom Manager signature
kbuild_path = dest / "Kbuild"
if kbuild_path.exists():
    kb = kbuild_path.read_text(encoding="utf-8")
    kb = re.sub(r"^LOCAL_GIT_EXISTS\s*:=.*$", "LOCAL_GIT_EXISTS := 1", kb, flags=re.M)
    kb = re.sub(r"^\$\(shell cd \$\(KSU_SRC\); \[ -f \.\./\.git/shallow \].*$", "# shallow fetch skipped", kb, flags=re.M)
    kb = re.sub(r"^KSU_LOCAL_VERSION\s*:=.*$", f"KSU_LOCAL_VERSION := {ksu_count}", kb, flags=re.M)
    kb = re.sub(r"^KSU_VERSION\s*:=.*$", f"KSU_VERSION := {ksu_vercode}", kb, flags=re.M)
    kb = re.sub(r"^KSU_TAG_NAME\s*:=.*$", f"KSU_TAG_NAME := {ksu_tag}", kb, flags=re.M)
    kb = re.sub(r"^KSU_COMMIT_SHA\s*:=.*$", f"KSU_COMMIT_SHA := {ksu_commit}", kb, flags=re.M)
    kb = re.sub(
        r"ifneq \(\$\(shell cd \$\(KSU_SRC\); \$\(GIT_BIN\) diff-index --quiet HEAD; echo \$\$\?\),0\)\nKSU_COMMIT_SHA\s*:=\s*\$\(KSU_COMMIT_SHA\)-dirty\nendif",
        "# preserve upstream KSU_COMMIT_SHA without outer-repo dirty suffix",
        kb,
    )
    kb = re.sub(r"^KSU_BRANCH_NAME\s*:=.*$", "KSU_BRANCH_NAME := main", kb, flags=re.M)

    if "KSU_EXPECTED_SIZE := 0x039a" not in kb:
        old_signs = "# Custom Signs\nifdef KSU_EXPECTED_SIZE"
        new_signs = """# Custom Signs
ifndef KSU_EXPECTED_SIZE
KSU_EXPECTED_SIZE := 0x039a
endif
ifndef KSU_EXPECTED_HASH
KSU_EXPECTED_HASH := 366aa724f4ed84d589fb47077cee4dc6aac45c37c4a50a6e1eaed4446bb3bc03
endif

ifdef KSU_EXPECTED_SIZE"""
        if old_signs in kb:
            kb = kb.replace(old_signs, new_signs, 1)
        else:
            kb += '\nccflags-y += -DEXPECTED_SIZE=0x039a -DEXPECTED_HASH=\\"366aa724f4ed84d589fb47077cee4dc6aac45c37c4a50a6e1eaed4446bb3bc03\\"\n'
    kbuild_path.write_text(kb, encoding="utf-8")
    print("  - Updated Kbuild: injected upstream metadata & default 0x039a custom manager flags")

# 1. core/init.c: allow_shell = true & preserve permissive SELinux
init_path = dest / "core" / "init.c"
if init_path.exists():
    init_c = init_path.read_text(encoding="utf-8")
    init_c = init_c.replace("bool allow_shell = false;", "bool allow_shell = true;")
    old_enforce = 'if (!getenforce()) {\n            pr_info("Permissive SELinux, enforcing\\n");\n            setenforce(true);\n        }'
    new_enforce = 'if (!getenforce()) {\n            pr_info("Permissive SELinux, keeping permissive\\n");\n            // setenforce(true);\n        }'
    if old_enforce in init_c:
        init_c = init_c.replace(old_enforce, new_enforce, 1)
    init_path.write_text(init_c, encoding="utf-8")
    print("  - Updated core/init.c: allow_shell=true & permissive mode preserved")

# 2. feature/sucompat.h
h_path = dest / "feature" / "sucompat.h"
if h_path.exists():
    h = h_path.read_text(encoding="utf-8")
    if "int ksu_handle_post_execve(" not in h.split("#else")[0]:
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
            print("  - Updated feature/sucompat.h: exported ksu_handle_post_execve under CONFIG_KSU_SUSFS")

# 3. feature/sucompat.c
c_path = dest / "feature" / "sucompat.c"
if c_path.exists():
    c = c_path.read_text(encoding="utf-8")
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
        if path_anchor in c:
            c = c.replace(path_anchor, path_anchor + path_helper, 1)

    c = c.replace(
        "if (likely(memcmp(filename, su_path, sizeof(su_path))))",
        "if (likely(!is_su_binary_path(filename)))",
    )
    c = c.replace(
        "!static_branch_unlikely(&ksu_su_compat_enabled)",
        "!static_branch_likely(&ksu_su_compat_enabled)",
    )

    old_post = """int ksu_handle_post_execve_common(int *fd, const char **filename, void *argv, void *envp, int *flags, int *retval)
{
    if (likely(!test_thread_flag(TIF_PROC_IN_KSU_EXECVE))) {
        return -EINVAL;
    }
#ifndef KSU_COMPAT_HAS_SUSFS_INSTALL_SU_FD_DIRECT_CALL
    ksu_install_su_fd();
#endif"""
    new_post = """int ksu_handle_post_execve_common(int *fd, const char **filename, void *argv, void *envp, int *flags, int *retval)
{
    if (likely(!test_thread_flag(TIF_PROC_IN_KSU_EXECVE))) {
        return -EINVAL;
    }
    clear_thread_flag(TIF_PROC_IN_KSU_EXECVE);
#ifndef KSU_COMPAT_HAS_SUSFS_INSTALL_SU_FD_DIRECT_CALL
    if (!retval || *retval >= 0)
        ksu_install_su_fd();
#endif"""
    if old_post in c:
        c = c.replace(old_post, new_post, 1)

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
            c = c[:c.find(fa_anchor)] + fa_body + "\n#else\n" + c[fa_end:]

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
            c = c[:c.find(stat_anchor)] + stat_body + "\n#else\n" + c[stat_end:]

    c_path.write_text(c, encoding="utf-8")
    print("  - Updated feature/sucompat.c: 4.14 SUSFS struct filename ABI & authorized UID filter installed")

# 4. compat/apatch_conflict.c: disable KPM conflict kthread
ap_path = dest / "compat" / "apatch_conflict.c"
if ap_path.exists():
    ap = ap_path.read_text(encoding="utf-8")
    idx = ap.find("void ksu_start_apatch_conflict_check")
    if idx != -1:
        next_brace = ap.find("{", idx)
        close_brace = ap.find("}", next_brace)
        if next_brace != -1 and close_brace != -1:
            ap = (
                ap[:next_brace + 1]
                + '\n    pr_info("KernelPatch KPM is disabled on built-in kernel\\n");\n    kernel_patch_type = KERNEL_PATCH_NOT_FOUND;\n'
                + ap[close_brace:]
            )
            ap_path.write_text(ap, encoding="utf-8")
            print("  - Updated compat/apatch_conflict.c: KPM disabled safely")

# 5. runtime/ksud_integration.c: support /system/etc/init/init.rc
ksud_path = dest / "runtime" / "ksud_integration.c"
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
            print("  - Updated runtime/ksud_integration.c: added /system/etc/init/init.rc support")
            break

# 6. manager/manager_sign.h & manager/apk_sign.c: dual custom signatures (0x039a + 0x38b) & multi-manager
sign_h_path = dest / "manager" / "manager_sign.h"
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
#define EXPECTED_SIZE 0x039a
#endif
#ifndef EXPECTED_HASH
#define EXPECTED_HASH "366aa724f4ed84d589fb47077cee4dc6aac45c37c4a50a6e1eaed4446bb3bc03"
#endif

#ifndef EXPECTED_SIZE_CUSTOM
#define EXPECTED_SIZE_CUSTOM 0x039a
#endif
#ifndef EXPECTED_HASH_CUSTOM
#define EXPECTED_HASH_CUSTOM "366aa724f4ed84d589fb47077cee4dc6aac45c37c4a50a6e1eaed4446bb3bc03"
#endif

#ifndef EXPECTED_SIZE_CUSTOM_V1
#define EXPECTED_SIZE_CUSTOM_V1 0x38b
#endif
#ifndef EXPECTED_HASH_CUSTOM_V1
#define EXPECTED_HASH_CUSTOM_V1 "aaf4f7590df8e55068503e29c58f7e9d5699f0c72bd31a7561cc36c0d044af11"
#endif
"""
    if "EXPECTED_SIZE_CUSTOM_V1" not in sign_h:
        guard_end = sign_h.rfind("#endif")
        if guard_end != -1:
            sign_h = sign_h[:guard_end] + extra_sign_defs + "\n" + sign_h[guard_end:]
        else:
            sign_h += "\n" + extra_sign_defs
        sign_h_path.write_text(sign_h, encoding="utf-8")
        print("  - Updated manager/manager_sign.h: added 0x039a, 0x38b & multi-manager definitions")

apk_sign_c_path = dest / "manager" / "apk_sign.c"
if apk_sign_c_path.exists():
    apk_sign_c = apk_sign_c_path.read_text(encoding="utf-8")
    patched_apk = False
    for primary_line in [
        "    { EXPECTED_SIZE_BAKASU, EXPECTED_HASH_BAKASU }, /* Baka-SU/BakaSU */",
        "    { EXPECTED_SIZE_RESUKISU, EXPECTED_HASH_RESUKISU }, /* ReSukiSU/ReSukiSU */",
    ]:
        if primary_line in apk_sign_c and "EXPECTED_SIZE_CUSTOM_V1" not in apk_sign_c:
            apk_sign_c = apk_sign_c.replace(
                primary_line,
                primary_line
                + "\n    { EXPECTED_SIZE_CUSTOM, EXPECTED_HASH_CUSTOM }, // Custom Manager (0x039a)"
                + "\n    { EXPECTED_SIZE_CUSTOM_V1, EXPECTED_HASH_CUSTOM_V1 }, // Custom Manager V1 (0x38b)",
                1,
            )
            patched_apk = True
            break

    official_line = "    { EXPECTED_SIZE_OFFICIAL, EXPECTED_HASH_OFFICIAL }, // tiann/KernelSU"
    if official_line in apk_sign_c and "EXPECTED_SIZE_SUKISU" not in apk_sign_c:
        apk_sign_c = apk_sign_c.replace(
            official_line,
            official_line
            + "\n    { EXPECTED_SIZE_5EC1CFF, EXPECTED_HASH_5EC1CFF }, // 5ec1cff/KernelSU"
            + "\n    { EXPECTED_SIZE_RSUNTK, EXPECTED_HASH_RSUNTK }, // rsuntk/KernelSU"
            + "\n    { EXPECTED_SIZE_SUKISU, EXPECTED_HASH_SUKISU }, // SukiSU-Ultra/SukiSU-Ultra",
            1,
        )
        patched_apk = True

    if not patched_apk and "EXPECTED_SIZE_CUSTOM_V1" not in apk_sign_c:
        raise SystemExit("[FATAL] Failed to patch apk_sign_keys[] in manager/apk_sign.c")

    apk_sign_c_path.write_text(apk_sign_c, encoding="utf-8")
    print("  - Updated manager/apk_sign.c: unconditional 0x039a + 0x38b & multi-manager table enabled")

# 7. supercall/supercall.c: relax O_CLOEXEC on ksu_install_fd (Run 152 run29 parity)
sc_path = dest / "supercall" / "supercall.c"
if sc_path.exists():
    sc = sc_path.read_text(encoding="utf-8")
    if "ksu_install_fd_with_permissions(O_CLOEXEC, 0)" in sc:
        sc = sc.replace(
            "ksu_install_fd_with_permissions(O_CLOEXEC, 0)",
            "ksu_install_fd_with_permissions(0, 0)",
            1,
        )
        sc_path.write_text(sc, encoding="utf-8")
        print("  - Updated supercall/supercall.c: relaxed O_CLOEXEC on ksu_install_fd")

# 8. SUSFS 2.3.0 priority_uid_filter wiring in dispatch.c, pkg_observer.c, throne_tracker.c
disp_p = dest / "supercall" / "dispatch.c"
if disp_p.exists():
    ds = disp_p.read_text(encoding="utf-8")
    if "#include <linux/susfs.h>" not in ds:
        ds = ds.replace(
            "#include <linux/susfs_def.h>",
            "#include <linux/susfs_def.h>\n#include <linux/susfs.h>",
            1,
        )
    if "CMD_SUSFS_SET_PRIORITY_UID_FILTER" not in ds:
        anchor = "    case CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING: {\n"
        block = (
            "    case CMD_SUSFS_SET_PRIORITY_UID_FILTER: {\n"
            "        susfs_set_priority_uid_filter(arg);\n"
            "        return 0;\n"
            "    }\n"
        )
        if anchor not in ds:
            raise SystemExit("[FATAL] Missing CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING anchor in dispatch.c")
        ds = ds.replace(anchor, block + anchor, 1)
    disp_p.write_text(ds, encoding="utf-8")
    print("  - Updated supercall/dispatch.c: wired CMD_SUSFS_SET_PRIORITY_UID_FILTER")

pkg_p = dest / "manager" / "pkg_observer.c"
if pkg_p.exists():
    ps = pkg_p.read_text(encoding="utf-8")
    if "susfs_parse_priority_app_strings" not in ps:
        if "#include <linux/susfs.h>" not in ps:
            ps = ps.replace(
                "#include <linux/version.h>",
                "#include <linux/version.h>\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#endif",
                1,
            )
        anchor = "static void ksu_defer_track_throne(void)\n{\n    struct callback_head *cb;\n"
        if anchor in ps:
            ps = ps.replace(
                anchor,
                anchor + "\n#ifdef CONFIG_KSU_SUSFS\n    susfs_parse_priority_app_strings();\n#endif\n",
                1,
            )
            pkg_p.write_text(ps, encoding="utf-8")
            print("  - Updated manager/pkg_observer.c: added susfs_parse_priority_app_strings")

thr_p = dest / "manager" / "throne_tracker.c"
if thr_p.exists():
    ts = thr_p.read_text(encoding="utf-8")
    if "susfs_parse_priority_app_strings" not in ts:
        if "#include <linux/susfs.h>" not in ts:
            ts = ts.replace(
                "#include <linux/version.h>",
                "#include <linux/version.h>\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#endif",
                1,
            )
        anchor = "void track_throne(unsigned int flags)\n{\n"
        if anchor in ts:
            ts = ts.replace(
                anchor,
                anchor + "#ifdef CONFIG_KSU_SUSFS\n    susfs_parse_priority_app_strings();\n#endif\n",
                1,
            )
            thr_p.write_text(ts, encoding="utf-8")
            print("  - Updated manager/throne_tracker.c: added susfs_parse_priority_app_strings")

# 9. 4.14 Kbuild code_generation compatibility (syscall_no.mk & preinit_runner.mk)
sysno_mk = dest / "tools" / "code_generation" / "syscall_no" / "syscall_no.mk"
if sysno_mk.exists():
    smk = sysno_mk.read_text(encoding="utf-8")
    if "always += compat/syscall_no.h" not in smk and "always-y += compat/syscall_no.h" in smk:
        smk = smk.replace(
            "always-y += compat/syscall_no.h",
            "always += compat/syscall_no.h\nalways-y += compat/syscall_no.h",
            1,
        )
        sysno_mk.write_text(smk, encoding="utf-8")
        print("  - Updated syscall_no.mk: added 4.14 always += compat/syscall_no.h")

preinit_h = dest / "preinit" / "preinit.h"
if preinit_h.exists():
    ph = preinit_h.read_text(encoding="utf-8")
    ph_new = ph.replace(
        "static inline void ksu_preinit_handle_execve_manual(const char **filename, struct user_arg_ptr *argv)\n{\n    return false;\n}",
        "static inline void ksu_preinit_handle_execve_manual(const char **filename, struct user_arg_ptr *argv)\n{\n}",
    )
    if ph_new != ph:
        preinit_h.write_text(ph_new, encoding="utf-8")
        print("  - Updated preinit/preinit.h: fixed void stub return")

preinit_mk = dest / "tools" / "code_generation" / "preinit_runner" / "preinit_runner.mk"
if preinit_mk.exists():
    pmk = preinit_mk.read_text(encoding="utf-8")
    # Fix 4.14 arm64 cross-target flags and disable preinit runner when 4.14 SUSFS fs/exec.c lacks ksu_setup_preinit_file
    patched_pmk = """# Linux 4.14 compatibility: only build preinit runner if SUSFS fs/exec.c actually hooks ksu_setup_preinit_file
KSU_HAS_PREINIT_HOOK := 1
ifdef CONFIG_KSU_SUSFS
ifneq ($(shell grep -q "ksu_setup_preinit_file" $(srctree)/fs/exec.c 2>/dev/null; echo $$?),0)
KSU_HAS_PREINIT_HOOK := 0
endif
endif

ifeq ($(KSU_HAS_PREINIT_HOOK),0)
$(info -- $(REPO_NAME): 4.14 SUSFS without ksu_setup_preinit_file hook, preinit disabled cleanly)
ccflags-y += -DKSU_NO_PREINIT
else
ifeq ($(CLANG_FLAGS),)
ifeq ($(ARCH),arm64)
CLANG_FLAGS := --target=aarch64-linux-gnu
endif
endif
""" + pmk.replace(
        "$(shell $(CC) -print-file-name=include)",
        "$(shell $(filter-out ccache,$(CC)) -print-file-name=include)",
    ).replace(
        "targets += preinit/runner.elf",
        "targets += preinit/runner.elf\nalways += preinit/runner.elf\nalways-y += preinit/runner.elf",
    ) + "\nendif\n"
    preinit_mk.write_text(patched_pmk, encoding="utf-8")
    print("  - Updated preinit_runner.mk: added 4.14 SUSFS preinit guard & arm64 CLANG_FLAGS fix")
PY

# 6. Pre-generate compat/syscall_no.h on Linux hosts so parallel 4.14 Kbuild never races
if [ -f "$DEST_DIR/tools/code_generation/syscall_no/syscall_no.c" ] && command -v gcc >/dev/null 2>&1; then
    echo "[+] Pre-generating $DEST_DIR/compat/syscall_no.h..."
    mkdir -p "$DEST_DIR/compat"
    TMP_SYSNO_TOOL="$(mktemp /tmp/ksu_syscall_no.XXXXXX)"
    gcc -O2 "$DEST_DIR/tools/code_generation/syscall_no/syscall_no.c" -o "$TMP_SYSNO_TOOL"
    if [ -f "$KERNEL_DIR/arch/arm64/include/asm/unistd32.h" ]; then
        "$TMP_SYSNO_TOOL" "$DEST_DIR/compat/syscall_no.h" --arm64-compat "$KERNEL_DIR/arch/arm64/include/asm/unistd32.h"
    else
        "$TMP_SYSNO_TOOL" "$DEST_DIR/compat/syscall_no.h" --arm64
    fi
    rm -f "$TMP_SYSNO_TOOL"
    test -s "$DEST_DIR/compat/syscall_no.h"
    echo "  - Pre-generated compat/syscall_no.h"
fi

echo "[PASS] ReSukiSU successfully synchronized and adapted for Linux 4.14.357 + SUSFS 2.3.0."
