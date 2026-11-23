#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
KSU="$ROOT/KernelSU"

# ---- الوضع ----
# strict=1 : كل تحذير يصبح خروجاً بالفشل (السلوك الأصلي)
# strict=0 : التحذيرات تُطبع فقط ويستمر السكربت
strict=1
for arg in "$@"; do
  case "$arg" in
    --check)  ;;
    --strict) strict=1 ;;
    --loose)  strict=0 ;;
    *) echo "Usage: $0 [--check] [--strict|--loose]" >&2; exit 2 ;;
  esac
done

warnings=0
warn() {
  echo "WARN: $*" >&2
  warnings=$((warnings + 1))
}

check_grep() {
  local pattern=$1 file=$2 msg=${3:-"pattern not found: $pattern in $file"}
  grep -q -- "$pattern" "$file" || warn "$msg"
}

check_grep_absent() {
  local pattern=$1 file=$2 msg=${3:-"unexpected match: $pattern in $file"}
  grep -qE -- "$pattern" "$file" && warn "$msg" || true
}

# ---- 1. شجرة العمل: يبقى شرطاً قاطعاً (لا معنى للاستمرار بدونها) ----
git -C "$KSU" rev-parse --verify HEAD >/dev/null
source_status=$(git -C "$KSU" status --porcelain --untracked-files=normal)
if [ -n "$source_status" ]; then
  echo "BakaSU must match its upstream commit; preserve local edits before building" >&2
  exit 1
fi

# ---- 2. فحوصات API: تحذيرات فقط ----
check_grep 'int ksu_setup_preinit_file(struct filename \*\*filename_ptr, struct user_arg_ptr \*argv_user)' \
  "$KSU/kernel/preinit/preinit.c" \
  "SUSFS preinit setup API changed; review fs/bakasu_preinit.h adapter"

check_grep 'KSU_SYSCALL_NO_TARGET :=' \
  "$KSU/kernel/tools/code_generation/syscall_no/syscall_no.mk" \
  "syscall generator changed; review kernel build dependency"

[ -s "$KSU/kernel/preinit/runner/runner.c" ] || warn "missing preinit runner.c"
[ -s "$KSU/kernel/tools/code_generation/preinit_runner/preinit_runner.mk" ] \
  || warn "missing preinit_runner.mk"

# ---- 3. خطّافات SELinux ----
check_grep 'susfs_selinux_setprocattr' "$ROOT/security/selinux/hooks.c"

for hook in susfs_sel_write_context susfs_sel_write_access initialize_fake_status \
            fake_status_initialize_key ksu_selinux_hide_running; do
  check_grep "$hook" "$ROOT/security/selinux/selinuxfs.c"
done

check_grep 'ksu_selinux_hide_running' "$ROOT/security/selinux/hooks.c"

# ---- 4. علامات ميزة KernelSU ----
check_grep 'KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE' "$KSU/kernel/tools/susfs_compat.mk"
check_grep '#define __maybe_static$' "$KSU/kernel/feature/selinux_hide/selinux_hide.c"
check_grep 'int ksu_handle_sys_read(unsigned int fd, char __user \*\*buf_ptr, size_t \*count_ptr)' \
  "$KSU/kernel/runtime/ksud_integration.c"
check_grep 'KSU_INSTALL_MAGIC1, 0xDEADBEEF' "$KSU/kernel/include/uapi/supercall.h"

for api in my_write_context my_write_access my_setprocattr initialize_fake_status; do
  check_grep "$api" "$KSU/kernel/feature/selinux_hide/selinux_hide.c"
done

# ---- 5. تكامل priority UID الأصلي (فحص عكسي) ----
check_grep_absent 'CMD_SUSFS_SET_PRIORITY_UID_FILTER|susfs_parse_priority_app_strings' \
  "$KSU/kernel/supercall/dispatch.c"
check_grep_absent 'CMD_SUSFS_SET_PRIORITY_UID_FILTER|susfs_parse_priority_app_strings' \
  "$KSU/kernel/manager/pkg_observer.c"

# ---- التقرير النهائي ----
printf 'BakaSU upstream: %s\n' "$(git -C "$KSU" rev-parse HEAD)"
printf 'BakaSU worktree: clean\n'

if [ "$warnings" -gt 0 ]; then
  printf 'BakaSU checks: %d warning(s)\n' "$warnings"
  if [ "$strict" -eq 1 ]; then
    exit 1
  fi
  printf 'BakaSU checks: continuing in non-strict mode\n'
else
  printf 'BakaSU integration: parent-kernel preinit, manual SELinux and SUSFS command adapters; no submodule patches\n'
  printf 'SUSFS priority UID source: simonpunk gki-android12-5.10 eb95da080c76724c4962d0c62e9af3be37d9d439\n'
fi
