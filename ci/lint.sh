#!/usr/bin/env bash
# Runs shellcheck on every shell script, actionlint on the workflows, a
# compile check on the Python scripts and a digest check on the images.
# Needs only docker and git.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root"

# The tool images are pinned by the digest of their multi-arch index, as the
# digest check below wants. Dependabot does not read this file, so change
# the tag and the digest together by hand.
mapfile -t scripts < <(git ls-files --cached --others --exclude-standard '*.sh')
((${#scripts[@]})) || { echo "no shell scripts found"; exit 1; }
echo "==> shellcheck: ${#scripts[@]} scripts"
docker run --rm -v "$root:/mnt:ro" -w /mnt \
    koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d \
    --external-sources "${scripts[@]}"
echo "ok"

echo "==> actionlint (with shellcheck for the run: blocks)"
docker run --rm -v "$root:/repo:ro" -w /repo \
    rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 -color
echo "ok"

mapfile -t pyscripts < <(git ls-files --cached --others --exclude-standard '*.py')
echo "==> python compile check: ${#pyscripts[@]} scripts"
if ((${#pyscripts[@]})); then
    # Python 3.12 is the version on the boxes (Ubuntu 24.04)
    docker run --rm -v "$root:/mnt:ro" -w /mnt -e PYTHONDONTWRITEBYTECODE=1 \
        python:3.12-slim@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1 \
        python3 -c 'import ast, sys
for f in sys.argv[1:]:
    ast.parse(open(f, encoding="utf-8").read(), f)' "${pyscripts[@]}"
fi
echo "ok"

# Each image must name the digest of its multi-arch index, so a moved or
# hijacked tag cannot change what runs. The check reads the image: lines of
# the compose files, the FROM lines of the Dockerfiles, and the docker run,
# create and pull commands in ci/*.sh and scripts/*.sh. Dependabot updates
# the tag and the digest of the compose images together.
mapfile -t composefiles < <(git ls-files --cached --others --exclude-standard '*compose*.yml' '*compose*.yaml')
((${#composefiles[@]})) || { echo "no compose files found"; exit 1; }
mapfile -t dockerfiles < <(git ls-files --cached --others --exclude-standard '*Dockerfile*' '*.dockerfile')
mapfile -t shfiles < <(git ls-files --cached --others --exclude-standard 'ci/*.sh' 'scripts/*.sh')
echo "==> image digests: ${#composefiles[@]} compose files, ${#dockerfiles[@]} Dockerfiles, ${#shfiles[@]} scripts"
images=0 unpinned=0
check_pin() { # <file> <line> <image>
    images=$((images + 1))
    if [[ ! $3 =~ @sha256:[0-9a-f]{64}$ ]]; then
        echo "$1:$2: $3 has no full @sha256: digest. Pin it by the digest of its multi-arch index."
        unpinned=$((unpinned + 1))
    fi
}

re="^[[:space:]]*image:[[:space:]]*[\"']?([^\"'[:space:]]+)"
while IFS=: read -r file line text; do
    [[ $text =~ $re ]] || continue
    check_pin "$file" "$line" "${BASH_REMATCH[1]}"
done < <(grep -nH -E '^[[:space:]]*image:' "${composefiles[@]}")

# FROM [--platform=<platform>] <image> [AS <stage>]. scratch and the name of
# an earlier stage are not images.
for file in "${dockerfiles[@]}"; do
    stages=" scratch "
    while IFS=: read -r line text; do
        read -ra words <<<"$text"
        i=1
        while [[ ${words[i]:-} == --* ]]; do i=$((i + 1)); done
        image=${words[i]:-}
        [[ -z $image || $stages == *" ${image,,} "* ]] || check_pin "$file" "$line" "$image"
        if [[ ${words[i + 1]:-} =~ ^[Aa][Ss]$ ]]; then
            stage=${words[i + 2]:-}
            stages+="${stage,,} "
        fi
    done < <(grep -n -i -E '^[[:space:]]*FROM[[:space:]]' "$file")
done

# The image of a docker run, create or pull command is the first word after
# the flags. The flags in these lists take no value, and each other flag
# takes one. An image in a variable is not checked here: it comes from a
# compose file or from a local build.
run_bools=" -d -i -P -q -t --detach --help --init --interactive --no-healthcheck --oom-kill-disable --privileged --publish-all --quiet --read-only --rm --sig-proxy --tty --use-api-socket "
pull_bools=" -a -q --all-tags --quiet "
while IFS=$'\t' read -r file line cmd; do
    read -ra words <<<"$cmd"
    for ((i = 0; i + 1 < ${#words[@]}; i++)); do
        [[ ${words[i]##*[\(\`]} == docker && ${words[i + 1]} =~ ^(run|create|pull)$ ]] || continue
        bools=$run_bools
        [[ ${words[i + 1]} != pull ]] || bools=$pull_bools
        for ((j = i + 2; j < ${#words[@]}; j++)); do
            case ${words[j]} in
                --*=* | -[!-]?*) ;; # the value in the same word, or short flags together (-it)
                -*) [[ $bools == *" ${words[j]} "* ]] || j=$((j + 1)) ;;
                *) break ;;
            esac
        done
        image=${words[j]:-}
        image=${image//[\"\']/}
        [[ -z $image || $image == *'$'* ]] || check_pin "$file" "$line" "$image"
    done
done < <(awk '
    FNR == 1 { cont = 0 }
    !cont && /^[[:space:]]*#/ { next }
    {
        if (cont) buf = buf " " $0; else { buf = $0; start = FNR }
        cont = sub(/\\$/, "", buf)
        if (!cont && buf ~ /docker/) print FILENAME "\t" start "\t" buf
    }' "${shfiles[@]}")

((images)) || { echo "no images found"; exit 1; }
((unpinned == 0)) || exit 1
echo "ok, $images images"
