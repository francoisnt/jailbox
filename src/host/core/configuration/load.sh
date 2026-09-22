# configuration — load

ENV_CONFIG_PREFIX="JAILBOX_CONFIG_"

environment_config_names() {
    compgen -A export "$ENV_CONFIG_PREFIX" || true
}

validate_environment_value() {
    local name value LC_ALL=C

    name="$1"
    value="$2"
    # Legal values are ordinary bytes including commas and spaces;
    # newline-bearing values are deliberately not representable.
    if contains_control_character "$value"; then
        die "configuration value in '$name' contains an ASCII control character"
    fi
}

# Indirect assignment on the declared key name: callers only pass keys from
# the public-API declaration arrays, whose grammar is validated before any
# configuration is interpreted, so the name is never user-controlled.
assign_config_scalar() {
    local key value

    key="$1"
    value="$2"
    printf -v "$key" '%s' "$value"
}

load_environment_config() {
    local name key bare suffix value expected first_missing
    local gap_member count i
    local -a names=() member_names=() items=()
    local -A discovered=() handled=() expected_set=()

    mapfile -t names < <(environment_config_names)

    # Every discovered name is an exported shell parameter, so its charset is
    # already a valid identifier; restrict further to the uppercase namespace
    # grammar before any name is used as an associative-array subscript.
    for name in "${names[@]}"; do
        [[ "$name" =~ ^JAILBOX_CONFIG_[A-Z0-9_]+$ ]] || \
            die "unknown configuration variable '$name'"
        discovered["$name"]=1
    done

    for key in "${CONFIG_SCALAR_KEYS[@]}"; do
        name="${ENV_CONFIG_PREFIX}${key}"
        [[ -v discovered[$name] ]] || continue
        # Absent values receive defaults; a present empty scalar stays empty.
        value="${!name}"
        validate_environment_value "$name" "$value"
        assign_config_scalar "$key" "$value"
        handled["$name"]=1
    done

    for key in "${CONFIG_ARRAY_KEYS[@]}"; do
        bare="${ENV_CONFIG_PREFIX}${key}"
        member_names=()
        count=0
        for name in "${names[@]}"; do
            [[ "$name" == "${bare}_"* ]] || continue
            suffix="${name#"${bare}_"}"
            [[ "$suffix" =~ ^(0|[1-9][0-9]*)$ ]] || \
                die "malformed configuration array member name '$name' (indices are 0 or nonzero decimal without leading zeros)"
            member_names+=("$name")
            handled["$name"]=1
            # The member count is trusted local state; the caller-supplied
            # suffix is never interpreted through arithmetic or subscripts.
            count=$((count + 1))
        done

        if [[ -v discovered[$bare] ]]; then
            handled["$bare"]=1
            [ "$count" -eq 0 ] || \
                die "configuration array '$key' mixes the bare variable '$bare' with indexed members"
            value="${!bare}"
            [ -z "$value" ] || \
                die "non-empty bare configuration array variable '$bare' (use indexed ${bare}_0.. members; leave it empty for an explicitly empty array)"
            set_config_array "$key"
            continue
        fi
        [ "$count" -gt 0 ] || continue

        # Check the exact expected names _0.._(count-1); any expected name
        # missing means some discovered member sits past the contiguous range.
        items=()
        expected_set=()
        first_missing=""
        for ((i = 0; i < count; i++)); do
            expected="${bare}_${i}"
            expected_set["$expected"]=1
            if [[ ! -v discovered[$expected] ]]; then
                [ -n "$first_missing" ] || first_missing="$expected"
                continue
            fi
            [ -n "$first_missing" ] && continue
            value="${!expected}"
            validate_environment_value "$expected" "$value"
            [ -n "$value" ] || \
                die "empty configuration array member '$expected'"
            items+=("$value")
        done
        if [ -n "$first_missing" ]; then
            gap_member=""
            for name in "${member_names[@]}"; do
                if [[ ! -v expected_set[$name] ]]; then
                    gap_member="$name"
                    break
                fi
            done
            die "configuration array '$key' has a gap: found member '$gap_member' but '$first_missing' is missing"
        fi
        set_config_array "$key" "${items[@]}"
    done

    for name in "${names[@]}"; do
        [[ -v handled[$name] ]] || \
            die "unknown configuration variable '$name'"
    done

    validate_machine_config
}

validate_machine_config() {
    case "$EPHEMERAL_HOME" in
        true|false) ;;
        *) die "invalid EPHEMERAL_HOME (expected exactly true or false)" ;;
    esac
    validate_egress_allow
    validate_readonly_paths_lexical
}

validate_egress_allow() {
    local host

    for host in "${EGRESS_ALLOW[@]}"; do
        # Single-label names such as localhost or proxy are intentionally
        # rejected: this allowlist is for internet-routable domain names only.
        [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] || \
            die "invalid EGRESS_ALLOW host '$host' (use hostnames like github.com, without URLs, wildcards, or regex)"
    done
}

validate_readonly_paths_lexical() {
    local path seen
    declare -A seen=()

    for path in "${READONLY_PATHS[@]}"; do
        validate_project_mount_path_lexical "$path" || \
            die "invalid READONLY_PATHS path '$path' (use a non-empty project-relative path without dot segments, colons, or a trailing slash)"
        [[ ! -v seen[$path] ]] || die "duplicate READONLY_PATHS path: $path"
        seen["$path"]=1
    done
}

# Apply declared machine defaults to core-owned configuration.
set_config_array() {
    is_config_array_key "$1" || public_api_error "unknown array key '$1'"
    # shellcheck disable=SC2178 # Nameref to the validated array, not a scalar.
    local -n config_array_target="$1"
    shift
    # shellcheck disable=SC2034 # Assignment through a validated nameref.
    config_array_target=("$@")
}

apply_config_defaults() {
    local entry key value

    validate_public_api_declaration
    for entry in "${CONFIG_DEFAULTS[@]}"; do
        key="${entry%%=*}"
        value="${entry#*=}"
        if is_config_array_key "$key"; then
            set_config_array "$key"
        else
            printf -v "$key" '%s' "$value"
        fi
    done
}
