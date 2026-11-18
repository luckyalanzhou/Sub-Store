#!/bin/sh

VPS_COMMAND_NAME="${0##*/}"
VPS_CONFIG_FILE="${SUB_STORE_VPS_CONFIG:-/etc/sub-store-vps.conf}"
VPS_OS_RELEASE="${SUB_STORE_VPS_OS_RELEASE:-/etc/os-release}"
VPS_CONTAINER_NAME=sub-store
VPS_VOLUME_NAME=sub-store-data
VPS_DATA_TARGET=/opt/app/data
VPS_LOCK_DIRECTORY="${SUB_STORE_VPS_LOCK_DIRECTORY:-/run/sub-store-vps.lock}"
VPS_APT_KEYRING_FILE="${SUB_STORE_VPS_APT_KEYRING_FILE:-/etc/apt/keyrings/docker.asc}"
VPS_APT_SOURCE_FILE="${SUB_STORE_VPS_APT_SOURCE_FILE:-/etc/apt/sources.list.d/docker.sources}"
VPS_RPM_REPO_FILE="${SUB_STORE_VPS_RPM_REPO_FILE:-/etc/yum.repos.d/docker-ce.repo}"

vps_error() {
    printf '%s: %s\n' "$VPS_COMMAND_NAME" "$*" >&2
    return 1
}

vps_defaults() {
    FRONTEND_PORT=3001
    ACCESS_HOST=
    PUBLIC_URL=
    BACKEND_PORT=3000
    BACKEND_LAN_ACCESS=0
    API_PATH="$(vps_random_api_path)" || return 1
    IMAGE_REF=xream/sub-store:latest
    SYNC_CRON='55 23 * * *'
}

vps_random_api_path() {
    random_path="$(od -An -N24 -tx1 /dev/urandom | tr -d '[:space:]')" || return 1
    [ "${#random_path}" -eq 48 ] || {
        vps_error 'could not generate a 48-character API path'
        return 1
    }
    printf '%s\n' "$random_path"
}

vps_parse_install_args() {
    while [ "$#" -gt 0 ]; do
        option="$1"
        [ "$#" -ge 2 ] || {
            vps_error "missing value for $option"
            return 1
        }
        case "$option" in
            --frontend-port) FRONTEND_PORT="$2" ;;
            --access-host) ACCESS_HOST="$2" ;;
            --public-url) PUBLIC_URL="$2" ;;
            --backend-port) BACKEND_PORT="$2" ;;
            --backend-lan-access) BACKEND_LAN_ACCESS="$2" ;;
            --api-path)
                if [ "$2" = random ]; then
                    API_PATH="$(vps_random_api_path)" || return 1
                else
                    API_PATH="$2"
                fi
                ;;
            --image) IMAGE_REF="$2" ;;
            --sync-cron) SYNC_CRON="$2" ;;
            *)
                vps_error "unknown install option: $option"
                return 1
                ;;
        esac
        shift 2
    done
}

vps_prompt_line() {
    prompt_label="$1"
    prompt_default="$2"
    printf '%s [%s]: ' "$prompt_label" "$prompt_default" >&2
    IFS= read -r prompt_answer || return 1
    if [ -n "$prompt_answer" ]; then
        VPS_PROMPT_VALUE="$prompt_answer"
    else
        VPS_PROMPT_VALUE="$prompt_default"
    fi
}

vps_prompt_config() {
    [ -t 0 ] || return 0

    vps_prompt_line 'Frontend port' "$FRONTEND_PORT" || return 1
    FRONTEND_PORT="$VPS_PROMPT_VALUE"
    vps_prompt_line 'Public URL (optional)' "$PUBLIC_URL" || return 1
    PUBLIC_URL="$VPS_PROMPT_VALUE"
    vps_prompt_line 'Backend API port' "$BACKEND_PORT" || return 1
    BACKEND_PORT="$VPS_PROMPT_VALUE"
    vps_prompt_line 'Publish backend API on all interfaces (0/1; 1 exposes it publicly)' "$BACKEND_LAN_ACCESS" || return 1
    BACKEND_LAN_ACCESS="$VPS_PROMPT_VALUE"
    vps_prompt_line 'API path (48 hex characters)' "$API_PATH" || return 1
    API_PATH="$VPS_PROMPT_VALUE"
    if [ "$API_PATH" = random ]; then
        API_PATH="$(vps_random_api_path)" || return 1
    fi
    vps_prompt_line 'Official image reference' "$IMAGE_REF" || return 1
    IMAGE_REF="$VPS_PROMPT_VALUE"
    vps_prompt_line 'Sync schedule (five-field cron)' "$SYNC_CRON" || return 1
    SYNC_CRON="$VPS_PROMPT_VALUE"
}

vps_valid_cron() {
    printf '%s\n' "$1" | awk '
        function valid_field(field, minimum, maximum, items, count, i, parts, part_count, base, step, ranges, range_count, low, high, number) {
            if (field == "" || field ~ /(^,|,$|,,)/) return 0
            count = split(field, items, ",")
            for (i = 1; i <= count; i++) {
                part_count = split(items[i], parts, "/")
                if (part_count > 2) return 0
                base = parts[1]
                if (part_count == 2) {
                    step = parts[2]
                    if (step !~ /^[0-9]+$/ || step + 0 < 1) return 0
                }
                if (base == "*") continue
                range_count = split(base, ranges, "-")
                if (range_count == 1) {
                    if (base !~ /^[0-9]+$/) return 0
                    number = base + 0
                    if (number < minimum || number > maximum) return 0
                } else if (range_count == 2) {
                    if (ranges[1] !~ /^[0-9]+$/ || ranges[2] !~ /^[0-9]+$/) return 0
                    low = ranges[1] + 0
                    high = ranges[2] + 0
                    if (low < minimum || high > maximum || low > high) return 0
                } else {
                    return 0
                }
            }
            return 1
        }
        NF != 5 { exit 1 }
        !valid_field($1, 0, 59) || !valid_field($2, 0, 23) || !valid_field($3, 1, 31) ||
        !valid_field($4, 1, 12) || !valid_field($5, 0, 7) { exit 1 }
        { exit 0 }
    '
}

vps_validate_host() {
    host_value="$1"
    [ -n "$host_value" ] || return 0
    [ "${#host_value}" -le 253 ] || return 1
    case "$host_value" in
        *[!A-Za-z0-9.-]*|.*|*.|-*|*-|*..*|*-.*|*.-*) return 1 ;;
    esac
    return 0
}

vps_validate_config() {
    case "$FRONTEND_PORT" in ''|*[!0-9]*) vps_error 'frontend port must be an integer'; return 1 ;; esac
    case "$BACKEND_PORT" in ''|*[!0-9]*) vps_error 'backend port must be an integer'; return 1 ;; esac
    [ "${#FRONTEND_PORT}" -le 5 ] && [ "${#BACKEND_PORT}" -le 5 ] || {
        vps_error 'ports must be between 1 and 65535'
        return 1
    }
    FRONTEND_PORT="$(vps_normalize_decimal "$FRONTEND_PORT")"
    BACKEND_PORT="$(vps_normalize_decimal "$BACKEND_PORT")"
    [ "$FRONTEND_PORT" -ge 1 ] && [ "$FRONTEND_PORT" -le 65535 ] || {
        vps_error 'frontend port must be between 1 and 65535'
        return 1
    }
    [ "$BACKEND_PORT" -ge 1 ] && [ "$BACKEND_PORT" -le 65535 ] || {
        vps_error 'backend port must be between 1 and 65535'
        return 1
    }
    [ "$FRONTEND_PORT" -ne "$BACKEND_PORT" ] || {
        vps_error 'frontend and backend ports must be different'
        return 1
    }
    case "$BACKEND_LAN_ACCESS" in 0|1) ;; *) vps_error 'backend LAN access must be 0 or 1'; return 1 ;; esac
    vps_validate_host "$ACCESS_HOST" || {
        vps_error 'access host must be a hostname or IPv4 address without protocol or port'
        return 1
    }
    if [ -n "$PUBLIC_URL" ]; then
        printf '%s\n' "$PUBLIC_URL" | grep -Eq '^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[^?#[:space:]]*)?$' || {
            vps_error 'public URL must be HTTP or HTTPS without a query or fragment'
            return 1
        }
        public_authority="${PUBLIC_URL#*://}"
        public_authority="${public_authority%%/*}"
        public_host="${public_authority%%:*}"
        vps_validate_host "$public_host" || {
            vps_error 'public URL contains an invalid hostname'
            return 1
        }
        public_port="${public_authority##*:}"
        if [ "$public_port" != "$public_authority" ]; then
            case "$public_port" in ''|*[!0-9]*) vps_error 'public URL port must be an integer'; return 1 ;; esac
            [ "${#public_port}" -le 5 ] || {
                vps_error 'public URL port must be between 1 and 65535'
                return 1
            }
            public_port="$(vps_normalize_decimal "$public_port")"
            [ "$public_port" -ge 1 ] && [ "$public_port" -le 65535 ] || {
                vps_error 'public URL port must be between 1 and 65535'
                return 1
            }
        fi
    fi
    [ "${#API_PATH}" -eq 48 ] || {
        vps_error 'API path must contain 48 hexadecimal characters'
        return 1
    }
    case "$API_PATH" in *[!0123456789abcdefABCDEF]*) vps_error 'API path must be hexadecimal'; return 1 ;; esac
    printf '%s\n' "$IMAGE_REF" | grep -Eq '^(docker\.io/)?xream/sub-store(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}|@sha256:[a-f0-9]{64})?$' || {
        vps_error 'image must use the official xream/sub-store repository'
        return 1
    }
    vps_valid_cron "$SYNC_CRON" || {
        vps_error 'sync cron must be a valid five-field expression'
        return 1
    }
}

