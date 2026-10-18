# A Linux shell with the docker CLI and compose v5.0.1 (the oldest compose on
# the boxes), for running the ci/ scripts from a Mac. See ci/in-box.sh.
# Both images are pinned by the digest of their multi-arch index. Dependabot
# does not read this file, so change the tag and the digest together by hand.
FROM docker:29.9.0-cli@sha256:1a4c7cb63513f349bdad01fcc6e0f3f2f67d37b9da86f14dc0d4a0942eecda00 AS docker

# noble is Ubuntu 24.04
FROM ubuntu:noble-20260917@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55
RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl git openssl python3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker
ARG COMPOSE_VERSION=v5.0.1
RUN set -eu; \
    url="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}"; \
    bin="docker-compose-linux-$(uname -m)"; \
    dir=/usr/local/libexec/docker/cli-plugins; \
    mkdir -p "$dir"; \
    curl -fsSL -o "/tmp/$bin" "$url/$bin"; \
    curl -fsSL "$url/checksums.txt" | grep " \*$bin\$" | sed 's/ \*/  \/tmp\//' | sha256sum -c -; \
    install -m 755 "/tmp/$bin" "$dir/docker-compose"; \
    rm "/tmp/$bin"
# The checkout belongs to the Mac user, the box runs as root
RUN git config --system --add safe.directory '*'
