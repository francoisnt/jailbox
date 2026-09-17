# Dev image discovery, validation, and wrapper-image build.

PROJECT_DEV_IMAGE=""
JAILBOX_IMAGE=""
USABLE_SHELL=""
PKG_MANAGER=""
SELECTED_DEV_CONTAINERFILE=""
SELECTED_DEV_CONTAINERFILE_INPUT=""
SELECTED_DEV_BUILD_CONTEXT=""
SELECTED_DEV_IMAGE_ID=""

initialize_dev_image_state() {
    PROJECT_DEV_IMAGE="${PROJECT_RESOURCE_PREFIX}-dev"
    JAILBOX_IMAGE="${PROJECT_RESOURCE_PREFIX}-image"
    USABLE_SHELL=""
    PKG_MANAGER=""
    SELECTED_DEV_CONTAINERFILE=""
    SELECTED_DEV_CONTAINERFILE_INPUT=""
    SELECTED_DEV_BUILD_CONTEXT=""
    SELECTED_DEV_IMAGE_ID=""
}

# Cleanup uses immutable project identity, never the image selected at launch.
# Remove the wrapper before its dev-image parent so child images cannot block
# deletion of a project-built dev image.
project_cleanup_images() {
    printf '%s\n' "${PROJECT_RESOURCE_PREFIX}-image" \
        "${PROJECT_RESOURCE_PREFIX}-proxy" "${PROJECT_RESOURCE_PREFIX}-dev"
}

assert_dev_image_state_initialized() {
    [[ -n "$PROJECT_DEV_IMAGE" && -n "$JAILBOX_IMAGE" ]] || \
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

    validate_local_build_inputs || return $?
    local display_path
    local -a BUILD_CMD=(podman build -t "$PROJECT_DEV_IMAGE" -f "$SELECTED_DEV_CONTAINERFILE")
    [ -n "$DEV_TARGET_STAGE" ] && BUILD_CMD+=(--target "$DEV_TARGET_STAGE")
    BUILD_CMD+=("$SELECTED_DEV_BUILD_CONTEXT")

    display_path=$(realpath --relative-to="$PROJECT_DIR" "$SELECTED_DEV_CONTAINERFILE" 2>/dev/null || printf '%s' "$SELECTED_DEV_CONTAINERFILE")
    echo "🏗️  Building dev image from $display_path..."
    "${BUILD_CMD[@]}"
}

# Shared local-only launch checks. DEV_IMAGE makes file/context inputs unused.
validate_local_build_inputs() {
    [ -z "$DEV_IMAGE" ] || return 0
    select_dev_containerfile_for_launch || return $?

    local build_context_input context_status
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
}

run_validate() {
    [ -z "$CONFIG_PATH_ARG" ] || die '--config cannot be used with validate; use JAILBOX_CONFIG_* environment configuration'
    require_command realpath
    load_environment_config || return 1
    validate_configured_readonly_paths || return 1
    validate_local_build_inputs || return 1
    finalize_effective_readonly_paths || return 1
    printf 'Configuration and local launch inputs are valid; sandbox health and build success were not checked.\n'
}

# Run the trusted selector for a launch, turning a vanished or unusable
# selection into launch's specific missing-input diagnostic. The digest shares
# this entry point so both reach the same Containerfile by the same order.
select_dev_containerfile_for_launch() {
    local status

    status=0
    discover_dev_containerfile || status=$?
    case "$status" in
        0) return 0 ;;
        1) die "no Containerfile found. Set DEV_IMAGE or DEV_CONTAINERFILE in jailbox.conf, or add a Containerfile to the project root." ;;
        2) die "configured Containerfile does not exist: $DEV_CONTAINERFILE" ;;
        *) return "$status" ;;
    esac
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

    # shellcheck disable=SC2016  # Expanded inside the image.
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
    # Resolve once and feed the immutable identity to FROM. A moved local tag
    # must not reuse a wrapper built from the previous base through cached FROM
    # resolution. Missing images may be fetched; automatic refresh is separate.
    local status=0
    podman image exists "$PROJECT_DEV_IMAGE" || status=$?
    case "$status" in
        0) ;;
        1)
            [ -n "$DEV_IMAGE" ] || die "just-built development image '$PROJECT_DEV_IMAGE' is missing"
            podman pull "$PROJECT_DEV_IMAGE" || return 1
            ;;
        *) die "could not inspect development image '$PROJECT_DEV_IMAGE'" ;;
    esac
    SELECTED_DEV_IMAGE_ID=$(podman image inspect "$PROJECT_DEV_IMAGE" --format '{{.Id}}') || return 1
    [ -n "$SELECTED_DEV_IMAGE_ID" ] || die 'development image inspection returned no identity'

    echo "📦 Building jailbox image..."
    if ! podman build \
        -t "$JAILBOX_IMAGE" \
        -f "$SCRIPT_DIR/container/Containerfile.wrapper" \
        --pull=never \
        --build-arg DEV_IMAGE="$SELECTED_DEV_IMAGE_ID" \
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

build_current_proxy_image() {
    if [ -n "${EGRESS_ALLOW[*]-}" ]; then
        podman build -t "$PROXY_IMAGE" -f "$SCRIPT_DIR/container/tinyproxy/Containerfile" "$SCRIPT_DIR/container/tinyproxy"
    fi
}

jailbox_install_cache_bust() (
    cd "$SCRIPT_DIR" || return 1
    # These payloads are streamed by the host, never copied into a built image.
    find container -type f ! -path 'container/validate-session.sh' ! -path 'container/proxy-route.awk' -print0 \
        | sort -z \
        | xargs -0 cksum \
        | cksum \
        | cut -d' ' -f1
)