vps_normalize_decimal() {
    decimal_value="$1"
    while [ "${#decimal_value}" -gt 1 ] && [ "${decimal_value#0}" != "$decimal_value" ]; do
        decimal_value="${decimal_value#0}"
    done
    printf '%s\n' "$decimal_value"
}

vps_path_contains_symlink() {
    checked_path="$1"
    case "$checked_path" in /*) ;; *) return 0 ;; esac
    checked_prefix=
    checked_remainder="${checked_path#/}"
    while [ -n "$checked_remainder" ]; do
        checked_component="${checked_remainder%%/*}"
        if [ "$checked_component" = "$checked_remainder" ]; then
            checked_remainder=
        else
            checked_remainder="${checked_remainder#*/}"
        fi
        [ -n "$checked_component" ] || continue
        checked_prefix="$checked_prefix/$checked_component"
        [ ! -L "$checked_prefix" ] || return 0
    done
    return 1
}

vps_directory_is_safe() {
    safe_directory="$1"
    [ -d "$safe_directory" ] && [ ! -L "$safe_directory" ] || return 1
    vps_path_contains_symlink "$safe_directory" && return 1
    safe_directory_owner="$(stat -c '%u' "$safe_directory" 2>/dev/null)" || return 1
    safe_directory_mode="$(stat -c '%a' "$safe_directory" 2>/dev/null)" || return 1
    safe_directory_uid="$(id -u 2>/dev/null)" || return 1
    case "$safe_directory_mode" in ''|*[!0-7]*) return 1 ;; esac
    safe_directory_mode_number=$((0$safe_directory_mode))
    [ "$safe_directory_owner" = "$safe_directory_uid" ] &&
        [ $((safe_directory_mode_number & 022)) -eq 0 ]
}

vps_config_file_is_safe() {
    [ -f "$VPS_CONFIG_FILE" ] && [ ! -L "$VPS_CONFIG_FILE" ] || return 1
    config_directory="${VPS_CONFIG_FILE%/*}"
    [ "$config_directory" != "$VPS_CONFIG_FILE" ] || config_directory=.
    vps_directory_is_safe "$config_directory" || return 1
    vps_path_contains_symlink "$VPS_CONFIG_FILE" && return 1
    config_owner="$(stat -c '%u' "$VPS_CONFIG_FILE" 2>/dev/null)" || return 1
    config_mode="$(stat -c '%a' "$VPS_CONFIG_FILE" 2>/dev/null)" || return 1
    current_owner="$(id -u)" || return 1
    [ "$config_owner" = "$current_owner" ] && [ "$config_mode" = 600 ]
}

vps_lock_directory_is_safe() {
    [ -d "$VPS_LOCK_DIRECTORY" ] && [ ! -L "$VPS_LOCK_DIRECTORY" ] || return 1
    vps_path_contains_symlink "$VPS_LOCK_DIRECTORY" && return 1
    lock_directory_owner="$(stat -c '%u' "$VPS_LOCK_DIRECTORY" 2>/dev/null)" || return 1
    lock_directory_mode="$(stat -c '%a' "$VPS_LOCK_DIRECTORY" 2>/dev/null)" || return 1
    lock_directory_uid="$(id -u 2>/dev/null)" || return 1
    [ "$lock_directory_owner" = "$lock_directory_uid" ] && [ "$lock_directory_mode" = 700 ]
}

vps_lock_pid_file_is_safe() {
    lock_pid_file="$VPS_LOCK_DIRECTORY/pid"
    [ -f "$lock_pid_file" ] && [ ! -L "$lock_pid_file" ] || return 1
    vps_path_contains_symlink "$lock_pid_file" && return 1
    lock_pid_owner="$(stat -c '%u' "$lock_pid_file" 2>/dev/null)" || return 1
    lock_pid_mode="$(stat -c '%a' "$lock_pid_file" 2>/dev/null)" || return 1
    lock_pid_uid="$(id -u 2>/dev/null)" || return 1
    [ "$lock_pid_owner" = "$lock_pid_uid" ] && [ "$lock_pid_mode" = 600 ]
}

vps_read_operation_lock_pid() {
    vps_lock_pid_file_is_safe || return 1
    VPS_LOCK_OWNER_PID="$(cat "$VPS_LOCK_DIRECTORY/pid" 2>/dev/null)" || return 1
    case "$VPS_LOCK_OWNER_PID" in ''|*[!0-9]*) return 1 ;; esac
    VPS_LOCK_OWNER_PID="$(vps_normalize_decimal "$VPS_LOCK_OWNER_PID")"
    [ "$VPS_LOCK_OWNER_PID" != 0 ]
}

vps_create_operation_lock() {
    (umask 077; mkdir "$VPS_LOCK_DIRECTORY" 2>/dev/null) || return 1
    if ! chmod 700 "$VPS_LOCK_DIRECTORY" || ! vps_lock_directory_is_safe; then
        rmdir "$VPS_LOCK_DIRECTORY" 2>/dev/null || :
        vps_error 'operation lock directory has unsafe ownership or permissions'
        return 1
    fi
    if ! (umask 077; printf '%s\n' "$$" > "$VPS_LOCK_DIRECTORY/pid"); then
        rmdir "$VPS_LOCK_DIRECTORY" 2>/dev/null || :
        vps_error 'could not write operation lock owner'
        return 1
    fi
    if ! chmod 600 "$VPS_LOCK_DIRECTORY/pid" || ! vps_read_operation_lock_pid; then
        rm -f "$VPS_LOCK_DIRECTORY/pid"
        rmdir "$VPS_LOCK_DIRECTORY" 2>/dev/null || :
        vps_error 'could not secure operation lock owner'
        return 1
    fi
    return 0
}

vps_acquire_operation_lock() {
    vps_path_contains_symlink "$VPS_LOCK_DIRECTORY" && {
        vps_error 'operation lock path contains a symlink'
        return 1
    }
    if vps_create_operation_lock; then return 0; fi
    [ -e "$VPS_LOCK_DIRECTORY" ] || {
        vps_error 'could not create operation lock; check that its parent directory exists'
        return 1
    }
    vps_lock_directory_is_safe || {
        vps_error 'operation lock directory has unsafe ownership or permissions'
        return 1
    }
    vps_read_operation_lock_pid || {
        vps_error 'operation lock state is invalid; inspect it before removing it'
        return 1
    }
    if kill -0 "$VPS_LOCK_OWNER_PID" 2>/dev/null; then
        vps_error "another Sub-Store operation is running (PID $VPS_LOCK_OWNER_PID)"
        return 1
    fi
    rm -f "$VPS_LOCK_DIRECTORY/pid" && rmdir "$VPS_LOCK_DIRECTORY" 2>/dev/null || {
        vps_error 'could not clear stale operation lock safely'
        return 1
    }
    vps_create_operation_lock || {
        vps_error 'another Sub-Store operation acquired the lock; retry the command'
        return 1
    }
}

vps_release_operation_lock() {
    vps_lock_directory_is_safe && vps_read_operation_lock_pid || {
        vps_error 'operation lock changed or became unsafe; leaving it in place'
        return 1
    }
    [ "$VPS_LOCK_OWNER_PID" = "$$" ] || {
        vps_error 'operation lock is owned by another process; leaving it in place'
        return 1
    }
    rm -f "$VPS_LOCK_DIRECTORY/pid" && rmdir "$VPS_LOCK_DIRECTORY" || {
        vps_error 'could not release operation lock'
        return 1
    }
}

