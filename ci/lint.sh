#!/usr/bin/env bash
# Runs shellcheck on every shell script, actionlint on the workflows and a
# compile check on the Python scripts. Needs only docker and git.
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

mapfile -t pyscripts < <(git ls-files --cached --others --exclude-standard '*.py')
echo "==> python compile check: ${#pyscripts[@]} scripts"
if ((${#pyscripts[@]})); then
    # Python 3.12 is the version on the boxes (Ubuntu 24.04)
    docker run --rm -v "$root:/mnt:ro" -w /mnt -e PYTHONDONTWRITEBYTECODE=1 python:3.12-slim \
        python3 -c 'import ast, sys
for f in sys.argv[1:]:
    ast.parse(open(f, encoding="utf-8").read(), f)' "${pyscripts[@]}"
fi
echo "ok"
