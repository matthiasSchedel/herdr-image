#!/usr/bin/env bash
# Copy the skill out of the private fleet checkout and rewrite the few paths
# that differ: the fleet keeps the tool under personal/matthias and its tests
# beside the skill, this repo keeps both at the root.
set -euo pipefail
src="${1:?usage: sync-from-fleet.sh <fleet-checkout>/personal/matthias}"
root="$(cd -P "$(dirname "$0")" && pwd -P)"
cp "$src/bin/image" "$src/bin/agent-shot" "$root/bin/"
cp "$src/skills/show-image/SKILL.md" "$root/skills/show-image/SKILL.md"
cp "$src/skills/show-image/scripts/"*.sh "$src/skills/show-image/scripts/"*.py "$root/skills/show-image/scripts/"
cp "$src/skills/show-image/tests/"*.sh "$root/tests/"
for test in "$root"/tests/*.sh; do
  perl -0pi -e 's{REPO_ROOT="\$\(cd -P "\$SKILL_DIR/\.\./\.\./\.\./\.\." && pwd -P\)"}{REPO_ROOT="\$(cd -P "\$(dirname "\$0")/.." && pwd -P)"}g;
                 s{SKILL_DIR="\$\(cd -P "\$\(dirname "\$0"\)/\.\." && pwd -P\)"}{REPO_ROOT="\$(cd -P "\$(dirname "\$0")/.." && pwd -P)"\nSKILL_DIR="\$REPO_ROOT/skills/show-image"}g;
                 s{\$REPO_ROOT/personal/matthias/bin/image}{\$REPO_ROOT/bin/image}g;
                 s{\$SKILL_DIR/\.\./img/scripts/img\.sh}{\$REPO_ROOT/skills/img/scripts/img.sh}g;
                 s{\$REPO_ROOT/personal/matthias/bin/_image}{\$REPO_ROOT/bin/_image}g' "$test"
done
chmod +x "$root/bin/image" "$root/bin/agent-shot" "$root"/skills/*/scripts/* "$root"/tests/*.sh
