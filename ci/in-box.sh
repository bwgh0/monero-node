#!/usr/bin/env bash
# Runs a ci/ script in a Linux container that drives the local Docker.
# The ci/ scripts need Linux tools and bash 5, so a Mac runs them this way:
#   CI_WORKDIR=<dir> ci/in-box.sh ci/smoke.sh
# CI_WORKDIR must be a directory that Docker can bind mount at the same path.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
work=${CI_WORKDIR:?set CI_WORKDIR to a directory that Docker can bind mount}
mkdir -p "$work"
work=$(cd "$work" && pwd -P)
image=monero-node-ci-box:local
# A git worktree keeps its objects in the main checkout. Mount that too.
common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)

# The box is native. It runs the stack images as amd64.
DOCKER_DEFAULT_PLATFORM='' docker build -q -t "$image" -f "$root/ci/box.Dockerfile" "$root/ci" >/dev/null
exec docker run --rm --network host \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$root:$root" -v "$common:$common" -v "$work:$work" -w "$root" \
    -e SMOKE_WORKDIR="$work" -e SIM_WORKDIR="$work" \
    -e DOCKER_DEFAULT_PLATFORM="${DOCKER_DEFAULT_PLATFORM:-linux/amd64}" \
    "$image" bash "$@"
