#!/bin/bash
# Install the lightweight dependencies used by `tests/run portable`.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tests/ci/setup-common.sh
source "$SCRIPT_DIR/setup-common.sh"

install_portable_tools() {
    local packages

    case "$(uname -s)" in
        Darwin)
            command -v brew >/dev/null 2>&1 || {
                echo "Error: Homebrew is required to install portable test dependencies" >&2
                return 1
            }
            HOMEBREW_NO_AUTO_UPDATE=1 brew install bash coreutils shellcheck
            prepend_path "$(brew --prefix bash)/bin"
            prepend_path "$(brew --prefix coreutils)/libexec/gnubin"
            command -v bash
            bash --version | head -1
            bash -c '(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) ))' || {
                echo "Error: Bash 4.4 or newer is required" >&2
                return 1
            }
            ;;
        Linux)
            packages=()
            command -v realpath >/dev/null 2>&1 || packages+=(coreutils)
            command -v shellcheck >/dev/null 2>&1 || packages+=(shellcheck)
            if [[ -n "${packages[*]-}" ]]; then
                sudo apt-get update
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
                    "${packages[@]+"${packages[@]}"}"
            fi
            ;;
        *)
            echo "Error: unsupported portable test host: $(uname -s)" >&2
            return 1
            ;;
    esac
}

setup_portable_main() {
    [[ "$#" -eq 0 ]] || {
        echo "Usage: $(basename "$0")" >&2
        return 2
    }

    cd "$ROOT_DIR"
    install_portable_tools
    verify_portable_tools
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    setup_portable_main "$@"
fi
