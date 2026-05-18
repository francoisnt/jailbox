# Dev image discovery, validation, and wrapper-image build.

build_or_select_dev_image() {
    if [ -n "$DEV_IMAGE" ]; then
        echo "📦 Using dev image: $DEV_IMAGE"
        PROJECT_DEV_IMAGE="$DEV_IMAGE"
        return 0
    fi

    discover_dev_containerfile

    local build_context
    build_context="${DEV_BUILD_CONTEXT:-$PROJECT_DIR}"
    BUILD_CMD=(podman build -t "$PROJECT_DEV_IMAGE" -f "$DEV_CONTAINERFILE")
    [ -n "$DEV_TARGET_STAGE" ] && BUILD_CMD+=(--target "$DEV_TARGET_STAGE")
    BUILD_CMD+=("$build_context")

    echo "🏗️  Building dev image from $(realpath --relative-to="$PROJECT_DIR" "$DEV_CONTAINERFILE")..."
    "${BUILD_CMD[@]}"
}

discover_dev_containerfile() {
    local candidate

    if [ -n "$DEV_CONTAINERFILE" ]; then
        return 0
    fi

    for candidate in \
        "$PROJECT_DIR/Containerfile" \
        "$PROJECT_DIR/Dockerfile" \
        "$PROJECT_DIR/.devcontainer/Containerfile" \
        "$PROJECT_DIR/.devcontainer/Dockerfile"
    do
        if [ -f "$candidate" ]; then
            DEV_CONTAINERFILE="$candidate"
            return 0
        fi
    done

    die "no Containerfile found. Set DEV_IMAGE or DEV_CONTAINERFILE in jailbox.conf, or add a Containerfile to the project root."
}

validate_dev_image() {
    echo "🔍 Validating dev image..."

    USABLE_SHELL=""
    if podman run --rm "$PROJECT_DEV_IMAGE" /bin/sh -c "exit 0" 2>/dev/null; then
        USABLE_SHELL="/bin/sh"
    elif podman run --rm "$PROJECT_DEV_IMAGE" bash -c "exit 0" 2>/dev/null; then
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

    PKG_MANAGER=$(podman run --rm "$PROJECT_DEV_IMAGE" "$USABLE_SHELL" -c \
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

build_jailbox_image() {
    echo "📦 Building jailbox image..."
    if ! podman build \
        -t "$JAILBOX_IMAGE" \
        -f "$SCRIPT_DIR/Containerfile.wrapper" \
        --build-arg DEV_IMAGE="$PROJECT_DEV_IMAGE" \
        --build-arg USER_ID="$MY_UID" \
        --build-arg AI_TOOLS="${AI_TOOLS[*]}" \
        --build-arg EXTRA_PACKAGES="$EXTRA_PACKAGES" \
        --build-arg CLAUDE_INSTALL_SHA256="$CLAUDE_INSTALL_SHA256" \
        --build-arg AIDER_VERSION="$AIDER_VERSION" \
        "$SCRIPT_DIR"; then
        echo ""
        echo "Error: jailbox image build failed."
        printf "  Dev image:       %s\n" "$PROJECT_DEV_IMAGE"
        [ -n "$DEV_TARGET_STAGE" ] && printf "  Stage:           %s\n" "$DEV_TARGET_STAGE"
        printf "  Package manager: %s\n" "$PKG_MANAGER"
        echo ""
        echo "Common causes:"
        echo "  - A package in AI_TOOLS or EXTRA_PACKAGES is unavailable in this image"
        echo "  - CLAUDE_INSTALL_SHA256 or AIDER_VERSION does not match the downloaded tool"
        echo "  - The selected stage is a production or distroless stage"
        echo "Fix: verify AI_TOOLS, EXTRA_PACKAGES, CLAUDE_INSTALL_SHA256, AIDER_VERSION, and DEV_TARGET_STAGE in jailbox.conf."
        exit 1
    fi
}
