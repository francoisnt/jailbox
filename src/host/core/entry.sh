# Core module loading and explicit initialization.
# shellcheck source=src/host/core/checks/host.sh
source "$SCRIPT_DIR/host/core/checks/host.sh"
# shellcheck source=src/host/core/project/hash.sh
source "$SCRIPT_DIR/host/core/project/hash.sh"
# shellcheck source=src/host/core/project/identity.sh
source "$SCRIPT_DIR/host/core/project/identity.sh"
# shellcheck source=src/host/core/project/paths.sh
source "$SCRIPT_DIR/host/core/project/paths.sh"
# shellcheck source=src/host/core/configuration/version.sh
source "$SCRIPT_DIR/host/core/configuration/version.sh"
# shellcheck source=src/host/core/configuration/load.sh
source "$SCRIPT_DIR/host/core/configuration/load.sh"
# shellcheck source=src/host/core/configuration/digest.sh
source "$SCRIPT_DIR/host/core/configuration/digest.sh"
# shellcheck source=src/host/core/resources/inventory.sh
source "$SCRIPT_DIR/host/core/resources/inventory.sh"
# shellcheck source=src/host/core/resources/images.sh
source "$SCRIPT_DIR/host/core/resources/images.sh"
# shellcheck source=src/host/core/resources/ssh.sh
source "$SCRIPT_DIR/host/core/resources/ssh.sh"
# shellcheck source=src/host/core/resources/network.sh
source "$SCRIPT_DIR/host/core/resources/network.sh"
# shellcheck source=src/host/core/resources/proxy.sh
source "$SCRIPT_DIR/host/core/resources/proxy.sh"
# shellcheck source=src/host/core/resources/downloader.sh
source "$SCRIPT_DIR/host/core/resources/downloader.sh"
# shellcheck source=src/host/core/resources/home.sh
source "$SCRIPT_DIR/host/core/resources/home.sh"
# shellcheck source=src/host/core/resources/container.sh
source "$SCRIPT_DIR/host/core/resources/container.sh"
# shellcheck source=src/host/core/resources/runtime-files.sh
source "$SCRIPT_DIR/host/core/resources/runtime-files.sh"
# shellcheck source=src/host/core/checks/compatibility.sh
source "$SCRIPT_DIR/host/core/checks/compatibility.sh"
# shellcheck source=src/host/core/checks/attachment.sh
source "$SCRIPT_DIR/host/core/checks/attachment.sh"
# shellcheck source=src/host/core/commands/up.sh
source "$SCRIPT_DIR/host/core/commands/up.sh"
# shellcheck source=src/host/core/commands/stop.sh
source "$SCRIPT_DIR/host/core/commands/stop.sh"
# shellcheck source=src/host/core/commands/clean.sh
source "$SCRIPT_DIR/host/core/commands/clean.sh"
# shellcheck source=src/host/core/commands/status.sh
source "$SCRIPT_DIR/host/core/commands/status.sh"
# shellcheck source=src/host/core/commands/ssh-config.sh
source "$SCRIPT_DIR/host/core/commands/ssh-config.sh"
# shellcheck source=src/host/core/commands/version.sh
source "$SCRIPT_DIR/host/core/commands/version.sh"
# shellcheck source=src/host/core/commands/validate.sh
source "$SCRIPT_DIR/host/core/commands/validate.sh"
# shellcheck source=src/host/core/commands/connection-info.sh
source "$SCRIPT_DIR/host/core/commands/connection-info.sh"
# shellcheck source=src/host/core/commands/exec.sh
source "$SCRIPT_DIR/host/core/commands/exec.sh"
# shellcheck source=src/host/core/commands/shell.sh
source "$SCRIPT_DIR/host/core/commands/shell.sh"

apply_config_defaults

initialize_launch_state() {
    initialize_config_digest_state
    initialize_dev_image_state
    initialize_ssh_state
    initialize_network_state
    initialize_container_runtime_state
    initialize_convergence_state
}