vps_load_config() {
    [ -e "$VPS_CONFIG_FILE" ] || return 0
    vps_config_file_is_safe || {
        vps_error 'configuration file must be a regular, current-user-owned mode 600 file'
        return 1
    }
    config_keys_seen=' '
    while IFS= read -r config_line || [ -n "$config_line" ]; do
        case "$config_line" in *=*) ;; *) vps_error 'malformed configuration line'; return 1 ;; esac
        config_key="${config_line%%=*}"
        config_value="${config_line#*=}"
        case "$config_key" in
            FRONTEND_PORT|ACCESS_HOST|PUBLIC_URL|BACKEND_PORT|BACKEND_LAN_ACCESS|API_PATH|IMAGE_REF|SYNC_CRON) ;;
            *) vps_error "unknown configuration key: $config_key"; return 1 ;;
        esac
        case "$config_keys_seen" in *" $config_key "*)
            vps_error "duplicate configuration key: $config_key"
            return 1
            ;;
        esac
        config_keys_seen="${config_keys_seen}${config_key} "
        case "$config_key" in
            FRONTEND_PORT) FRONTEND_PORT="$config_value" ;;
            ACCESS_HOST) ACCESS_HOST="$config_value" ;;
            PUBLIC_URL) PUBLIC_URL="$config_value" ;;
            BACKEND_PORT) BACKEND_PORT="$config_value" ;;
            BACKEND_LAN_ACCESS) BACKEND_LAN_ACCESS="$config_value" ;;
            API_PATH) API_PATH="$config_value" ;;
            IMAGE_REF) IMAGE_REF="$config_value" ;;
            SYNC_CRON) SYNC_CRON="$config_value" ;;
        esac
    done < "$VPS_CONFIG_FILE"
    for required_config_key in FRONTEND_PORT ACCESS_HOST PUBLIC_URL BACKEND_PORT BACKEND_LAN_ACCESS API_PATH IMAGE_REF SYNC_CRON; do
        case "$config_keys_seen" in *" $required_config_key "*) ;;
            *) vps_error "configuration is missing required key: $required_config_key"; return 1 ;;
        esac
    done
    vps_validate_config
}

vps_save_config() {
    vps_validate_config || return 1
    config_directory="${VPS_CONFIG_FILE%/*}"
    [ "$config_directory" != "$VPS_CONFIG_FILE" ] || config_directory=.
    vps_directory_is_safe "$config_directory" || {
        vps_error 'configuration directory must be owned by the current user, not writable by group/others, and have no symlink components'
        return 1
    }
    if [ -e "$VPS_CONFIG_FILE" ] || [ -L "$VPS_CONFIG_FILE" ]; then
        vps_config_file_is_safe || {
            vps_error 'refusing to replace an unsafe configuration file'
            return 1
        }
    fi
    config_temporary="$(mktemp "${VPS_CONFIG_FILE}.tmp.XXXXXX")" || {
        vps_error 'could not create a temporary configuration file'
        return 1
    }
    if ! (umask 077; printf '%s\n' \
        "FRONTEND_PORT=$FRONTEND_PORT" \
        "ACCESS_HOST=$ACCESS_HOST" \
        "PUBLIC_URL=$PUBLIC_URL" \
        "BACKEND_PORT=$BACKEND_PORT" \
        "BACKEND_LAN_ACCESS=$BACKEND_LAN_ACCESS" \
        "API_PATH=$API_PATH" \
        "IMAGE_REF=$IMAGE_REF" \
        "SYNC_CRON=$SYNC_CRON" > "$config_temporary"); then
        rm -f "$config_temporary"
        vps_error 'could not write configuration'
        return 1
    fi
    chmod 600 "$config_temporary" || {
        rm -f "$config_temporary"
        vps_error 'could not secure configuration permissions'
        return 1
    }
    mv -f "$config_temporary" "$VPS_CONFIG_FILE" || {
        rm -f "$config_temporary"
        vps_error 'could not atomically replace configuration'
        return 1
    }
}

vps_show_config() {
    printf 'FRONTEND_PORT=%s\n' "$FRONTEND_PORT"
    printf 'ACCESS_HOST=%s\n' "$ACCESS_HOST"
    printf 'PUBLIC_URL=%s\n' "$PUBLIC_URL"
    printf 'BACKEND_PORT=%s\n' "$BACKEND_PORT"
    printf 'BACKEND_LAN_ACCESS=%s\n' "$BACKEND_LAN_ACCESS"
    printf 'API_PATH=<hidden>\n'
    printf 'IMAGE_REF=%s\n' "$IMAGE_REF"
    printf 'SYNC_CRON=%s\n' "$SYNC_CRON"
}

vps_print_api_path() {
    printf '%s\n' "$API_PATH"
}

vps_api_path_set() {
    [ "$#" -eq 1 ] || {
        vps_error 'usage: api-path set <48-hex-path>'
        return 1
    }
    previous_api_path="$API_PATH"
    API_PATH="$1"
    vps_validate_config || {
        API_PATH="$previous_api_path"
        return 1
    }
    vps_apply_config || {
        API_PATH="$previous_api_path"
        return 1
    }
    if ! vps_save_config; then
        API_PATH="$previous_api_path"
        vps_apply_config || vps_error 'could not restore the previous API path'
        return 1
    fi
}

vps_api_path_rotate() {
    rotated_api_path="$(vps_random_api_path)" || return 1
    vps_api_path_set "$rotated_api_path"
}

vps_parse_os_release() {
    VPS_OS_ID=
    VPS_OS_VERSION=
    VPS_OS_CODENAME=
    VPS_OS_NAME=
    VPS_OS_VARIANT=
    [ -r "$VPS_OS_RELEASE" ] || {
        vps_error "cannot read $VPS_OS_RELEASE"
        return 1
    }
    while IFS= read -r os_line || [ -n "$os_line" ]; do
        case "$os_line" in *=*) ;; *) continue ;; esac
        os_key="${os_line%%=*}"
        os_value="${os_line#*=}"
        case "$os_value" in
            \"*\") os_value="${os_value#\"}"; os_value="${os_value%\"}" ;;
            \'*\') os_value="${os_value#\'}"; os_value="${os_value%\'}" ;;
        esac
        case "$os_key" in
            ID) VPS_OS_ID="$os_value" ;;
            VERSION_ID) VPS_OS_VERSION="$os_value" ;;
            VERSION_CODENAME) VPS_OS_CODENAME="$os_value" ;;
            UBUNTU_CODENAME) [ -n "$VPS_OS_CODENAME" ] || VPS_OS_CODENAME="$os_value" ;;
            NAME) VPS_OS_NAME="$os_value" ;;
            VARIANT_ID) VPS_OS_VARIANT="$os_value" ;;
        esac
    done < "$VPS_OS_RELEASE"
}

vps_has_command() {
    command -v "$1" >/dev/null 2>&1
}

vps_detect_platform() {
    vps_parse_os_release || return 1
    VPS_DOCKER_DISTRO=
    VPS_PACKAGE_FAMILY=
    case "$VPS_OS_ID" in
        ubuntu)
            case "$VPS_OS_VERSION" in 22.04|24.04|26.04|26.10) ;; *) vps_error "unsupported Ubuntu version: ${VPS_OS_VERSION:-unknown}"; return 1 ;; esac
            VPS_DOCKER_DISTRO=ubuntu
            VPS_PACKAGE_FAMILY=apt
            ;;
        debian)
            case "$VPS_OS_VERSION" in 12|13|12.*|13.*) ;; *) vps_error "unsupported Debian version: ${VPS_OS_VERSION:-unknown}"; return 1 ;; esac
            VPS_DOCKER_DISTRO=debian
            VPS_PACKAGE_FAMILY=apt
            ;;
        fedora)
            case "$VPS_OS_VERSION" in 43|44|45|43.*|44.*|45.*) ;; *) vps_error "unsupported Fedora version: ${VPS_OS_VERSION:-unknown}"; return 1 ;; esac
            VPS_DOCKER_DISTRO=fedora
            VPS_PACKAGE_FAMILY=rpm
            ;;
        centos)
            case "$VPS_OS_NAME $VPS_OS_VARIANT" in *Stream*) ;; *) vps_error 'only CentOS Stream is supported'; return 1 ;; esac
            case "$VPS_OS_VERSION" in 9|10|9.*|10.*) ;; *) vps_error "unsupported CentOS Stream version: ${VPS_OS_VERSION:-unknown}"; return 1 ;; esac
            VPS_DOCKER_DISTRO=centos
            VPS_PACKAGE_FAMILY=rpm
            ;;
        rhel)
            case "$VPS_OS_VERSION" in 8|9|10|8.*|9.*|10.*) ;; *) vps_error "unsupported RHEL version: ${VPS_OS_VERSION:-unknown}"; return 1 ;; esac
            VPS_DOCKER_DISTRO=rhel
            VPS_PACKAGE_FAMILY=rpm
            ;;
        almalinux)
            case "$VPS_OS_VERSION" in 8|9|10|8.*|9.*|10.*) ;; *) vps_error "unsupported AlmaLinux version: ${VPS_OS_VERSION:-unknown}"; return 1 ;; esac
            VPS_DOCKER_DISTRO=alma
            VPS_PACKAGE_FAMILY=rpm
            ;;
        rocky)
            case "$VPS_OS_VERSION" in 8|9|10|8.*|9.*|10.*) ;; *) vps_error "unsupported Rocky Linux version: ${VPS_OS_VERSION:-unknown}"; return 1 ;; esac
            VPS_DOCKER_DISTRO=rocky
            VPS_PACKAGE_FAMILY=rpm
            ;;
        ol)
            case "$VPS_OS_VERSION" in 8|9|10|8.*|9.*|10.*) ;; *) vps_error "unsupported Oracle Linux version: ${VPS_OS_VERSION:-unknown}"; return 1 ;; esac
            VPS_DOCKER_DISTRO=oracle
            VPS_PACKAGE_FAMILY=rpm
            ;;
        *)
            vps_error "unsupported Linux distribution: ${VPS_OS_ID:-unknown}"
            return 1
            ;;
    esac
    case "$VPS_PACKAGE_FAMILY" in
        apt) vps_has_command apt-get || { vps_error 'apt-get is required'; return 1; } ;;
        rpm) if ! vps_has_command dnf && ! vps_has_command yum; then vps_error 'dnf or yum is required'; return 1; fi ;;
    esac
    case "$VPS_DOCKER_DISTRO" in
        ubuntu|debian) VPS_DOCKER_REPO_URL="https://download.docker.com/linux/$VPS_DOCKER_DISTRO" ;;
        *) VPS_DOCKER_REPO_URL="https://download.docker.com/linux/$VPS_DOCKER_DISTRO" ;;
    esac
    export VPS_OS_ID VPS_OS_VERSION VPS_OS_CODENAME VPS_DOCKER_DISTRO VPS_PACKAGE_FAMILY VPS_DOCKER_REPO_URL
}

