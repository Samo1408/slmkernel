#!/bin/sh
# Validate the unmodified upstream submodule; all adaptation lives in the kernel.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
KSU="$ROOT/KernelSU"

# ---------------------------------------------------------------------------
# Mode
#   --strict (default): any warning becomes a failure (original behaviour)
#   --loose           : warnings are printed but the script exits 0
# ---------------------------------------------------------------------------
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

# NOTE: keep each assignment on its own line. Writing
#   local pattern=$1 msg=${3:-"...$pattern..."}
# expands $pattern BEFORE it is defined, which fails under `set -u`.
check_grep() {
  local pattern file msg
  pattern=$1
  file=$2
  msg=${3:-"pattern not found: $pattern in $file"}
  grep -q -- "$pattern" "$file" || warn "$msg"
}

check_grep_absent() {
  local pattern file msg
  pattern=$1
  file=$2
  msg=${3:-"unexpected match: $pattern in $file"}
  if grep -qE -- "$pattern" "$file"; then
    warn "$msg"
  fi
}

# ---------------------------------------------------------------------------
# 1. Worktree must be pristine. This stays fatal: running the API checks
#    against locally modified sources is meaningless.
# ---------------------------------------------------------------------------
git -C "$KSU" rev-parse --verify HEAD >/dev/null
source_status=$(git -C "$KSU" status --porcelain --untracked-files=normal)
if [ -n "$source_status" ]; then
  echo "BakaSU must match its upstream commit; preserve local edits before building" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. API used by fs/bakasu_preinit.h. A full clean build is still required
#    to validate a new upstream implementation.
# ---------------------------------------------------------------------------
check_grep 'int ksu_setup_preinit_file(struct filename \*\*filename_ptr, struct user_arg_ptr \*argv_user)' \
  "$KSU/kernel/preinit/preinit.c" \
  "BakaSU SUSFS preinit setup API changed; review the kernel adapter"

check_grep 'KSU_SYSCALL_NO_TARGET :=' \
  "$KSU/kernel/tools/code_generation/syscall_no/syscall_no.mk" \
  "BakaSU syscall generator changed; review the kernel build dependency"

[ -s "$KSU/kernel/preinit/runner/runner.c" ] \
  || warn "missing or empty: $KSU/kernel/preinit/runner/runner.c"

[ -s "$KSU/kernel/tools/code_generation/preinit_runner/preinit_runner.mk" ] \
  || warn "missing or empty: $KSU/kernel/tools/code_generation/preinit_runner/preinit_runner.mk"

# ---------------------------------------------------------------------------
# 3. Upstream detection disables all automatic SELinux hooks. Require the
#    complete parent-side set so a partial port cannot silently disable hiding.
# ---------------------------------------------------------------------------
check_grep 'susfs_selinux_setprocattr' "$ROOT/security/selinux/hooks.c"

for hook in susfs_sel_write_context susfs_sel_write_access initialize_fake_status \
            fake_status_initialize_key ksu_selinux_hide_running; do
  check_grep "$hook" "$ROOT/security/selinux/selinuxfs.c"
done

check_grep 'ksu_selinux_hide_running' "$ROOT/security/selinux/hooks.c"

# ---------------------------------------------------------------------------
# 4. KernelSU feature markers that the parent adapter depends on.
# ---------------------------------------------------------------------------
check_grep 'KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE' \
  "$KSU/kernel/tools/susfs_compat.mk"

check_grep '#define __maybe_static$' \
  "$KSU/kernel/feature/selinux_hide/selinux_hide.c"

check_grep 'int ksu_handle_sys_read(unsigned int fd, char __user \*\*buf_ptr, size_t \*count_ptr)' \
  "$KSU/kernel/runtime/ksud_integration.c"

check_grep 'KSU_INSTALL_MAGIC1, 0xDEADBEEF' \
  "$KSU/kernel/include/uapi/supercall.h"

for api in my_write_context my_write_access my_setprocattr initialize_fake_status; do
  check_grep "$api" "$KSU/kernel/feature/selinux_hide/selinux_hide.c"
done

# ---------------------------------------------------------------------------
# 5. Reverse check: upstream must NOT introduce native priority UID support,
#    because that would conflict with the parent adapter.
# ---------------------------------------------------------------------------
check_grep_absent 'CMD_SUSFS_SET_PRIORITY_UID_FILTER|susfs_parse_priority_app_strings' \
  "$KSU/kernel/supercall/dispatch.c" \
  "BakaSU now has native priority UID integration; review the parent adapter before updating"

check_grep_absent 'CMD_SUSFS_SET_PRIORITY_UID_FILTER|susfs_parse_priority_app_strings' \
  "$KSU/kernel/manager/pkg_observer.c" \
  "BakaSU now has native priority UID integration; review the parent adapter before updating"

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
printf 'BakaSU upstream: %s\n' "$(git -C "$KSU" rev-parse HEAD)"
printf 'BakaSU worktree: clean\n'

if [ "$warnings" -gt 0 ]; then
  printf 'BakaSU checks: %d warning(s)\n' "$warnings"
  if [ "$strict" -eq 1 ]; then
    exit 1
  fi
  printf 'BakaSU checks: continuing in non-strict mode\n'
  exit 0
fi

printf 'BakaSU integration: parent-kernel preinit, manual SELinux and SUSFS command adapters; no submodule patches\n'
printf 'SUSFS priority UID source: simonpunk gki-android12-5.10 eb95da080c76724c4962d0c62e9af3be37d9d439\n'
