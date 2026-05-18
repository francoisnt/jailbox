#!/bin/sh
set -e

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"

if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y python3 python3-pip && apt-get clean && rm -rf /var/lib/apt/lists/*
elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache python3 py3-pip
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3 python3-pip && dnf clean all
elif command -v yum >/dev/null 2>&1; then
    yum install -y python3 python3-pip && yum clean all
else
    echo "Error: no supported package manager" >&2
    exit 1
fi

if [ -n "${AIDER_VERSION:-}" ]; then
    AIDER_PACKAGE="aider-chat==$AIDER_VERSION"
else
    AIDER_PACKAGE="aider-chat"
    echo "Warning: AIDER_VERSION is not set; installing latest aider-chat" >&2
fi

# --break-system-packages is required on newer distros (PEP 668).
# Fall back for older pip that doesn't recognise the flag.
sh "$INSTALL_DIR/run-as-devuser.sh" \
    "pip3 install --user --break-system-packages \"$AIDER_PACKAGE\" 2>/dev/null || pip3 install --user \"$AIDER_PACKAGE\""
