# Dev image discovery, validation, and wrapper-image build.

PROJECT_DEV_IMAGE=""
JAILBOX_IMAGE=""
USABLE_SHELL=""
PKG_MANAGER=""
SELECTED_DEV_CONTAINERFILE=""
SELECTED_DEV_CONTAINERFILE_INPUT=""
SELECTED_DEV_BUILD_CONTEXT=""

initialize_dev_image_state() {
    PROJECT_DEV_IMAGE="${PROJECT_RESOURCE_PREFIX}-dev"
    JAILBOX_IMAGE="${PROJECT_RESOURCE_PREFIX}-image"
    USABLE_SHELL=""
    PKG_MANAGER=""
    SELECTED_DEV_CONTAINERFILE=""
    SELECTED_DEV_CONTAINERFILE_INPUT=""
    SELECTED_DEV_BUILD_CONTEXT=""
}

assert_dev_image_state_initialized() {
    [ -n "$PROJECT_DEV_IMAGE" ] && [ -n "$JAILBOX_IMAGE" ] || \
        die "internal error: development image state is not initialized"
}

# Validation probes execute the dev image (including any entrypoint it
# defines) before jailbox's runtime hardening applies. The probes only run
# short shell one-liners, so constrain them: no network, no capabilities, no
# privilege escalation.
podman_probe() {
    podman run --rm --network=none --cap-drop=ALL --security-opt=no-new-privileges "$@"
}

