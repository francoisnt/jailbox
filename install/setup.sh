#!/bin/sh
set -e

# Portable /etc/passwd lookup — getent is absent on Alpine/busybox images.
get_passwd_entry() {
    if command -v getent >/dev/null 2>&1; then
        getent passwd "$DEV_USER"
    else
        grep "^${DEV_USER}:" /etc/passwd || true
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
# Baseline follows VS Code Remote Development Linux prerequisites:
# https://code.visualstudio.com/docs/remote/linux#_remote-host-container-wsl-linux-prerequisites
#
# Remote - SSH needs an OpenSSH server, bash, and curl or wget. The VS Code
# server runtime also needs the listed libc/libstdc++ runtime packages plus tar.
# Alpine support is preview/limited upstream; the extra VSCodium REH packages
# cover native modules present in current vscodium-reh-alpine archives.
case "$PKG_MGR" in
    apt)
        apt-get update
        apt-get install -y \
            openssh-server bash curl git procps ca-certificates tar \
            libc6 libstdc++6
        apt-get clean && rm -rf /var/lib/apt/lists/*
        ;;
    apk)
        apk add --no-cache \
            openssh bash curl git procps ca-certificates tar shadow \
            musl libgcc libstdc++ \
            gcompat krb5-libs webkit2gtk-4.1
        ;;
    dnf)
        dnf install -y \
            openssh-server bash curl git procps-ng ca-certificates tar \
            glibc libgcc libstdc++
        dnf clean all
        ;;
    yum)
        yum install -y \
            openssh-server bash curl git procps ca-certificates tar \
            glibc libgcc libstdc++
        yum clean all
        ;;
esac

# ── Validate sshd ─────────────────────────────────────────────────────────────
if ! command -v sshd >/dev/null 2>&1; then
    echo "Error: sshd not found after package installation" >&2
    exit 1
fi

# ── dev user ──────────────────────────────────────────────────────────────────
# Prefer bash for the interactive shell; VS Code Remote SSH opens non-login
# interactive shells so .bashrc (not .bash_profile) is what gets sourced.
_PREFERRED_SHELL=$(command -v bash 2>/dev/null || echo /bin/sh)

if id "$DEV_USER" >/dev/null 2>&1; then
    existing_uid=$(id -u "$DEV_USER")
    if [ "$existing_uid" != "$USER_ID" ]; then
        echo "$DEV_USER exists with UID $existing_uid, expected $USER_ID — attempting to update..."
        if command -v usermod >/dev/null 2>&1; then
            usermod -u "$USER_ID" "$DEV_USER"
            # Best-effort: update ownership in common writable/application paths.
            for path in /home /root /var /opt /usr; do
                if [ -d "$path" ]; then
                    find "$path" -xdev -user "$existing_uid" -exec chown -h "$USER_ID" {} \; 2>/dev/null || true
                fi
            done
        else
            echo "Error: $DEV_USER has UID $existing_uid but USER_ID=$USER_ID, and usermod is not available." >&2
            echo "Fix: use an image where $DEV_USER does not exist, or set USER_ID=$existing_uid in jailbox.conf." >&2
            exit 1
        fi
    fi
else
    if command -v useradd >/dev/null 2>&1; then
        useradd -m -u "$USER_ID" -s "$_PREFERRED_SHELL" "$DEV_USER"
    elif command -v adduser >/dev/null 2>&1; then
        # Alpine-style adduser
        adduser -D -u "$USER_ID" -h "/home/$DEV_USER" -s "$_PREFERRED_SHELL" "$DEV_USER"
    else
        echo "Error: cannot create $DEV_USER (no useradd or adduser)" >&2
        exit 1
    fi
fi

# Ensure a valid home directory
PASSWD_ENTRY=$(get_passwd_entry)
DEVUSER_HOME=$(printf '%s\n' "$PASSWD_ENTRY" | cut -d: -f6)
[ -z "$DEVUSER_HOME" ] && DEVUSER_HOME="/home/$DEV_USER"
mkdir -p "$DEVUSER_HOME"
chown "$DEV_USER:$DEV_USER" "$DEVUSER_HOME" 2>/dev/null || true
chmod 755 "$DEVUSER_HOME" 2>/dev/null || true

# Ensure a usable login shell
DEVUSER_SHELL=$(printf '%s\n' "$PASSWD_ENTRY" | cut -d: -f7)
[ -z "$DEVUSER_SHELL" ] && DEVUSER_SHELL="/bin/sh"
case "$DEVUSER_SHELL" in
    ""|/bin/sh|/bin/false|/sbin/nologin|/usr/sbin/nologin)
        # Upgrade sh → bash when available; VS Code Remote SSH requires bash
        # for its server install script and for terminal prompt support.
        if command -v usermod >/dev/null 2>&1; then
            usermod -s "$_PREFERRED_SHELL" "$DEV_USER" 2>/dev/null || true
        fi
        ;;
esac

# Refresh after any shell update above.
PASSWD_ENTRY=$(get_passwd_entry)
DEVUSER_SHELL=$(printf '%s\n' "$PASSWD_ENTRY" | cut -d: -f7)
[ -z "$DEVUSER_SHELL" ] && DEVUSER_SHELL="$_PREFERRED_SHELL"
if ! [ -x "$DEVUSER_SHELL" ]; then
    if [ -x "$_PREFERRED_SHELL" ]; then
        usermod -s "$_PREFERRED_SHELL" "$DEV_USER" 2>/dev/null || true
    elif [ -x /bin/sh ]; then
        usermod -s /bin/sh "$DEV_USER" 2>/dev/null || true
    fi
fi

# Ensure account is not locked. Required for SSH key auth on systems where
# OpenSSH is compiled without PAM support (e.g. Alpine). useradd and adduser -D
# both set the shadow password field to "!" (locked); change it to "*" (no
# password, not locked) so key-based auth succeeds without PAM.
if command -v usermod >/dev/null 2>&1; then
    usermod -p '*' "$DEV_USER" 2>/dev/null || true
fi

# Provide a minimal prompt for interactive bash shells. VS Code Remote SSH opens
# non-login interactive shells, so .bashrc is the right place for PS1.
if [ ! -f "$DEVUSER_HOME/.bashrc" ]; then
    cat > "$DEVUSER_HOME/.bashrc" << 'DOTBASHRC'
export PS1='\u@\h:\w\$ '
DOTBASHRC
    chown "$DEV_USER:$DEV_USER" "$DEVUSER_HOME/.bashrc"
elif ! grep -q 'PS1=' "$DEVUSER_HOME/.bashrc"; then
    cat >> "$DEVUSER_HOME/.bashrc" << 'DOTBASHRC'
export PS1='\u@\h:\w\$ '
DOTBASHRC
    chown "$DEV_USER:$DEV_USER" "$DEVUSER_HOME/.bashrc"
fi

# SSH directory
mkdir -p "$DEVUSER_HOME/.ssh"
chmod 700 "$DEVUSER_HOME/.ssh"
chown -R "$DEV_USER:$DEV_USER" "$DEVUSER_HOME/.ssh"

# ── sshd hardening ────────────────────────────────────────────────────────────
# Generate host keys for any missing algorithm.
ssh-keygen -A

# Write jailbox settings to a dedicated sshd config. The wrapper starts sshd
# with this file directly so distro defaults cannot override jailbox policy.
#
# Both ChallengeResponseAuthentication (pre-8.7) and
# KbdInteractiveAuthentication (8.7+) are set to cover all OpenSSH versions.
cat > /etc/ssh/jailbox_sshd_config << EOF
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
UsePAM no
AllowTcpForwarding local
AllowStreamLocalForwarding yes
PermitTunnel no
GatewayPorts no
AllowUsers ${DEV_USER}
EOF
