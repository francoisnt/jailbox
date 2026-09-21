# Public interface declarations.
#
# Changes here drive release version suggestions:
# - Before v1.0.0, additions suggest patch and removals suggest minor.
# - After v1.0.0, removing a config key or CLI flag suggests a major bump.
# - After v1.0.0, adding a config key or CLI flag suggests a minor bump.
# - Other changes suggest a patch bump.

# Machine configuration keys. Each declared key has exactly one derived
# environment spelling: KEY -> JAILBOX_CONFIG_KEY (scalars) or contiguous
# JAILBOX_CONFIG_KEY_0.. members / a bare empty variable (arrays). The
# namespace is declared here once; adding or removing a key changes the
# derived interface.
CONFIG_SCALAR_KEYS=(
    DEV_IMAGE
    DEV_CONTAINERFILE
    DEV_BUILD_CONTEXT
    DEV_TARGET_STAGE
    MEMORY_LIMIT
    CPU_LIMIT
    PIDS_LIMIT
    EPHEMERAL_HOME
)

CONFIG_ARRAY_KEYS=(
    EGRESS_ALLOW
    READONLY_PATHS
)

# Frontend-only keys: accepted in jailbox.conf for the human editor workflow,
# never part of the JAILBOX_CONFIG_* machine namespace.
FRONTEND_SCALAR_KEYS=(
    EDITOR
)

# Resource-limit defaults are literal effective values, not launch-time
# fallbacks: an absent key and an explicitly spelled default are the same
# configuration (and the same digest once the digest lands).
CONFIG_DEFAULTS=(
    "DEV_IMAGE="
    "DEV_CONTAINERFILE="
    "DEV_BUILD_CONTEXT="
    "DEV_TARGET_STAGE="
    "MEMORY_LIMIT=4g"
    "CPU_LIMIT=2"
    "PIDS_LIMIT=256"
    "EPHEMERAL_HOME=false"
    "EGRESS_ALLOW="
    "READONLY_PATHS="
)

# shellcheck disable=SC2034 # Mapping validated through its declared name.
FRONTEND_DEFAULTS=(
    "EDITOR="
)

CLI_FLAGS_WITH_VALUES=(
    --config
)
declare -A CLI_VALUE_NAMES=([--config]=PATH)

# Commands that manage sandbox containers, networks, and home state. The bare
# editor launch and --no-editor delegate lifecycle work to public up. Frontend
# commands, project initialization, and installation management are not lifecycle commands.
CLI_LIFECYCLE_COMMANDS=(
    up
    stop
    --clean
)

CLI_OTHER_COMMANDS=(
    --no-editor
    exec
    shell
    init
    config-schema
    status
    connection-info
    validate
    ssh-config
    --uninstall
    --version
    --help
)

CLI_ARGUMENT_COMMANDS=(exec)

CLI_HELP=(
    "exec=Run a command: exec [--] CMD [ARG...]"
    "shell=Open an interactive login shell in a running sandbox"
    "--version=Show the build version without reading configuration"
    "--config=Load configuration from PATH instead of project jailbox.conf"
    "init=Create the default project jailbox.conf"
    "config-schema=Print machine configuration key names and types"
    "status=Print this project's resource inventory state"
    "up=Launch the sandbox using environment configuration"
    "--no-editor=Launch from the config file without opening an editor"
    "stop=Stop and remove this project's jailbox containers, networks, and ephemeral home"
    "connection-info=Print validated NUL-delimited SSH connection metadata"
    "validate=Check environment configuration and local launch inputs"
    "ssh-config=Print manual SSH config instructions for this project"
    "--clean=Permanently delete this project's containers, networks, home, runtime state, and derived images"
    "--uninstall=Remove this jailbox installation from the host"
    "--help=Show this help"
)
