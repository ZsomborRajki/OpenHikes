#!/bin/bash
#
# Installs a pre-push hook that runs `Scripts/lint.sh`.
#
# Opt-in rather than committed into `.git/hooks` for you, because a hook is
# local state and nothing can install one on a clone by itself. Run it once:
#
#   Scripts/install-git-hooks.sh
#
# Skip the hook for a single push with `git push --no-verify`.
#
set -euo pipefail

cd "$(dirname "$0")/.."

hooks_dir="$(git rev-parse --git-path hooks)"
mkdir -p "$hooks_dir"
hook="$hooks_dir/pre-push"

if [[ -e "$hook" ]] && ! grep -q "OpenHikes lint hook" "$hook"; then
    echo "error: $hook already exists and was not written by this script." >&2
    echo "       Add 'Scripts/lint.sh' to it by hand, or move it aside." >&2
    exit 1
fi

cat > "$hook" <<'HOOK'
#!/bin/bash
# OpenHikes lint hook — installed by Scripts/install-git-hooks.sh
#
# The CI `quality` job runs this exact lint, so a violation caught here is a
# red `main` that never happened. Bypass with `git push --no-verify`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
if [[ ! -x "$repo/Scripts/lint.sh" ]]; then
    exit 0
fi

if ! "$repo/Scripts/lint.sh"; then
    echo >&2
    echo "Push aborted: SwiftLint --strict failed, and CI would fail the same way." >&2
    echo "Fix the violations, try 'Scripts/lint.sh --fix', or push with --no-verify." >&2
    exit 1
fi
HOOK

chmod +x "$hook"
echo "Installed pre-push hook at $hook."