vps_package_installed() {
    checked_package="$1"
    case "$VPS_PACKAGE_FAMILY" in
        apt)
            vps_has_command dpkg-query || {
                vps_error 'dpkg-query is required to check for conflicting container packages'
                return 2
            }
            package_status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$checked_package" 2>/dev/null || true)"
            case "$package_status" in ii*|hi*) return 0 ;; esac
            return 1
            ;;
        rpm)
            vps_has_command rpm || {
                vps_error 'rpm is required to check for conflicting container packages'
                return 2
            }
            rpm -q "$checked_package" >/dev/null 2>&1
            ;;
        *) vps_error 'unsupported package family while checking container conflicts'; return 2 ;;
    esac
}

vps_refuse_conflicting_runtime_packages() {
    case "$VPS_PACKAGE_FAMILY" in
        apt) conflicting_packages='docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc' ;;
        rpm) conflicting_packages='docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine docker-selinux docker-engine-selinux podman-docker podman containerd runc' ;;
        *) vps_error 'unsupported package family while checking container conflicts'; return 1 ;;
    esac
    for conflicting_package in $conflicting_packages; do
        if vps_package_installed "$conflicting_package"; then
            vps_error "conflicting package '$conflicting_package' is installed; remove or resolve it manually before installing Docker (no packages were removed)"
            return 1
        else
            package_check_status=$?
            [ "$package_check_status" -eq 1 ] || return "$package_check_status"
        fi
    done
}

vps_download_file() {
    download_url="$1"
    download_target="$2"
    if vps_has_command curl; then
        curl -fsSL "$download_url" -o "$download_target"
    elif vps_has_command wget; then
        wget -qO "$download_target" "$download_url"
    else
        vps_error 'curl or wget is required to download Docker repository metadata'
        return 1
    fi
}

vps_install_docker_apt() {
    [ -n "$VPS_OS_CODENAME" ] || {
        vps_error 'OS release does not provide a repository codename'
        return 1
    }
    apt-get update || return 1
    apt-get install -y ca-certificates || return 1
    if ! vps_has_command curl && ! vps_has_command wget; then
        apt-get install -y curl || return 1
    fi
    key_directory="${VPS_APT_KEYRING_FILE%/*}"
    source_directory="${VPS_APT_SOURCE_FILE%/*}"
    vps_path_contains_symlink "$key_directory" && { vps_error 'Docker APT keyring path contains a symlink'; return 1; }
    vps_path_contains_symlink "$source_directory" && { vps_error 'Docker APT source path contains a symlink'; return 1; }
    install -m 0755 -d "$key_directory" "$source_directory" || return 1
    vps_directory_is_safe "$key_directory" && vps_directory_is_safe "$source_directory" || {
        vps_error 'Docker APT repository directories are unsafe'
        return 1
    }
    [ ! -L "$VPS_APT_KEYRING_FILE" ] && [ ! -L "$VPS_APT_SOURCE_FILE" ] || {
        vps_error 'refusing to replace a symlinked Docker APT repository file'
        return 1
    }
    key_temporary="$(mktemp "${VPS_APT_KEYRING_FILE}.tmp.XXXXXX")" || return 1
    if ! vps_download_file "$VPS_DOCKER_REPO_URL/gpg" "$key_temporary"; then
        rm -f "$key_temporary"
        return 1
    fi
    chmod 0644 "$key_temporary" && mv -f "$key_temporary" "$VPS_APT_KEYRING_FILE" || {
        rm -f "$key_temporary"
        return 1
    }
    apt_arch="$(dpkg --print-architecture 2>/dev/null)" || return 1
    case "$apt_arch" in ''|*[!a-z0-9-]*) vps_error 'could not determine a valid APT architecture'; return 1 ;; esac
    source_temporary="$(mktemp "${VPS_APT_SOURCE_FILE}.tmp.XXXXXX")" || return 1
    if ! (umask 022; printf '%s\n' \
        'Types: deb' \
        "URIs: $VPS_DOCKER_REPO_URL" \
        "Suites: $VPS_OS_CODENAME" \
        'Components: stable' \
        "Architectures: $apt_arch" \
        "Signed-By: $VPS_APT_KEYRING_FILE" > "$source_temporary"); then
        rm -f "$source_temporary"
        return 1
    fi
    chmod 0644 "$source_temporary" && mv -f "$source_temporary" "$VPS_APT_SOURCE_FILE" || {
        rm -f "$source_temporary"
        return 1
    }
    apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

vps_install_docker_rpm() {
    repo_directory="${VPS_RPM_REPO_FILE%/*}"
    vps_path_contains_symlink "$repo_directory" && { vps_error 'Docker RPM repository path contains a symlink'; return 1; }
    [ -d "$repo_directory" ] || mkdir -p "$repo_directory" || return 1
    vps_directory_is_safe "$repo_directory" && [ ! -L "$VPS_RPM_REPO_FILE" ] || {
        vps_error 'refusing to replace a symlinked Docker RPM repository path'
        return 1
    }
    repo_temporary="$(mktemp "${VPS_RPM_REPO_FILE}.tmp.XXXXXX")" || return 1
    if ! vps_download_file "$VPS_DOCKER_REPO_URL/docker-ce.repo" "$repo_temporary"; then
        rm -f "$repo_temporary"
        return 1
    fi
    chmod 0644 "$repo_temporary" && mv -f "$repo_temporary" "$VPS_RPM_REPO_FILE" || {
        rm -f "$repo_temporary"
        return 1
    }
    if vps_has_command dnf; then
        dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
        yum -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
}

vps_docker() {
    docker "$@"
}

vps_guard_local_target() {
    [ -z "${DOCKER_HOST:-}" ] && [ -z "${DOCKER_CONTEXT:-}" ] || {
        vps_error 'DOCKER_HOST and DOCKER_CONTEXT must be unset; remote Docker targets are refused'
        return 1
    }
    vps_has_command docker || return 0
    context_name="$(vps_docker context show 2>/dev/null)" || {
        vps_error 'could not verify the Docker context'
        return 1
    }
    [ "$context_name" = default ] || {
        vps_error "Docker context '$context_name' is not the local default context"
        return 1
    }
    context_endpoint="$(vps_docker context inspect default --format '{{ (index .Endpoints "docker").Host }}' 2>/dev/null)" || {
        vps_error 'could not verify the default Docker endpoint'
        return 1
    }
    case "$context_endpoint" in unix:///*) ;; *) vps_error 'default Docker context must use a local Unix socket'; return 1 ;; esac
}

vps_docker_info() {
    vps_guard_local_target || return 1
    docker_info="$(vps_docker info 2>&1)" || {
        vps_error 'Docker Engine is not responding'
        return 1
    }
    [ -n "$docker_info" ] || { vps_error 'Docker Engine returned empty server information'; return 1; }
    docker_version_text="$(vps_docker version 2>&1)" || {
        vps_error 'Docker Engine version query failed'
        return 1
    }
    if printf '%s\n%s\n' "$docker_info" "$docker_version_text" | grep -qi podman; then
        vps_error 'Podman-compatible engines are not supported'
        return 1
    fi
    docker_version="$(vps_docker version --format '{{.Server.Version}}' 2>/dev/null)" || {
        vps_error 'could not read the Docker Engine version'
        return 1
    }
    [ -n "$docker_version" ] || { vps_error 'Docker Engine returned an empty version'; return 1; }
    VPS_DOCKER_INFO="$docker_version"
}

vps_service_start() {
    if vps_has_command systemctl; then
        systemctl enable --now docker
    elif vps_has_command service; then
        service docker start
    else
        vps_error 'systemctl or service is required to start Docker'
        return 1
    fi
}

vps_ensure_local_docker() {
    vps_guard_local_target || return 1
    if vps_docker_info 2>/dev/null; then return 0; fi
    vps_service_start || return 1
    vps_docker_info
}

