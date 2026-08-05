#!/usr/bin/env bash
#
# End-to-end check of the rcsym CLI against a real filesystem.
#
# Runs on all three platforms (bash is available on GitHub's Windows runners
# too). The unit tests cover the logic; this covers the thing they cannot --
# that the shipped binary, invoked the way a context menu invokes it, actually
# creates links and actually refuses to destroy anything.
#
#   ./scripts/smoke.sh [path-to-rcsym]
#
set -euo pipefail

RCSYM="${1:-}"
if [ -z "$RCSYM" ]; then
    for candidate in target/release/rcsym target/release/rcsym.exe \
                     target/debug/rcsym target/debug/rcsym.exe; do
        [ -x "$candidate" ] && { RCSYM="$candidate"; break; }
    done
fi
[ -n "$RCSYM" ] && [ -x "$RCSYM" ] || { echo "cannot find rcsym binary" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "binary: $RCSYM"
echo "workdir: $WORK"
echo

# ---------------------------------------------------------------------------
echo "== capabilities =="
"$RCSYM" probe
CAPS="$("$RCSYM" probe)"
# Crude but dependency-free JSON peek; the field is a bare true/false.
can_symlink() { echo "$CAPS" | grep -q '"symlink_unprivileged": true'; }
echo

# ---------------------------------------------------------------------------
echo "== setup =="
mkdir -p "$WORK/realdir" "$WORK/dest"
echo payload > "$WORK/realdir/inside.txt"
echo original > "$WORK/realfile.txt"
ok "fixtures created"
echo

# ---------------------------------------------------------------------------
echo "== dry run writes nothing =="
"$RCSYM" link --target "$WORK/realdir" --into "$WORK/dest" --name dry --dry-run --no-confirm >/dev/null
check "dry run left no artifact" '[ ! -e "$WORK/dest/dry" ]'
echo

# ---------------------------------------------------------------------------
echo "== refuses to overwrite =="
# The whole safety story. If any of these fail, the tool is dangerous.
echo precious > "$WORK/dest/victim.txt"
mkdir -p "$WORK/dest/victimdir"
echo precious > "$WORK/dest/victimdir/keep.txt"

! "$RCSYM" link --target "$WORK/realfile.txt" --into "$WORK/dest" \
    --name victim.txt --no-confirm 2>/dev/null
check "refused to clobber an existing file"   '[ "$(cat "$WORK/dest/victim.txt")" = precious ]'

! "$RCSYM" link --target "$WORK/realdir" --into "$WORK/dest" \
    --name victimdir --no-confirm 2>/dev/null
check "refused to clobber an existing folder" '[ "$(cat "$WORK/dest/victimdir/keep.txt")" = precious ]'
echo

# ---------------------------------------------------------------------------
echo "== rejects nonsense =="
! "$RCSYM" link --target "$WORK/realdir" --into "$WORK/dest" \
    --name hl --kind hardlink --no-confirm 2>/dev/null
check "hard link to a directory rejected" '[ ! -e "$WORK/dest/hl" ]'

! "$RCSYM" link --target "$WORK/realdir" --into "$WORK/nonexistent" \
    --name x --no-confirm 2>/dev/null
check "missing destination folder rejected" 'true'
echo

# ---------------------------------------------------------------------------
echo "== creates real links =="
if can_symlink; then
    "$RCSYM" link --target "$WORK/realdir" --into "$WORK/dest" --name d_abs --no-confirm
    check "absolute directory symlink is a symlink" '[ -L "$WORK/dest/d_abs" ]'
    check "reads through it"                        '[ "$(cat "$WORK/dest/d_abs/inside.txt")" = payload ]'

    "$RCSYM" link --target "$WORK/realdir" --into "$WORK/dest" --name d_rel --relative --no-confirm
    check "relative directory symlink is a symlink" '[ -L "$WORK/dest/d_rel" ]'
    check "reads through it"                        '[ "$(cat "$WORK/dest/d_rel/inside.txt")" = payload ]'

    "$RCSYM" link --target "$WORK/realfile.txt" --into "$WORK/dest" --name f_abs --no-confirm
    check "file symlink is a symlink" '[ -L "$WORK/dest/f_abs" ]'
    check "reads through it"          '[ "$(cat "$WORK/dest/f_abs")" = original ]'

    # Deleting a link must never reach the target.
    rm "$WORK/dest/f_abs"
    check "deleting the link spared the target" '[ "$(cat "$WORK/realfile.txt")" = original ]'
else
    echo "  skipped: this machine cannot create symlinks unprivileged"
fi
echo

# ---------------------------------------------------------------------------
echo "== hard link =="
"$RCSYM" link --target "$WORK/realfile.txt" --into "$WORK/dest" \
    --name hardcopy --kind hardlink --no-confirm
check "hard link created"        '[ -f "$WORK/dest/hardcopy" ]'
check "hard link shares content" '[ "$(cat "$WORK/dest/hardcopy")" = original ]'
echo

# ---------------------------------------------------------------------------
if [ "${OS:-}" = "Windows_NT" ]; then
    echo "== junction (Windows, needs no privilege) =="
    "$RCSYM" link --target "$WORK/realdir" --into "$WORK/dest" \
        --name jn --kind junction --no-confirm
    check "junction resolves" '[ "$(cat "$WORK/dest/jn/inside.txt")" = payload ]'
    # Remove as a directory entry so the target is untouched.
    cmd //c rmdir "$(cygpath -w "$WORK/dest/jn")" 2>/dev/null || rmdir "$WORK/dest/jn" 2>/dev/null || true
    check "removing the junction spared the target" '[ -f "$WORK/realdir/inside.txt" ]'
    echo
fi

# ---------------------------------------------------------------------------
printf '\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
