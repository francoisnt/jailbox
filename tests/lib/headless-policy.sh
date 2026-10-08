# Machine attachment policy for the headless runtime fixture.
# The fixture explicitly lists these paths in config/runtime.conf; frontend
# composition must not add another copy of either config-file anchor.
headless_attachment_paths() {
    export JAILBOX_CONFIG_READONLY_PATHS_0=jailbox.conf
    export JAILBOX_CONFIG_READONLY_PATHS_1=config/runtime.conf
    export JAILBOX_CONFIG_READONLY_PATHS_2=protected-policy
}
