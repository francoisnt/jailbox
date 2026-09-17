#!/bin/bash
# shellcheck disable=SC2009 # Keep the process listing in failure diagnostics.
# Download failures are reported with their original status below.
set -uo pipefail
JAILBOX_E2E_REH_RELEASE=$1
JAILBOX_E2E_REH_COMMIT=$2
echo "REH_RELEASE=$JAILBOX_E2E_REH_RELEASE"
echo "REH_COMMIT=$JAILBOX_E2E_REH_COMMIT"

SERVER_DATA_DIR="$HOME/.vscodium-server"
SERVER_DIR="$SERVER_DATA_DIR/bin/$JAILBOX_E2E_REH_COMMIT"
SERVER_SCRIPT="$SERVER_DIR/bin/codium-server"
SERVER_LOGFILE="$SERVER_DATA_DIR/.$JAILBOX_E2E_REH_COMMIT.log"
SERVER_PIDFILE="$SERVER_DATA_DIR/.$JAILBOX_E2E_REH_COMMIT.pid"
SERVER_TOKENFILE="$SERVER_DATA_DIR/.$JAILBOX_E2E_REH_COMMIT.token"

os_release_id="$(grep -i '^ID=' /etc/os-release 2>/dev/null | sed 's/^ID=//gi' | sed 's/"//g' || true)"
platform="linux"
if [[ "$os_release_id" == "alpine" ]]; then
    platform="alpine"
fi

arch="$(uname -m)"
case "$arch" in
    x86_64 | amd64) server_arch="x64" ;;
    aarch64 | arm64) server_arch="arm64" ;;
    *) echo "unsupported arch: $arch"; exit 1 ;;
esac

mkdir -p "$SERVER_DIR" "$SERVER_DATA_DIR" || {
    echo "REH_MKDIR_FAILED=$?"
    exit 1
}

echo "REH_SERVER_DIR=$SERVER_DIR"
if [[ ! -f "$SERVER_SCRIPT" ]]; then
    url="https://github.com/VSCodium/vscodium/releases/download/$JAILBOX_E2E_REH_RELEASE/vscodium-reh-${platform}-${server_arch}-$JAILBOX_E2E_REH_RELEASE.tar.gz"
    echo "REH_DOWNLOAD_URL=$url"
    tmp="$SERVER_DIR/vscode-server.tar.gz"
    if command -v curl >/dev/null 2>&1; then
        curl --retry 3 --connect-timeout 10 --max-time 120 --location --show-error --silent --output "$tmp" "$url"
        rc=$?
        if [[ "$rc" -ne 0 ]]; then
            echo "REH_DOWNLOAD_FAILED=$rc"
            exit 1
        fi
    else
        wget --tries=3 --timeout=10 --continue --no-verbose -O "$tmp" "$url"
        rc=$?
        if [[ "$rc" -ne 0 ]]; then
            echo "REH_DOWNLOAD_FAILED=$rc"
            exit 1
        fi
    fi
    echo "REH_DOWNLOAD_OK"
    tar -xf "$tmp" -C "$SERVER_DIR" --strip-components 1
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "REH_EXTRACT_FAILED=$rc"
        ls -lh "$tmp" 2>&1 || true
        exit 1
    fi
    echo "REH_EXTRACT_OK"
    rm -f "$tmp"
else
    echo "REH_SERVER_ALREADY_INSTALLED"
fi

if [[ ! -x "$SERVER_SCRIPT" ]]; then
    echo "REH_SERVER_SCRIPT_NOT_EXECUTABLE=$SERVER_SCRIPT"
    ls -la "$SERVER_DIR" "$SERVER_DIR/bin" 2>&1 || true
    exit 1
fi

if [[ -f "$SERVER_PIDFILE" ]]; then
    kill "$(cat "$SERVER_PIDFILE")" >/dev/null 2>&1 || true
fi
rm -f "$SERVER_LOGFILE" "$SERVER_TOKENFILE"
printf '%s\n' "jailbox-e2e-token" > "$SERVER_TOKENFILE"
chmod 600 "$SERVER_TOKENFILE"

echo "REH_STARTING=$SERVER_SCRIPT"
"$SERVER_SCRIPT" --start-server --host=127.0.0.1 --port=0 \
    --connection-token-file "$SERVER_TOKENFILE" \
    --telemetry-level off --enable-remote-auto-shutdown \
    --accept-server-license-terms > "$SERVER_LOGFILE" 2>&1 &
echo "$!" > "$SERVER_PIDFILE"
echo "REH_PID=$(cat "$SERVER_PIDFILE")"

for _ in $(seq 1 30); do
    listening_on="$(grep -E 'Extension host agent listening on .+' "$SERVER_LOGFILE" 2>/dev/null | tail -1 | sed 's/.*Extension host agent listening on //')"
    if [[ -n "$listening_on" ]]; then
        echo "LISTENING_ON=$listening_on"
        exit 0
    fi
    sleep 0.2
done

echo "REH_LISTENING_PORT_NOT_FOUND"
cat "$SERVER_LOGFILE" || true
echo "### process list"
ps -o pid,ppid,args -A | grep -E 'codium|node|server-main' | grep -v grep || true
echo "### server dir"
ls -la "$SERVER_DIR" "$SERVER_DIR/bin" 2>&1 || true
exit 1
