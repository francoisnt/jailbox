#!/bin/sh
set -e

MANAGED_USER=jailbox

# Portable /etc/passwd lookup — getent is absent on Alpine/busybox images.
get_passwd_entry() {
    if command -v getent >/dev/null 2>&1; then
        getent passwd "$MANAGED_USER"
    else
        grep "^${MANAGED_USER}:" /etc/passwd || true
    fi
}

get_user_for_uid() {
    if command -v getent >/dev/null 2>&1; then
        getent passwd "$USER_ID" | cut -d: -f1
    else
        awk -F: -v uid="$USER_ID" '$3 == uid { print $1; exit }' /etc/passwd
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

# ── managed user ──────────────────────────────────────────────────────────────
# The wrapper image owns the runtime user model. Dev images should install tools
# system-wide; they must not require a pre-existing app-specific user or home
# directory. Failing on conflicts is safer than mutating arbitrary image users
# and avoids recursive ownership repair across system paths.
# Prefer bash for the managed user because VS Code Remote SSH and many dev
# tools assume it exists, but keep shell startup files under user control.
_PREFERRED_SHELL=$(command -v bash 2>/dev/null || echo /bin/sh)
if id "$MANAGED_USER" >/dev/null 2>&1; then
    existing_uid=$(id -u "$MANAGED_USER")
    echo "Error: managed user '$MANAGED_USER' already exists in the dev image with UID $existing_uid." >&2
    echo "Fix: remove or rename that user in the dev image. jailbox always creates its own managed user." >&2
    exit 1
else
    existing_user_for_uid=$(get_user_for_uid)
    if [ -n "$existing_user_for_uid" ]; then
        echo "Error: host UID $USER_ID already belongs to existing image user '$existing_user_for_uid'." >&2
        echo "jailbox will not mutate arbitrary existing users. Use a dev image where UID $USER_ID is free." >&2
        exit 1
    fi

    if command -v useradd >/dev/null 2>&1; then
        useradd -m -u "$USER_ID" -s "$_PREFERRED_SHELL" "$MANAGED_USER"
    elif command -v adduser >/dev/null 2>&1; then
        # Alpine-style adduser
        adduser -D -u "$USER_ID" -h "/home/$MANAGED_USER" -s "$_PREFERRED_SHELL" "$MANAGED_USER"
    else
        echo "Error: cannot create $MANAGED_USER (no useradd or adduser)" >&2
        exit 1
    fi
fi

# Ensure a valid home directory
PASSWD_ENTRY=$(get_passwd_entry)
MANAGED_HOME=$(printf '%s\n' "$PASSWD_ENTRY" | cut -d: -f6)
[ -z "$MANAGED_HOME" ] && MANAGED_HOME="/home/$MANAGED_USER"
# Only files created as part of the managed jailbox account are chowned here.
# The project mount and persistent home volume are handled by keep-id/Podman,
# not by changing ownership inside the dev image.
mkdir -p "$MANAGED_HOME"
chown "$MANAGED_USER:$MANAGED_USER" "$MANAGED_HOME" 2>/dev/null || true
chmod 755 "$MANAGED_HOME" 2>/dev/null || true

# Ensure the managed account has an executable shell.
MANAGED_SHELL=$(printf '%s\n' "$PASSWD_ENTRY" | cut -d: -f7)
[ -z "$MANAGED_SHELL" ] && MANAGED_SHELL="$_PREFERRED_SHELL"
if ! [ -x "$MANAGED_SHELL" ]; then
    echo "Error: managed user '$MANAGED_USER' has unusable shell '$MANAGED_SHELL'." >&2
    echo "Fix: use an image with bash or /bin/sh available." >&2
    exit 1
fi

# Ensure a jailbox-created account is not locked. Required for SSH key auth on
# systems where OpenSSH is compiled without PAM support (e.g. Alpine). useradd
# and adduser -D both set the shadow password field to "!" (locked); change it
# to "*" (no password, not locked) so key-based auth succeeds without PAM.
if command -v usermod >/dev/null 2>&1; then
    usermod -p '*' "$MANAGED_USER" 2>/dev/null || true
fi

# ── sshd hardening ────────────────────────────────────────────────────────────
# Distro package post-install scripts may expect host keys to exist. jailbox's
# actual sshd HostKey below is regenerated per launch under /run/jailbox-sshd,
# so these image-level keys are only baseline compatibility state.
ssh-keygen -A

# Write jailbox settings to a dedicated sshd config. The wrapper starts sshd
# with this file directly so distro defaults cannot override jailbox policy.
#
# Both ChallengeResponseAuthentication (pre-8.7) and
# KbdInteractiveAuthentication (8.7+) are set to cover all OpenSSH versions.
#
# Runtime auth and host-key files are generated under /run/jailbox-sshd. That
# path is backed by a strict, user-owned bind mount so sshd can satisfy
# StrictModes under rootless Podman/userns without permission-bypass
# capabilities.
cat > /etc/ssh/jailbox_sshd_config << EOF
Port 2222
PidFile /run/jailbox-sshd/sshd.pid
HostKey /run/jailbox-sshd/ssh_host_ed25519_key
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile /run/jailbox-sshd/authorized_keys
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
UsePAM no
AllowTcpForwarding local
AllowStreamLocalForwarding yes
PermitTunnel no
GatewayPorts no
AcceptEnv HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy
AllowUsers ${MANAGED_USER}
EOF

# ── jailbox runtime helpers ───────────────────────────────────────────────────
cp /tmp/jailbox-container/downloader-proxy-manager.sh /usr/local/bin/jailbox-manage-proxy
chmod 755 /usr/local/bin/jailbox-manage-proxy
