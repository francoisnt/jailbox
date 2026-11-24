# Dev image for working on jailbox itself (inside jailbox — no nested podman).
FROM debian:trixie

# ShellCheck: lints every shell script (scripts/lint.sh and the dev gate).
COPY --from=docker.io/koalaman/shellcheck:v0.11.0 /bin/shellcheck /usr/local/bin/shellcheck
# Go: builds the helper programs; includes gofmt and go vet. Use the latest
# patch of the Go series named in src/go.mod; scripts/apply-updates.sh
# updates this line together with src/go.mod.
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
        # Bash 4.4 or newer: host modules, scripts, and tests.
        bash \
        # TLS root certificates for curl and git over HTTPS.
        ca-certificates \
        # Dependency version lookups and downloads (scripts/plan-updates.sh).
        curl \
        # Tests and repository tooling.
        python3 \
        # Everyday work and the Git-based test fixtures.
        git \
        # JSON parsing in the dependency version lookups.
        jq \
        # Runs `just update` (justfile).
        just \
        # SSH client for everyday work.
        openssh-client \
    && rm -rf /var/lib/apt/lists/*
