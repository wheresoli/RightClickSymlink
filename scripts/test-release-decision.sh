#!/usr/bin/env bash
#
# Test the release workflow's "should we publish?" decision.
#
# That logic decides whether binaries reach users. It has grown several
# interacting rules -- skip markers, a force marker, path filtering, a manual
# escape hatch -- and getting it wrong is either a silent failure to ship or an
# unintended publish. Neither shows up in a normal test run, so it gets its own.
#
# The step is extracted straight out of .github/workflows/release.yml, so this
# tests the shipped logic rather than a copy of it that can drift. `git` is
# stubbed to feed it whatever scenario each case needs.
#
#   ./scripts/test-release-decision.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Pull the real step out of the workflow.
# ---------------------------------------------------------------------------

# `python3` on Windows is often the Microsoft Store stub, which exits without
# running anything. Prefer a python that actually works.
PY_BIN=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "import yaml" >/dev/null 2>&1; then
        PY_BIN="$candidate"
        break
    fi
done
if [ -z "$PY_BIN" ]; then
    echo "need a python with PyYAML installed (pip install pyyaml)" >&2
    exit 1
fi

"$PY_BIN" - "$ROOT" "$WORK" <<'PY'
import pathlib, sys, yaml
root, work = sys.argv[1], sys.argv[2]
wf = yaml.safe_load(open(f"{root}/.github/workflows/release.yml", encoding="utf-8"))
for step in wf["jobs"]["decide"]["steps"]:
    if step.get("name") == "Decide":
        pathlib.Path(f"{work}/decide.sh").write_text(step["run"], encoding="utf-8")
        break
else:
    raise SystemExit("could not find the Decide step in release.yml")
PY

# ---------------------------------------------------------------------------
# A git that answers from the environment.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/git" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  rev-parse)
    # `rev-parse HEAD` resolves; `rev-parse v1.2.3` must fail, otherwise the
    # decider thinks the tag already exists and bails.
    [ "$2" = "HEAD" ] && { echo deadbeefdeadbeef; exit 0; }
    exit 1 ;;
  log)  printf '%s\n' "${MOCK_SUBJECT:-}" ;;
  tag)  [ -n "${MOCK_LATEST:-}" ] && printf '%s\n' "$MOCK_LATEST" ;;
  diff) [ -n "${MOCK_CHANGED:-}" ] && printf '%s\n' "$MOCK_CHANGED" ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/git"

# ---------------------------------------------------------------------------
# case <name> <expect release|hold> <subject> <changed files> [manual]
# ---------------------------------------------------------------------------
run_case() {
    local name="$1" expect="$2" subject="$3" changed="$4" manual="${5:-false}"

    : > "$WORK/out"
    : > "$WORK/summary"

    local got
    if ( cd "$ROOT" \
         && PATH="$WORK/bin:$PATH" \
            GITHUB_OUTPUT="$WORK/out" \
            GITHUB_STEP_SUMMARY="$WORK/summary" \
            MOCK_SUBJECT="$subject" \
            MOCK_LATEST="v0.1.1" \
            MOCK_CHANGED="$changed" \
            OVERRIDE="" \
            MANUAL="$manual" \
            bash "$WORK/decide.sh" >/dev/null 2>&1 ); then
        if grep -q '^release=true' "$WORK/out"; then got=release; else got=hold; fi
    else
        got="error"
    fi

    if [ "$got" = "$expect" ]; then
        PASS=$((PASS + 1))
        printf '  \033[32mok\033[0m   %-46s -> %s\n' "$name" "$got"
    else
        FAIL=$((FAIL + 1))
        printf '  \033[31mFAIL\033[0m %-46s -> %s (wanted %s)\n' "$name" "$got" "$expect"
    fi
}

echo "release decision"
echo

# Things that should ship.
run_case "source change"              release "Fix the junction path"      "crates/symlink-core/src/plan.rs"
run_case "source + dependency"        release "Add a feature"              "Cargo.toml
Cargo.lock
crates/rcsym/src/ui.rs"
run_case "installer change"           release "Fix the installer"          "install.ps1"

# Things that should not.
run_case "docs only"                  hold    "Tidy the README"            "README.md
platform/linux/README.md"
run_case "CI only"                    hold    "Speed up CI"                ".github/workflows/ci.yml"
run_case "explicit skip marker"       hold    "Release v0.1.2 [skip release]" "crates/rcsym/src/ui.rs"
run_case "nothing changed"            hold    "Empty"                      ""

# The new rule: dependency bumps merge, but do not publish by themselves.
run_case "dependency bump alone"      hold    "Bump rfd from 0.17 to 0.18" "Cargo.toml
Cargo.lock"
run_case "lockfile alone"             hold    "Bump transitive dep"        "Cargo.lock"

# The two escape hatches.
run_case "forced with [release]"      release "Ship the dep updates [release]" "Cargo.toml
Cargo.lock"
run_case "manual dispatch"            release "Bump rfd from 0.17 to 0.18" "Cargo.toml
Cargo.lock" true
run_case "manual beats skip marker"   release "Whatever [skip release]"    "README.md" true

# "[skip release]" must not be read as containing "[release]".
run_case "skip marker is not a force" hold    "Release v0.2.0 [skip release]" "Cargo.toml
Cargo.lock"

echo
printf '\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
