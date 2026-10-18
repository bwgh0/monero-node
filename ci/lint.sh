#!/usr/bin/env bash
# Runs shellcheck on every shell script, actionlint on the workflows, a
# compile check on the Python scripts and a digest check on the compose
# images. Needs only docker and git.
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

# Each image must name the digest of its multi-arch index, so a moved or
# hijacked tag cannot change what runs. Dependabot updates the tag and the
# digest together.
mapfile -t composefiles < <(git ls-files --cached --others --exclude-standard '*compose*.yml' '*compose*.yaml')
((${#composefiles[@]})) || { echo "no compose files found"; exit 1; }
echo "==> image digests: ${#composefiles[@]} compose files"
re="^[[:space:]]*image:[[:space:]]*[\"']?([^\"'[:space:]]+)"
images=0 unpinned=0
while IFS=: read -r file line text; do
    [[ $text =~ $re ]] || continue
    image=${BASH_REMATCH[1]}
    images=$((images + 1))
    if [[ ! $image =~ @sha256:[0-9a-f]{64}$ ]]; then
        echo "$file:$line: $image has no full @sha256: digest. Pin it by the digest of its multi-arch index."
        unpinned=$((unpinned + 1))
    fi
done < <(grep -nH -E '^[[:space:]]*image:' "${composefiles[@]}")
((images)) || { echo "no image: lines found"; exit 1; }
((unpinned == 0)) || exit 1
echo "ok, $images images"
