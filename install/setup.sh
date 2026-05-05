#!/bin/sh
set -e

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"

# Portable /etc/passwd lookup — getent is absent on Alpine/busybox images.
get_passwd_entry() {
    if command -v getent >/dev/null 2>&1; then
        getent passwd devuser
    else
        grep '^devuser:' /etc/passwd || true
    fi
}

# ── Package manager ───────────────────────────────────────────────────────────
if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR=apt
elif command -v apk >/dev/null 2>&1; then
    PKG_MGR=apk
elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR=dnf
elif command -v yum >/dev/null 2>&1; then
    PKG_MGR=yum
else
    echo "Error: no supported package manager (apt-get, apk, dnf, yum)" >&2
    exit 1
fi

# ── Packages ──────────────────────────────────────────────────────────────────
# EXTRA_PACKAGES is intentionally unquoted — it is a space-separated list.
# shellcheck disable=SC2086
case "$PKG_MGR" in
    apt)
        apt-get update
        apt-get install -y openssh-server curl git procps ca-certificates
        [ -n "$EXTRA_PACKAGES" ] && apt-get install -y $EXTRA_PACKAGES
        apt-get clean && rm -rf /var/lib/apt/lists/*
        ;;
    apk)
        apk add --no-cache openssh curl git procps ca-certificates
        [ -n "$EXTRA_PACKAGES" ] && apk add --no-cache $EXTRA_PACKAGES
        ;;
    dnf)
        dnf install -y openssh-server curl git procps-ng ca-certificates
        [ -n "$EXTRA_PACKAGES" ] && dnf install -y $EXTRA_PACKAGES
        dnf clean all
        ;;
    yum)
        yum install -y openssh-server curl git procps ca-certificates
        [ -n "$EXTRA_PACKAGES" ] && yum install -y $EXTRA_PACKAGES
        yum clean all
        ;;
esac

# ── Validate sshd ─────────────────────────────────────────────────────────────
if ! command -v sshd >/dev/null 2>&1; then
    echo "Error: sshd not found after package installation" >&2
    exit 1
fi

# ── devuser ───────────────────────────────────────────────────────────────────
if id devuser >/dev/null 2>&1; then
    existing_uid=$(id -u devuser)
    if [ "$existing_uid" != "$USER_ID" ]; then
        echo "devuser exists with UID $existing_uid, expected $USER_ID — attempting to update..."
        if command -v usermod >/dev/null 2>&1; then
            usermod -u "$USER_ID" devuser
            # Best-effort: update ownership in common writable/application paths.
            for path in /home /root /var /opt /usr; do
                [ -d "$path" ] && find "$path" -xdev -user "$existing_uid" -exec chown -h "$USER_ID" {} \; 2>/dev/null || true
            done
        else
            echo "Error: devuser has UID $existing_uid but USER_ID=$USER_ID, and usermod is not available." >&2
            echo "Fix: use an image where devuser does not exist, or set USER_ID=$existing_uid in jailbox.conf." >&2
            exit 1
        fi
    fi
else
    if command -v useradd >/dev/null 2>&1; then
        useradd -m -u "$USER_ID" -s /bin/sh devuser
    elif command -v adduser >/dev/null 2>&1; then
        # Alpine-style adduser
        adduser -D -u "$USER_ID" -h /home/devuser -s /bin/sh devuser
    else
        echo "Error: cannot create devuser (no useradd or adduser)" >&2
        exit 1
    fi
fi

# Ensure a valid home directory
PASSWD_ENTRY=$(get_passwd_entry)
DEVUSER_HOME=$(printf '%s\n' "$PASSWD_ENTRY" | cut -d: -f6)
[ -z "$DEVUSER_HOME" ] && DEVUSER_HOME="/home/devuser"
mkdir -p "$DEVUSER_HOME"
chown devuser:devuser "$DEVUSER_HOME" 2>/dev/null || true
chmod 755 "$DEVUSER_HOME" 2>/dev/null || true

# Ensure a usable login shell
DEVUSER_SHELL=$(printf '%s\n' "$PASSWD_ENTRY" | cut -d: -f7)
[ -z "$DEVUSER_SHELL" ] && DEVUSER_SHELL="/bin/sh"
case "$DEVUSER_SHELL" in
    ""|/bin/false|/sbin/nologin|/usr/sbin/nologin)
        if command -v usermod >/dev/null 2>&1; then
            usermod -s /bin/sh devuser 2>/dev/null || true
        fi
        ;;
esac

# Refresh after any shell update above.
PASSWD_ENTRY=$(get_passwd_entry)
DEVUSER_SHELL=$(printf '%s\n' "$PASSWD_ENTRY" | cut -d: -f7)
[ -z "$DEVUSER_SHELL" ] && DEVUSER_SHELL="/bin/sh"
if ! [ -x "$DEVUSER_SHELL" ]; then
    if [ -x /bin/sh ]; then
        usermod -s /bin/sh devuser 2>/dev/null || true
    fi
fi

# SSH directory
mkdir -p "$DEVUSER_HOME/.ssh"
chmod 700 "$DEVUSER_HOME/.ssh"
chown -R devuser:devuser "$DEVUSER_HOME/.ssh"

# ── AI tools ──────────────────────────────────────────────────────────────────
# AI_TOOLS is intentionally unquoted — it is a space-separated list.
# shellcheck disable=SC2086
for tool in $AI_TOOLS; do
    case "$tool" in
        *[!A-Za-z0-9._-]*|"")
            echo "Error: invalid AI tool name: $tool" >&2
            exit 1
            ;;
    esac
    if [ ! -f "$INSTALL_DIR/${tool}.sh" ]; then
        echo "Error: AI tool installer not found: $INSTALL_DIR/${tool}.sh" >&2
        exit 1
    fi
    echo "Installing AI tool: $tool"
    sh "$INSTALL_DIR/${tool}.sh"
done

# ── sshd hardening ────────────────────────────────────────────────────────────
# Generate host keys for any missing algorithm.
ssh-keygen -A

# Write jailbox settings to a dedicated file and include it at the end of
# sshd_config. The Include is appended last, so our file is processed after
# all existing settings, giving it final precedence.
#
# Both ChallengeResponseAuthentication (pre-8.7) and
# KbdInteractiveAuthentication (8.7+) are set to cover all OpenSSH versions.
cat > /etc/ssh/jailbox_sshd_config << 'EOF'
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
UsePAM no
AllowUsers devuser
EOF

printf '\nInclude /etc/ssh/jailbox_sshd_config\n' >> /etc/ssh/sshd_config