vps_install_docker() {
    VPS_DOCKER_INSTALLED_BY_SCRIPT=0
    [ -z "${DOCKER_HOST:-}" ] && [ -z "${DOCKER_CONTEXT:-}" ] || {
        vps_error 'DOCKER_HOST and DOCKER_CONTEXT must be unset; remote Docker targets are refused'
        return 1
    }
    if vps_has_command docker; then
        vps_guard_local_target || return 1
        if vps_docker_info 2>/dev/null; then
            return 0
        fi
        if vps_has_command dockerd; then
            vps_service_start || return 1
            vps_docker_info || return 1
            return 0
        fi
    fi
    if vps_has_command podman; then
        vps_error 'Podman is already installed; refusing to replace or overlap the existing container runtime'
        return 1
    fi
    vps_detect_platform || return 1
    vps_refuse_conflicting_runtime_packages || return 1
    case "$VPS_PACKAGE_FAMILY" in
        apt) vps_install_docker_apt || return 1 ;;
        rpm) vps_install_docker_rpm || return 1 ;;
        *) vps_error 'unsupported package family'; return 1 ;;
    esac
    VPS_DOCKER_INSTALLED_BY_SCRIPT=1
    vps_service_start || return 1
    vps_docker_info || return 1
}

vps_route_ipv4() {
    vps_has_command ip || return 1
    ip -4 route get 1.1.1.1 2>/dev/null | awk '
        { for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }
    '
}

vps_is_private_ipv4() {
    private_ip="$1"
    case "$private_ip" in
        10.*|127.*|169.254.*|192.168.*|0.*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
        172.*)
            private_second="${private_ip#172.}"
            private_second="${private_second%%.*}"
            case "$private_second" in 1[6-9]|2[0-9]|3[01]) return 0 ;; esac
            ;;
    esac
    return 1
}

vps_has_tty() {
    [ -t 0 ]
}

vps_configure_access_host() {
    [ -n "${ACCESS_HOST:-}" ] && return 0
    [ -n "${PUBLIC_URL:-}" ] && return 0
    route_ipv4="$(vps_route_ipv4 || true)"
    if vps_has_tty; then
        prompt_default="$route_ipv4"
        if [ -z "$route_ipv4" ] || vps_is_private_ipv4 "$route_ipv4"; then
            prompt_default=
            printf 'No public default-route IPv4 was detected. Enter a public IP or DDNS hostname.\n' >&2
        fi
        vps_prompt_line 'DDNS hostname or public IPv4 (Enter uses detected route IPv4)' "$prompt_default" || return 1
        ACCESS_HOST="$VPS_PROMPT_VALUE"
        if [ -z "$ACCESS_HOST" ] && { [ -z "$route_ipv4" ] || vps_is_private_ipv4 "$route_ipv4"; }; then
            vps_error 'a public IP or DDNS hostname is required for an interactive install'
            return 1
        fi
    elif [ -n "$route_ipv4" ] && ! vps_is_private_ipv4 "$route_ipv4"; then
        ACCESS_HOST="$route_ipv4"
    fi
    ACCESS_HOST="${ACCESS_HOST:-}"
    vps_validate_host "$ACCESS_HOST" || {
        vps_error 'access host must be a hostname or public IPv4 address'
        return 1
    }
}

vps_container_exists() {
    vps_docker inspect "$VPS_CONTAINER_NAME" >/dev/null 2>&1
}

vps_container_state() {
    vps_docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null
}

vps_container_health() {
    vps_docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null
}

vps_verify_managed_container() {
    target_name="${1:-$VPS_CONTAINER_NAME}"
    [ -e "$VPS_CONFIG_FILE" ] || {
        vps_error "container $target_name exists without this tool's configuration; refusing to adopt it"
        return 1
    }
    vps_config_file_is_safe || {
        vps_error 'configuration file is unsafe; refusing to manage existing container'
        return 1
    }
    container_metadata="$(vps_docker inspect -f '{{.Config.Image}}|{{index .Config.Labels "io.sub-store-vps.managed"}}|{{index .Config.Labels "io.sub-store-vps.image-ref"}}|{{range .Mounts}}{{if eq .Destination "/opt/app/data"}}{{.Type}}:{{.Name}}{{end}}{{end}}' "$target_name" 2>/dev/null)" || {
        vps_error "could not inspect container $target_name"
        return 1
    }
    container_image="${container_metadata%%|*}"
    remaining_metadata="${container_metadata#*|}"
    container_label="${remaining_metadata%%|*}"
    remaining_metadata="${remaining_metadata#*|}"
    container_source_ref="${remaining_metadata%%|*}"
    container_mount="${remaining_metadata#*|}"
    case "$container_image" in
        xream/sub-store|xream/sub-store:*|xream/sub-store@sha256:*|docker.io/xream/sub-store|docker.io/xream/sub-store:*|docker.io/xream/sub-store@sha256:*) ;;
        sha256:[0-9a-f][0-9a-f]*)
            printf '%s\n' "$container_image" | grep -Eq '^sha256:[0-9a-f]{64}$' || {
                vps_error "container $target_name has an invalid immutable image ID"
                return 1
            }
            ;;
        *) vps_error "container $target_name is not using the official xream/sub-store image"; return 1 ;;
    esac
    [ "$container_label" = true ] || {
        vps_error "container $target_name is not marked as managed by this VPS tool"
        return 1
    }
    printf '%s\n' "$container_source_ref" | grep -Eq '^(docker\.io/)?xream/sub-store(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}|@sha256:[a-f0-9]{64})?$' || {
        vps_error "container $target_name is not labeled with an official image reference"
        return 1
    }
    [ "$container_mount" = "volume:$VPS_VOLUME_NAME" ] || {
        vps_error "container $target_name does not use the managed $VPS_VOLUME_NAME data volume"
        return 1
    }
}

vps_ensure_data_volume() {
    if vps_docker volume inspect "$VPS_VOLUME_NAME" >/dev/null 2>&1; then
        volume_label="$(vps_docker volume inspect -f '{{index .Labels "io.sub-store-vps.managed"}}' "$VPS_VOLUME_NAME" 2>/dev/null)" || return 1
        [ "$volume_label" = true ] || {
            vps_error "volume $VPS_VOLUME_NAME already exists and is not managed by this tool; refusing to adopt it"
            return 1
        }
        return 0
    fi
    vps_docker volume create --label io.sub-store-vps.managed=true "$VPS_VOLUME_NAME" >/dev/null
}

vps_check_host_ports() {
    for requested_port in "$FRONTEND_PORT" "$BACKEND_PORT"; do
        if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | awk -v port="$requested_port" '
            NR > 1 { local_address = $4; sub(/^.*:/, "", local_address); if (local_address == port) found = 1 }
            END { exit found ? 0 : 1 }
        '; then
            vps_error "requested host port $requested_port is already in use"
            return 1
        elif command -v netstat >/dev/null 2>&1 && netstat -lnt 2>/dev/null | awk -v port="$requested_port" '
            NR > 1 { local_address = $4; sub(/^.*:/, "", local_address); if (local_address == port) found = 1 }
            END { exit found ? 0 : 1 }
        '; then
            vps_error "requested host port $requested_port is already in use"
            return 1
        fi
    done
}

vps_cors_origins() {
    cors_origins="http://127.0.0.1:$FRONTEND_PORT,http://localhost:$FRONTEND_PORT"
    if [ -n "$ACCESS_HOST" ]; then
        cors_origins="$cors_origins,http://$ACCESS_HOST:$FRONTEND_PORT"
    fi
    if [ -n "$PUBLIC_URL" ]; then
        public_origin="$(printf '%s\n' "$PUBLIC_URL" | sed -n 's|^\(https\?://[^/]*\).*$|\1|p')"
        [ -z "$public_origin" ] || cors_origins="$cors_origins,$public_origin"
    fi
    printf '%s\n' "$cors_origins"
}

vps_create_container() {
    backend_publish="$BACKEND_PORT:3000"
    [ "$BACKEND_LAN_ACCESS" = 1 ] || backend_publish="127.0.0.1:$BACKEND_PORT:3000"
    vps_docker run -d \
        --name "$VPS_CONTAINER_NAME" \
        --label io.sub-store-vps.managed=true \
        --label "io.sub-store-vps.image-ref=$IMAGE_REF" \
        --restart unless-stopped \
        --security-opt no-new-privileges:true \
        -p "$FRONTEND_PORT:3001" \
        -p "$backend_publish" \
        -e TZ=Asia/Shanghai \
        -e SUB_STORE_FRONTEND_HOST=0.0.0.0 \
        -e SUB_STORE_FRONTEND_PORT=3001 \
        -e SUB_STORE_BACKEND_API_HOST=0.0.0.0 \
        -e SUB_STORE_BACKEND_API_PORT=3000 \
        -e SUB_STORE_BACKEND_MERGE= \
        -e "SUB_STORE_FRONTEND_BACKEND_PATH=/$API_PATH" \
        -e SUB_STORE_BACKEND_PREFIX=true \
        -e "SUB_STORE_CORS_ALLOWED_ORIGINS=$(vps_cors_origins)" \
        -e "SUB_STORE_BACKEND_SYNC_CRON=$SYNC_CRON" \
        --log-driver json-file \
        --log-opt max-size=1m \
        --log-opt max-file=1 \
        --health-cmd "node -e \"const p=process.env.SUB_STORE_FRONTEND_BACKEND_PATH||'';fetch('http://127.0.0.1:3001'+p+'/api/utils/env').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\"" \
        --health-interval 60s \
        --health-timeout 10s \
        --health-retries 3 \
        --health-start-period 30s \
        -v "$VPS_VOLUME_NAME:$VPS_DATA_TARGET" \
        "${VPS_DEPLOY_IMAGE:-$IMAGE_REF}"
}

