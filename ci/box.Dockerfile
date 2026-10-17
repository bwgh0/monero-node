# A Linux shell with the docker CLI and compose v5.0.1 (the oldest compose on
# the boxes), for running the ci/ scripts from a Mac. See ci/in-box.sh.
FROM docker:29-cli AS docker

FROM ubuntu:24.04
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
