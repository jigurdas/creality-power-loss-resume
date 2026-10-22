#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
MODULE="$ROOT/klipper/plr_prompt.py"
CFG="$ROOT/klipper/plr.cfg"

sh -n "$ROOT/install.sh" "$ROOT/uninstall.sh"
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$MODULE"
git -C "$ROOT" diff --check

grep -q '^\[plr_prompt\]' "$CFG"
for cmd in PLR_CHECK PLR_RESUME PLR_DISCARD; do
    grep -q "register_command(\"$cmd\"" "$MODULE"
done
# Guppy Screen keeps old buttons until prompt_end
grep -q '"prompt_end",' "$MODULE"
grep -q 'ISCONTINUEPRINT' "$MODULE"

echo "Validation passed"
