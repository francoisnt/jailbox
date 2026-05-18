#!/bin/sh
set -e

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"

# TODO: This installer is not pinned to a specific version or checksum.
# The script is fetched from https://claude.ai/install.sh on every build.
# Until upstream provides versioned or checksummed releases this step
# cannot be made fully reproducible. Pin and verify when upstream supports it.

CLAUDE_INSTALL_SCRIPT=$(mktemp)
trap 'rm -f "$CLAUDE_INSTALL_SCRIPT"' EXIT

echo "Downloading Claude Code installer..."
if ! curl -fsSL https://claude.ai/install.sh -o "$CLAUDE_INSTALL_SCRIPT"; then
    echo "Error: failed to download Claude Code install script" >&2
    exit 1
fi

echo "Claude installer SHA256: $(sha256sum "$CLAUDE_INSTALL_SCRIPT" | cut -d' ' -f1)"

if [ -n "${CLAUDE_INSTALL_SHA256:-}" ]; then
    actual_sha256=$(sha256sum "$CLAUDE_INSTALL_SCRIPT" | cut -d' ' -f1)
    if [ "$actual_sha256" != "$CLAUDE_INSTALL_SHA256" ]; then
        echo "Error: Claude installer checksum mismatch" >&2
        echo "  expected: $CLAUDE_INSTALL_SHA256" >&2
        echo "  actual:   $actual_sha256" >&2
        exit 1
    fi
else
    echo "Warning: CLAUDE_INSTALL_SHA256 is not set; Claude installer is unpinned" >&2
fi

sh "$INSTALL_DIR/run-as-devuser.sh" "sh $CLAUDE_INSTALL_SCRIPT"
