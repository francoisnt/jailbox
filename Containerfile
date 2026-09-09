# Dev image for working on jailbox itself (inside jailbox — no nested podman).
# shellcheck for scripts/lint.sh, jq + curl for the canary version resolver,
# git and ssh client for everyday work.
FROM debian:trixie

COPY --from=docker.io/koalaman/shellcheck:v0.11.0 /bin/shellcheck /usr/local/bin/shellcheck

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        jq \
        openssh-client \
    && rm -rf /var/lib/apt/lists/*