vps_wait_until_healthy() {
    health_wait_attempt=0
    while [ "$health_wait_attempt" -lt "${VPS_HEALTH_WAIT_ATTEMPTS:-30}" ]; do
        current_state="$(vps_container_state "$VPS_CONTAINER_NAME" 2>/dev/null || true)"
        current_health="$(vps_container_health "$VPS_CONTAINER_NAME" 2>/dev/null || true)"
        if [ "$current_state" = running ] && [ "$current_health" = healthy ]; then
            return 0
        fi
        if [ "$current_state" = exited ] || [ "$current_health" = unhealthy ]; then
            break
        fi
        health_wait_attempt=$((health_wait_attempt + 1))
        sleep 2
    done
    vps_error "container did not become healthy (state: ${current_state:-unknown}, health: ${current_health:-unknown})"
    return 1
}

vps_deploy_container() {
    vps_validate_config || return 1
    vps_guard_local_target || return 1
    if vps_container_exists; then
        vps_verify_managed_container "$VPS_CONTAINER_NAME" || return 1
        current_state="$(vps_container_state "$VPS_CONTAINER_NAME")" || return 1
        [ "$current_state" = running ] || vps_docker start "$VPS_CONTAINER_NAME" >/dev/null || return 1
        return 0
    fi
    vps_check_host_ports || return 1
    vps_ensure_data_volume || return 1
    vps_docker pull "$IMAGE_REF" || return 1
    if ! vps_create_container >/dev/null; then
        vps_error 'Docker could not create the Sub-Store container'
        return 1
    fi
    if ! vps_wait_until_healthy; then
        vps_docker rm -f "$VPS_CONTAINER_NAME" >/dev/null 2>&1 || true
        return 1
    fi
}

vps_encode_api_url() {
    printf '%s' "$1" | sed 's/%/%25/g; s/:/%3A/g; s|/|%2F|g'
}

vps_management_url() {
    url_host="${1:-}"
    if [ -z "$url_host" ] && [ -n "$PUBLIC_URL" ]; then
        url_base="${PUBLIC_URL%/}"
    else
        if [ -z "$url_host" ]; then url_host="$ACCESS_HOST"; fi
        if [ -z "$url_host" ]; then url_host="$(vps_route_ipv4 || true)"; fi
        [ -n "$url_host" ] && ! vps_is_private_ipv4 "$url_host" || return 1
        vps_validate_host "$url_host" || return 1
        url_base="http://$url_host:$FRONTEND_PORT"
    fi
    encoded_api_url="$(vps_encode_api_url "$url_base/$API_PATH")"
    printf '%s/?api=%s\n' "$url_base" "$encoded_api_url"
}

vps_url() {
    [ "$#" -eq 0 ] || {
        [ "$#" -eq 2 ] && [ "$1" = --host ] || { vps_error 'usage: url [--host <IP-or-domain>]'; return 1; }
        vps_validate_host "$2" || { vps_error 'invalid host'; return 1; }
        vps_management_url "$2"
        return $?
    }
    vps_management_url || {
        vps_error 'public host is unknown; retry with: sub-store-vps url --host <VPS-public-IP-or-domain>'
        return 1
    }
}

vps_print_install_summary() {
    docker_version="$(vps_docker version --format '{{.Server.Version}}' 2>/dev/null || printf '%s' unknown)"
    container_state="$(vps_container_state "$VPS_CONTAINER_NAME" 2>/dev/null || printf '%s' unknown)"
    container_health="$(vps_container_health "$VPS_CONTAINER_NAME" 2>/dev/null || printf '%s' unknown)"
    container_image="$(vps_docker inspect -f '{{index .Config.Labels "io.sub-store-vps.image-ref"}}' "$VPS_CONTAINER_NAME" 2>/dev/null || printf '%s' "$IMAGE_REF")"
    volume_path="$(vps_docker volume inspect -f '{{.Mountpoint}}' "$VPS_VOLUME_NAME" 2>/dev/null || printf '%s' unknown)"
    if [ "$BACKEND_LAN_ACCESS" = 1 ]; then backend_bind='0.0.0.0';
    else backend_bind=127.0.0.1; fi
    printf '\nSub-Store VPS installation summary\n'
    if [ "$VPS_DOCKER_INSTALLED_BY_SCRIPT" = 1 ]; then printf 'Docker Engine: installed by this command (%s)\n' "$docker_version";
    else printf 'Docker Engine: existing installation (%s)\n' "$docker_version"; fi
    printf 'Container: %s (%s, health: %s)\n' "$VPS_CONTAINER_NAME" "$container_state" "$container_health"
    printf 'Image: %s\n' "$container_image"
    printf 'Frontend: 0.0.0.0:%s -> container 3001\n' "$FRONTEND_PORT"
    printf 'Backend: %s:%s -> container 3000\n' "$backend_bind" "$BACKEND_PORT"
    printf 'Data volume: %s -> %s (host path: %s)\n' "$VPS_VOLUME_NAME" "$VPS_DATA_TARGET" "$volume_path"
    printf 'API path: /%s (private; do not share this output)\n' "$API_PATH"
    if management_url="$(vps_management_url 2>/dev/null)"; then
        printf 'Management URL: %s\n' "$management_url"
    else
        printf 'Management URL: unavailable; run: sub-store-vps url --host <VPS-public-IP-or-domain>\n'
    fi
    printf 'Commands: sub-store-vps status | api-path | logs --follow | config show\n'
    printf 'Removal: sub-store-vps remove keeps data; add --delete-data to delete the volume.\n'
}

vps_assign_saved_config() {
    new_frontend_port="$FRONTEND_PORT"
    new_access_host="$ACCESS_HOST"
    new_public_url="$PUBLIC_URL"
    new_backend_port="$BACKEND_PORT"
    new_backend_lan_access="$BACKEND_LAN_ACCESS"
    new_api_path="$API_PATH"
    new_image_ref="$IMAGE_REF"
    new_sync_cron="$SYNC_CRON"
    vps_defaults || return 1
    vps_load_config || return 1
    PREVIOUS_FRONTEND_PORT="$FRONTEND_PORT"
    PREVIOUS_ACCESS_HOST="$ACCESS_HOST"
    PREVIOUS_PUBLIC_URL="$PUBLIC_URL"
    PREVIOUS_BACKEND_PORT="$BACKEND_PORT"
    PREVIOUS_BACKEND_LAN_ACCESS="$BACKEND_LAN_ACCESS"
    PREVIOUS_API_PATH="$API_PATH"
    PREVIOUS_IMAGE_REF="$IMAGE_REF"
    PREVIOUS_SYNC_CRON="$SYNC_CRON"
    FRONTEND_PORT="$new_frontend_port"
    ACCESS_HOST="$new_access_host"
    PUBLIC_URL="$new_public_url"
    BACKEND_PORT="$new_backend_port"
    BACKEND_LAN_ACCESS="$new_backend_lan_access"
    API_PATH="$new_api_path"
    IMAGE_REF="$new_image_ref"
    SYNC_CRON="$new_sync_cron"
}

vps_restore_saved_config_values() {
    FRONTEND_PORT="$PREVIOUS_FRONTEND_PORT"
    ACCESS_HOST="$PREVIOUS_ACCESS_HOST"
    PUBLIC_URL="$PREVIOUS_PUBLIC_URL"
    BACKEND_PORT="$PREVIOUS_BACKEND_PORT"
    BACKEND_LAN_ACCESS="$PREVIOUS_BACKEND_LAN_ACCESS"
    API_PATH="$PREVIOUS_API_PATH"
    IMAGE_REF="$PREVIOUS_IMAGE_REF"
    SYNC_CRON="$PREVIOUS_SYNC_CRON"
}

vps_configs_equal() {
    [ "$FRONTEND_PORT" = "$PREVIOUS_FRONTEND_PORT" ] &&
        [ "$ACCESS_HOST" = "$PREVIOUS_ACCESS_HOST" ] &&
        [ "$PUBLIC_URL" = "$PREVIOUS_PUBLIC_URL" ] &&
        [ "$BACKEND_PORT" = "$PREVIOUS_BACKEND_PORT" ] &&
        [ "$BACKEND_LAN_ACCESS" = "$PREVIOUS_BACKEND_LAN_ACCESS" ] &&
        [ "$API_PATH" = "$PREVIOUS_API_PATH" ] &&
        [ "$IMAGE_REF" = "$PREVIOUS_IMAGE_REF" ] &&
        [ "$SYNC_CRON" = "$PREVIOUS_SYNC_CRON" ]
}

