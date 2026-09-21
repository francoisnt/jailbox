#!/bin/sh
set -eu
# shellcheck disable=SC3040
(set -o pipefail) 2>/dev/null && set -o pipefail

MANAGED_USER=jailbox

# Install a shipped subtree without changing unrelated base-image permissions.
# Subshells keep recursive traversal state and umask local to each invocation.
install_runtime_tree() (
    umask 022
    [ -d "$1" ] || return 1
    if [ ! -d "$2" ]; then
        mkdir "$2" && chmod 0755 "$2" || return 1
    fi
    for source in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        [ -e "$source" ] || [ -L "$source" ] || continue
        target="$2/${source##*/}"
        if [ -L "$target" ]; then
            echo "Error: runtime destination is a symlink: $target" >&2
            return 1
        fi
        if [ -L "$source" ]; then
            echo "Error: runtime sources must not be symlinks: $source" >&2
            return 1
        elif [ -d "$source" ]; then
            install_runtime_tree "$source" "$target" "$3" || return 1
            # Shipped directories need traversal permissions even when the
            # base image already contained them. Shared bin/lib roots retain
            # their existing modes because only children are normalized here.
            chmod 0755 "$target" || return 1
        elif [ -f "$source" ]; then
            [ ! -d "$target" ] || return 1
            cp "$source" "$target" && chmod "$3" "$target" || return 1
        else
            echo "Error: unsupported runtime source: $source" >&2
            return 1
        fi
    done
)

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
        getent passwd "$USER_ID" 2>/dev/null | cut -d: -f1 || true
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
            musl libgcc libstdc++ flock \
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
# actual sshd HostKey below is supplied by the host per container generation,
# so these image-level keys are only baseline compatibility state.
ssh-keygen -A

# Parse the required server feature independently of runtime-mounted host keys.
# Do not infer capabilities from distro version strings or vendor backports.
# Debian's root-run configuration test also requires its privilege-separation
# directory. Runtime uses an unprivileged daemon and a separate /run tmpfs.
mkdir -p /run/sshd && chmod 0755 /run/sshd || exit 1
if ! sshd -T -f /dev/null -o 'SetEnv JAILBOX_SSH_FEATURE_CHECK=yes' >/dev/null; then
    echo 'Error: could not validate SSH server session settings; jailbox requires SetEnv support (OpenSSH 7.8+). Check the error above and update the development image if unsupported.' >&2
    exit 1
fi

# Write jailbox settings to a dedicated sshd config. The wrapper starts sshd
# with this file directly so distro defaults cannot override jailbox policy.
#
# Both ChallengeResponseAuthentication (pre-8.7) and
# KbdInteractiveAuthentication (8.7+) are set to cover all OpenSSH versions.
#
# Authentication material is prepared on the host once per container and mounted
# read-only under /run/jailbox-sshd. keep-id preserves StrictModes ownership.
# Mutable daemon state lives separately on the managed-user-owned /run tmpfs.
cat > /etc/ssh/jailbox_sshd_config << EOF
Port 2222
PidFile /run/sshd.pid
HostKey /run/jailbox-sshd/ssh_host_ed25519_key
StrictModes yes
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
install_runtime_tree /tmp/jailbox-container/runtime/bin /usr/local/bin 0755
install_runtime_tree /tmp/jailbox-container/runtime/lib /usr/local/lib 0644