build_or_select_dev_image() {
    assert_dev_image_state_initialized
    SELECTED_DEV_CONTAINERFILE=""
    SELECTED_DEV_CONTAINERFILE_INPUT=""
    SELECTED_DEV_BUILD_CONTEXT=""
    if [ -n "$DEV_IMAGE" ]; then
        echo "📦 Using dev image: $DEV_IMAGE"
        PROJECT_DEV_IMAGE="$DEV_IMAGE"
        return 0
    fi

    local discovery_status
    if discover_dev_containerfile; then
        :
    else
        discovery_status=$?
        if [ "$discovery_status" -eq 2 ]; then
            die "configured Containerfile does not exist: $DEV_CONTAINERFILE"
        fi
        [ "$discovery_status" -eq 1 ] || return "$discovery_status"
        die "no Containerfile found. Set DEV_IMAGE or DEV_CONTAINERFILE in jailbox.conf, or add a Containerfile to the project root."
    fi

    local build_context_input display_path context_status
    if [ -n "$DEV_BUILD_CONTEXT" ]; then
        case "$DEV_BUILD_CONTEXT" in
            /*) build_context_input="$DEV_BUILD_CONTEXT" ;;
            *) build_context_input="$PROJECT_DIR/$DEV_BUILD_CONTEXT" ;;
        esac
    else
        build_context_input="$PROJECT_DIR"
    fi
    context_status=0
    SELECTED_DEV_BUILD_CONTEXT=$(classify_trusted_directory "$build_context_input" "build context") || context_status=$?
    [ "$context_status" -eq 0 ] || return "$context_status"
    BUILD_CMD=(podman build -t "$PROJECT_DEV_IMAGE" -f "$SELECTED_DEV_CONTAINERFILE")
    [ -n "$DEV_TARGET_STAGE" ] && BUILD_CMD+=(--target "$DEV_TARGET_STAGE")
    BUILD_CMD+=("$SELECTED_DEV_BUILD_CONTEXT")

    display_path=$(realpath --relative-to="$PROJECT_DIR" "$SELECTED_DEV_CONTAINERFILE" 2>/dev/null || printf '%s' "$SELECTED_DEV_CONTAINERFILE")
    echo "🏗️  Building dev image from $display_path..."
    "${BUILD_CMD[@]}"
}

discover_dev_containerfile() {
    local candidate classified

    if [ -n "$DEV_CONTAINERFILE" ]; then
        case "$DEV_CONTAINERFILE" in
            /*) candidate="$DEV_CONTAINERFILE" ;;
            *) candidate="$PROJECT_DIR/$DEV_CONTAINERFILE" ;;
        esac
        [ -e "$candidate" ] || [ -L "$candidate" ] || return 2
        SELECTED_DEV_CONTAINERFILE_INPUT="$candidate"
        classified=$(classify_trusted_file "$candidate" "Containerfile") || return 3
        SELECTED_DEV_CONTAINERFILE="${classified%%$'\t'*}"
        return 0
    fi

    for candidate in \
        "$PROJECT_DIR/Containerfile" \
        "$PROJECT_DIR/Dockerfile" \
        "$PROJECT_DIR/.devcontainer/Containerfile" \
        "$PROJECT_DIR/.devcontainer/Dockerfile"
    do
        if [ -f "$candidate" ] || [ -L "$candidate" ]; then
            SELECTED_DEV_CONTAINERFILE_INPUT="$candidate"
            classified=$(classify_trusted_file "$candidate" "Containerfile") || return 3
            SELECTED_DEV_CONTAINERFILE="${classified%%$'\t'*}"
            return 0
        fi
    done

    return 1
}

validate_dev_image() {
    echo "🔍 Validating dev image..."

    USABLE_SHELL=""
    if podman_probe "$PROJECT_DEV_IMAGE" /bin/sh -c "exit 0" 2>/dev/null; then
        USABLE_SHELL="/bin/sh"
    elif podman_probe "$PROJECT_DEV_IMAGE" bash -c "exit 0" 2>/dev/null; then
        USABLE_SHELL="bash"
    fi

    if [ -z "$USABLE_SHELL" ]; then
        echo "Error: dev image has no usable shell (tried /bin/sh and bash)." >&2
        echo "Dev image: $PROJECT_DEV_IMAGE"
        echo "This looks like a production or distroless image."
        [ -n "$DEV_TARGET_STAGE" ] && echo "Stage: $DEV_TARGET_STAGE"
        echo "Fix: use DEV_TARGET_STAGE to target a dev stage, or set DEV_IMAGE."
        exit 1
    fi

    PKG_MANAGER=$(podman_probe "$PROJECT_DEV_IMAGE" "$USABLE_SHELL" -c \
        'for pm in apt-get apk dnf yum; do command -v "$pm" >/dev/null 2>&1 && echo "$pm" && exit 0; done; exit 1' \
        2>/dev/null || true)

    if [ -z "$PKG_MANAGER" ]; then
        echo "Error: dev image has no supported package manager (apt-get, apk, dnf, yum)." >&2
        echo "Dev image: $PROJECT_DEV_IMAGE"
        echo "This looks like a production or distroless image."
        [ -n "$DEV_TARGET_STAGE" ] && echo "Stage: $DEV_TARGET_STAGE"
        echo "Fix: use DEV_TARGET_STAGE to target a dev stage, or set DEV_IMAGE."
        exit 1
    fi

    echo "  Package manager: $PKG_MANAGER"
}

warn_if_alpine_dev_image_with_vscode() {
    local os_release

    [ "$(basename "$EDITOR_BIN")" = "code" ] || return 0

    os_release=$(podman_probe "$PROJECT_DEV_IMAGE" "$USABLE_SHELL" -c 'cat /etc/os-release' 2>/dev/null || true)
    if printf '%s\n' "$os_release" | grep -Eq '^ID="?alpine"?$'; then
        echo "⚠️  VS Code Remote SSH does not support Alpine SSH hosts."
        echo "   This dev image appears to be Alpine-based; set EDITOR=codium in jailbox.conf."
    fi
}

build_jailbox_image() {
    local install_cache_bust

    install_cache_bust=$(jailbox_install_cache_bust)

    echo "📦 Building jailbox image..."
    if ! podman build \
        -t "$JAILBOX_IMAGE" \
        -f "$SCRIPT_DIR/container/Containerfile.wrapper" \
        --build-arg DEV_IMAGE="$PROJECT_DEV_IMAGE" \
        --build-arg JAILBOX_INSTALL_CACHE_BUST="$install_cache_bust" \
        --build-arg USER_ID="$MY_UID" \
        "$SCRIPT_DIR/container"; then
        echo ""
        echo "Error: jailbox image build failed."
        printf "  Dev image:       %s\n" "$PROJECT_DEV_IMAGE"
        [ -n "$DEV_TARGET_STAGE" ] && printf "  Stage:           %s\n" "$DEV_TARGET_STAGE"
        printf "  Package manager: %s\n" "$PKG_MANAGER"
        echo ""
        echo "Common causes:"
        echo "  - The selected stage is a production or distroless stage"
        echo "  - The wrapper prerequisites cannot be installed in this image"
        echo "Fix: verify DEV_TARGET_STAGE in jailbox.conf or use a supported development image."
        exit 1
    fi
}

jailbox_install_cache_bust() {
    find "$SCRIPT_DIR/container" -type f -print0 \
        | sort -z \
        | xargs -0 cksum \
        | cksum \
        | cut -d' ' -f1
}