vps_rollback_container_replacement() {
    rollback_name="$1"
    rollback_was_running="$2"
    if vps_container_exists; then vps_docker rm -f "$VPS_CONTAINER_NAME" >/dev/null 2>&1 || true; fi
    if vps_docker inspect "$rollback_name" >/dev/null 2>&1; then
        vps_docker rename "$rollback_name" "$VPS_CONTAINER_NAME" || {
            vps_error "rollback container remains available as $rollback_name; manual recovery is required"
            return 1
        }
        if [ "$rollback_was_running" = 1 ]; then
            vps_docker start "$VPS_CONTAINER_NAME" >/dev/null || {
                vps_error 'previous container was restored but could not be started'
                return 1
            }
        fi
    else
        vps_error "rollback container $rollback_name is missing; manual recovery is required"
        return 1
    fi
    vps_restore_saved_config_values
}

vps_apply_config() {
    apply_mode="${1:-config}"
    vps_validate_config || return 1
    vps_guard_local_target || return 1
    if ! vps_container_exists; then
        vps_save_config || return 1
        printf 'Configuration saved; the container is not installed yet.\n'
        return 0
    fi
    vps_verify_managed_container "$VPS_CONTAINER_NAME" || return 1
    vps_assign_saved_config || return 1
    if [ "$apply_mode" = config ] && vps_configs_equal; then
        vps_restore_saved_config_values
        printf 'Configuration is unchanged.\n'
        return 0
    fi
    old_state="$(vps_container_state "$VPS_CONTAINER_NAME")" || {
        vps_restore_saved_config_values
        return 1
    }
    case "$old_state" in
        running) old_was_running=1 ;;
        exited|created) old_was_running=0 ;;
        *) vps_restore_saved_config_values; vps_error "container cannot be updated in state $old_state"; return 1 ;;
    esac
    old_image_id="$(vps_docker inspect -f '{{.Image}}' "$VPS_CONTAINER_NAME")" || {
        vps_restore_saved_config_values
        return 1
    }
    backup_name="sub-store-vps-rollback-$$"
    if vps_docker inspect "$backup_name" >/dev/null 2>&1; then
        vps_restore_saved_config_values
        vps_error "rollback container $backup_name already exists; refusing to overwrite it"
        return 1
    fi
    if [ "$IMAGE_REF" != "$PREVIOUS_IMAGE_REF" ]; then
        vps_docker pull "$IMAGE_REF" || { vps_restore_saved_config_values; return 1; }
        deploy_image="$IMAGE_REF"
    else
        deploy_image="$old_image_id"
    fi
    if [ "$apply_mode" = update ]; then
        deploy_image="${VPS_UPDATE_IMAGE_ID:-$IMAGE_REF}"
    fi
    vps_ensure_data_volume || { vps_restore_saved_config_values; return 1; }
    if [ "$old_was_running" = 1 ]; then
        vps_docker stop "$VPS_CONTAINER_NAME" >/dev/null || { vps_restore_saved_config_values; return 1; }
    fi
    vps_docker rename "$VPS_CONTAINER_NAME" "$backup_name" || {
        if [ "$old_was_running" = 1 ]; then vps_docker start "$VPS_CONTAINER_NAME" >/dev/null 2>&1 || true; fi
        vps_restore_saved_config_values
        return 1
    }
    VPS_DEPLOY_IMAGE="$deploy_image"
    if ! vps_create_container >/dev/null || ! vps_wait_until_healthy; then
        vps_rollback_container_replacement "$backup_name" "$old_was_running" || return 1
        return 1
    fi
    if [ "$old_was_running" = 0 ]; then
        vps_docker stop "$VPS_CONTAINER_NAME" >/dev/null || {
            vps_rollback_container_replacement "$backup_name" "$old_was_running" || return 1
            return 1
        }
    fi
    if ! vps_save_config; then
        vps_rollback_container_replacement "$backup_name" "$old_was_running" || return 1
        return 1
    fi
    if ! vps_docker rm "$backup_name" >/dev/null 2>&1; then
        printf 'Warning: old rollback container remains as %s\n' "$backup_name" >&2
    fi
    VPS_DEPLOY_IMAGE=
    VPS_UPDATE_IMAGE_ID=
    printf 'Configuration applied; data remains in volume %s.\n' "$VPS_VOLUME_NAME"
}

vps_config_set() {
    [ "$#" -eq 2 ] || { vps_error 'usage: config set <key> <value>'; return 1; }
    vps_load_config || return 1
    config_set_key="$1"
    config_set_value="$2"
    case "$config_set_key" in
        frontend_port|FRONTEND_PORT) FRONTEND_PORT="$config_set_value" ;;
        access_host|ACCESS_HOST) ACCESS_HOST="$config_set_value" ;;
        public_url|PUBLIC_URL) PUBLIC_URL="$config_set_value" ;;
        backend_port|BACKEND_PORT) BACKEND_PORT="$config_set_value" ;;
        backend_lan_access|BACKEND_LAN_ACCESS) BACKEND_LAN_ACCESS="$config_set_value" ;;
        api_path|API_PATH) API_PATH="$config_set_value" ;;
        image|image_ref|IMAGE_REF) IMAGE_REF="$config_set_value" ;;
        sync_cron|SYNC_CRON) SYNC_CRON="$config_set_value" ;;
        *) vps_error "unknown configuration key: $config_set_key"; return 1 ;;
    esac
    vps_apply_config
}

vps_container_status() {
    vps_guard_local_target || return 1
    if ! vps_container_exists; then
        printf 'Container: not installed\n'
        return 0
    fi
    vps_verify_managed_container "$VPS_CONTAINER_NAME" || return 1
    status_state="$(vps_container_state "$VPS_CONTAINER_NAME")" || return 1
    status_health="$(vps_container_health "$VPS_CONTAINER_NAME" 2>/dev/null || printf '%s' unknown)"
    status_image="$(vps_docker inspect -f '{{index .Config.Labels "io.sub-store-vps.image-ref"}}' "$VPS_CONTAINER_NAME" 2>/dev/null || printf '%s' unknown)"
    printf 'Container: %s\n' "$VPS_CONTAINER_NAME"
    printf 'State: %s\n' "$status_state"
    printf 'Health: %s\n' "$status_health"
    printf 'Image: %s\n' "$status_image"
    printf 'Frontend: 0.0.0.0:%s\n' "$FRONTEND_PORT"
    if [ "$BACKEND_LAN_ACCESS" = 1 ]; then status_backend_bind=0.0.0.0; else status_backend_bind=127.0.0.1; fi
    printf 'Backend: %s:%s\n' "$status_backend_bind" "$BACKEND_PORT"
    printf 'Data volume: %s -> %s\n' "$VPS_VOLUME_NAME" "$VPS_DATA_TARGET"
}

vps_status() {
    vps_load_config || return 1
    vps_guard_local_target || return 1
    vps_docker_info || {
        printf 'Docker Engine: not responding\n' >&2
        return 1
    }
    vps_container_status
}

vps_service_control() {
    action="$1"
    vps_load_config || return 1
    vps_ensure_local_docker || return 1
    vps_container_exists || { vps_error 'Sub-Store is not installed'; return 1; }
    vps_verify_managed_container "$VPS_CONTAINER_NAME" || return 1
    case "$action" in
        start) vps_docker start "$VPS_CONTAINER_NAME" >/dev/null ;;
        stop) vps_docker stop "$VPS_CONTAINER_NAME" >/dev/null ;;
        restart) vps_docker restart "$VPS_CONTAINER_NAME" >/dev/null ;;
    esac
    printf 'Sub-Store %s complete.\n' "$action"
}

vps_logs() {
    follow=0
    case "${1:-}" in
        '') ;;
        --follow) follow=1 ;;
        *) vps_error 'usage: logs [--follow]'; return 1 ;;
    esac
    vps_load_config || return 1
    vps_ensure_local_docker || return 1
    vps_container_exists || { vps_error 'Sub-Store is not installed'; return 1; }
    vps_verify_managed_container "$VPS_CONTAINER_NAME" || return 1
    if [ "$follow" = 1 ]; then vps_docker logs --tail 100 --follow "$VPS_CONTAINER_NAME";
    else vps_docker logs --tail 100 "$VPS_CONTAINER_NAME"; fi
}

vps_update_image() {
    vps_load_config || return 1
    vps_ensure_local_docker || return 1
    vps_container_exists || { vps_error 'Sub-Store is not installed'; return 1; }
    vps_verify_managed_container "$VPS_CONTAINER_NAME" || return 1
    previous_image_id="$(vps_docker inspect -f '{{.Image}}' "$VPS_CONTAINER_NAME")" || return 1
    vps_docker pull "$IMAGE_REF" || { vps_error 'image pull failed; existing container remains unchanged'; return 1; }
    latest_image_id="$(vps_docker image inspect -f '{{.Id}}' "$IMAGE_REF")" || return 1
    [ -n "$latest_image_id" ] || { vps_error 'pulled image has no immutable ID'; return 1; }
    if [ "$previous_image_id" = "$latest_image_id" ]; then
        printf 'Sub-Store image is unchanged; container was not recreated.\n'
        return 0
    fi
    VPS_UPDATE_IMAGE_ID="$latest_image_id"
    vps_apply_config update
}

