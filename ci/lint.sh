#!/usr/bin/env bash
# Runs shellcheck on every shell script and actionlint on the workflows.
# Needs only docker and git.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root"

mapfile -t scripts < <(git ls-files --cached --others --exclude-standard '*.sh')
((${#scripts[@]})) || { echo "no shell scripts found"; exit 1; }
echo "==> shellcheck: ${#scripts[@]} scripts"
docker run --rm -v "$root:/mnt:ro" -w /mnt koalaman/shellcheck:v0.11.0 \
    --external-sources "${scripts[@]}"
echo "ok"

echo "==> actionlint (with shellcheck for the run: blocks)"
docker run --rm -v "$root:/repo:ro" -w /repo rhysd/actionlint:1.7.12 -color
echo "ok"
