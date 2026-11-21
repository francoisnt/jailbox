# Dev image for working on jailbox itself (inside jailbox — no nested podman).
# shellcheck for scripts/lint.sh, Go for the helper programs (gofmt and go vet
# included), jq + curl for the canary version resolver, python3 for tests and
# tooling, git and ssh client for everyday work.
FROM debian:trixie

COPY --from=docker.io/koalaman/shellcheck:v0.11.0 /bin/shellcheck /usr/local/bin/shellcheck
# Use the latest patch of the Go series named in src/go.mod.
COPY --from=docker.io/library/golang:1.27-trixie /usr/local/go /usr/local/go

# jailbox sessions arrive over SSH, which does not pass image ENV settings on.
# Link Go into the default PATH and set its defaults in Go's own config file:
# use only the installed toolchain and build static programs without a C
# compiler. Module and build caches live in the writable home.
RUN ln -s /usr/local/go/bin/go /usr/local/go/bin/gofmt /usr/local/bin/ \
    && sed -i 's/^GOTOOLCHAIN=.*/GOTOOLCHAIN=local/' /usr/local/go/go.env \
    && printf 'CGO_ENABLED=0\n' >> /usr/local/go/go.env \
    && grep -qx 'GOTOOLCHAIN=local' /usr/local/go/go.env

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        python3 \
        git \
        jq \
        openssh-client \
    && rm -rf /var/lib/apt/lists/*