vps_confirm_remove() {
    delete_data="$1"
    yes_flag="$2"
    [ "$yes_flag" = 1 ] && return 0
    vps_has_tty || {
        vps_error 'non-interactive removal requires --yes'
        return 1
    }
    if [ "$delete_data" = 1 ]; then
        printf 'This will remove the Sub-Store container and permanently delete volume %s. Continue? [y/N] ' "$VPS_VOLUME_NAME" >&2
    else
        printf 'Remove the Sub-Store container and keep data volume %s? [y/N] ' "$VPS_VOLUME_NAME" >&2
    fi
    IFS= read -r remove_answer || return 1
    case "$remove_answer" in y|Y|yes|YES) return 0 ;; *) printf 'Cancelled.\n'; return 1 ;; esac
}

vps_cleanup_official_image() {
    image_id="$1"
    [ -n "$image_id" ] || return 0
    image_refs="$(vps_docker image inspect -f '{{range .RepoTags}}{{println .}}{{end}}{{range .RepoDigests}}{{println .}}{{end}}' "$image_id" 2>/dev/null || true)"
    [ -n "$image_refs" ] || return 0
    printf '%s\n' "$image_refs" | while IFS= read -r image_reference; do
        [ -n "$image_reference" ] || continue
        case "$image_reference" in
            xream/sub-store|xream/sub-store:*|xream/sub-store@sha256:*|docker.io/xream/sub-store|docker.io/xream/sub-store:*|docker.io/xream/sub-store@sha256:*) ;;
            *) exit 1 ;;
        esac
    done || return 0
    remaining_users="$(vps_docker ps -a --filter "ancestor=$image_id" --format '{{.ID}}' 2>/dev/null || true)"
    [ -z "$remaining_users" ] || return 0
    vps_docker image rm "$image_id" >/dev/null 2>&1 || true
}

vps_remove() {
    delete_data=0
    yes_flag=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --delete-data) delete_data=1 ;;
            --yes) yes_flag=1 ;;
            *) vps_error 'usage: remove [--delete-data] [--yes]'; return 1 ;;
        esac
        shift
    done
    vps_load_config || return 1
    vps_ensure_local_docker || return 1
    if vps_container_exists; then
        vps_verify_managed_container "$VPS_CONTAINER_NAME" || return 1
        remove_image_id="$(vps_docker inspect -f '{{.Image}}' "$VPS_CONTAINER_NAME")" || return 1
    else
        remove_image_id=
    fi
    if [ "$delete_data" = 1 ] && vps_docker volume inspect "$VPS_VOLUME_NAME" >/dev/null 2>&1; then
        remove_volume_label="$(vps_docker volume inspect -f '{{index .Labels "io.sub-store-vps.managed"}}' "$VPS_VOLUME_NAME")" || return 1
        [ "$remove_volume_label" = true ] || {
            vps_error "volume $VPS_VOLUME_NAME is not marked as managed; refusing to delete it"
            return 1
        }
    fi
    vps_confirm_remove "$delete_data" "$yes_flag" || return 1
    if vps_container_exists; then vps_docker rm -f "$VPS_CONTAINER_NAME" >/dev/null || return 1; fi
    if [ "$delete_data" = 1 ] && vps_docker volume inspect "$VPS_VOLUME_NAME" >/dev/null 2>&1; then
        vps_docker volume rm "$VPS_VOLUME_NAME" >/dev/null || return 1
    fi
    if [ -e "$VPS_CONFIG_FILE" ]; then
        vps_config_file_is_safe || { vps_error 'refusing to remove an unsafe configuration file'; return 1; }
        rm -f "$VPS_CONFIG_FILE" || return 1
    fi
    vps_cleanup_official_image "$remove_image_id"
    if [ "$delete_data" = 1 ]; then printf 'Removed container, configuration, image when unused, and data volume.\n';
    else printf 'Removed container and configuration; data volume %s is preserved.\n' "$VPS_VOLUME_NAME"; fi
}

vps_install() {
    vps_defaults
    if [ -e "$VPS_CONFIG_FILE" ]; then vps_load_config || return 1; fi
    vps_parse_install_args "$@" || return 1
    vps_validate_config || return 1
    vps_prompt_config || return 1
    vps_configure_access_host || return 1
    vps_validate_config || return 1
    vps_install_docker || return 1
    if vps_container_exists; then
        [ -e "$VPS_CONFIG_FILE" ] || {
            vps_error 'a sub-store container already exists without this tool configuration; refusing to adopt it'
            return 1
        }
        vps_verify_managed_container "$VPS_CONTAINER_NAME" || return 1
        vps_apply_config || return 1
    else
        vps_save_config || return 1
        vps_deploy_container || return 1
    fi
    vps_print_install_summary
}

vps_require_root() {
    [ "${SUB_STORE_VPS_TEST_MODE:-0}" = 1 ] && return 0
    current_uid="$(id -u 2>/dev/null)" || return 1
    [ "$current_uid" = 0 ] || {
        vps_error 'run this command as root (for example: sudo sub-store-vps status)'
        return 1
    }
}

vps_load_required_config() {
    [ -e "$VPS_CONFIG_FILE" ] || {
        vps_error 'Sub-Store is not configured; run sub-store-vps install first'
        return 1
    }
    vps_defaults || return 1
    vps_load_config
}

vps_usage() {
    cat <<'USAGE'
Usage: sub-store-vps <command>

Commands:
  install [options]        Install Docker if needed, then deploy Sub-Store
  status                   Show container state without revealing the API path
  config show              Show settings with the API path hidden
  config set <key> <value> Validate and apply a setting
  api-path                 Read the private API path
  api-path set <48-hex>    Set the API path and apply it
  api-path rotate          Generate and apply a new API path
  url [--host <host>]      Print the complete management URL
  start | stop | restart   Control the managed container
  update                   Pull the configured image and update if it changed
  logs [--follow]          Show recent container logs
  remove [--delete-data] [--yes]
                           Remove the container; data is kept unless requested
USAGE
}

vps_command_mutates() {
    case "${1:-}" in
        install|start|stop|restart|update|remove) return 0 ;;
        config) [ "${2:-}" = set ] ;;
        api-path)
            case "${2:-}" in set|rotate) return 0 ;; esac
            ;;
    esac
    return 1
}

vps_dispatch_command() {
    command_name="${1:-help}"
    [ "$#" -eq 0 ] || shift
    case "$command_name" in
        install) vps_install "$@" ;;
        status)
            if [ ! -e "$VPS_CONFIG_FILE" ]; then printf 'Sub-Store: not installed\n'; return 0; fi
            vps_status
            ;;
        config)
            subcommand="${1:-}"
            [ "$#" -eq 0 ] || shift
            case "$subcommand" in
                show)
                    vps_load_required_config || return 1
                    vps_show_config
                    ;;
                set)
                    [ -e "$VPS_CONFIG_FILE" ] || { vps_error 'run install before changing settings'; return 1; }
                    vps_config_set "$@"
                    ;;
                *) vps_error 'usage: config {show|set <key> <value>}'; return 1 ;;
            esac
            ;;
        api-path)
            vps_load_required_config || return 1
            case "${1:-}" in
                '') vps_print_api_path ;;
                set) [ "$#" -eq 2 ] || { vps_error 'usage: api-path set <48-hex-path>'; return 1; }; vps_api_path_set "$2" ;;
                rotate) [ "$#" -eq 1 ] || { vps_error 'usage: api-path rotate'; return 1; }; vps_api_path_rotate ;;
                *) vps_error 'usage: api-path [set <48-hex-path>|rotate]'; return 1 ;;
            esac
            ;;
        url)
            vps_load_required_config || return 1
            vps_url "$@"
            ;;
        start|stop|restart) vps_service_control "$command_name" ;;
        update) vps_update_image ;;
        logs) vps_logs "$@" ;;
        remove) vps_remove "$@" ;;
        help|-h|--help) vps_usage ;;
        *) vps_error "unknown command: $command_name"; vps_usage >&2; return 2 ;;
    esac
}

vps_main() {
    command_name="${1:-help}"
    case "$command_name" in help|-h|--help) vps_usage; return 0 ;; esac
    vps_require_root || return 1
    if vps_command_mutates "$@"; then
        vps_acquire_operation_lock || return 1
        if vps_dispatch_command "$@"; then
            dispatch_status=0
        else
            dispatch_status=$?
        fi
        if vps_release_operation_lock; then
            release_status=0
        else
            release_status=$?
        fi
        [ "$release_status" -eq 0 ] || return "$release_status"
        return "$dispatch_status"
    fi
    vps_dispatch_command "$@"
}

if [ "${SUB_STORE_VPS_SOURCE_ONLY:-0}" != 1 ]; then
    vps_main "$@"
    exit $?
fi
