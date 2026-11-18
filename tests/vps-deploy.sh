#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/sub-store-vps.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

export SUB_STORE_VPS_CONFIG="$TMP/sub-store-vps.conf"
export SUB_STORE_VPS_OS_RELEASE="$TMP/os-release"
export SUB_STORE_VPS_SOURCE_ONLY=1
export SUB_STORE_VPS_TEST_MODE=1

. "$SCRIPT"

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        # Git Bash does not expose NTFS owner/mode bits as POSIX stat does.
        # VPS CI runs this same test under Linux and verifies the real mode.
        vps_config_file_is_safe() {
            [ -f "$VPS_CONFIG_FILE" ] && [ ! -L "$VPS_CONFIG_FILE" ]
        }
        vps_lock_directory_is_safe() {
            [ -d "$VPS_LOCK_DIRECTORY" ] && [ ! -L "$VPS_LOCK_DIRECTORY" ]
        }
        vps_lock_pid_file_is_safe() {
            [ -f "$VPS_LOCK_DIRECTORY/pid" ] && [ ! -L "$VPS_LOCK_DIRECTORY/pid" ]
        }
        ;;
esac

assert_equal() {
    expected="$1"
    actual="$2"
    label="$3"
    [ "$expected" = "$actual" ] || {
        printf 'FAIL: %s (expected <%s>, got <%s>)\n' "$label" "$expected" "$actual" >&2
        return 1
    }
}

test_default_config() {
    vps_defaults
    assert_equal 3001 "$FRONTEND_PORT" 'default frontend port'
    assert_equal 3000 "$BACKEND_PORT" 'default backend port'
    assert_equal 0 "$BACKEND_LAN_ACCESS" 'default backend LAN access'
    assert_equal xream/sub-store:latest "$IMAGE_REF" 'default official image'
    assert_equal '55 23 * * *' "$SYNC_CRON" 'default sync cron'
    [ "${#API_PATH}" -eq 48 ] || return 1
    case "$API_PATH" in *[!0123456789abcdef]*) return 1 ;; esac
}

test_default_optional_host_is_valid() {
    vps_defaults
    vps_validate_config
}

test_install_args_override_defaults() {
    vps_defaults
    vps_parse_install_args --frontend-port 8080 --api-path AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
        --sync-cron '*/10 * * * *'
    assert_equal 8080 "$FRONTEND_PORT" 'frontend override'
    assert_equal AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "$API_PATH" 'API path override'
    assert_equal '*/10 * * * *' "$SYNC_CRON" 'cron override'
}

test_validation_rejects_equal_ports_invalid_api_path_and_nonofficial_image() {
    vps_defaults
    BACKEND_PORT="$FRONTEND_PORT"
    if vps_validate_config 2>/dev/null; then return 1; fi
    BACKEND_PORT=3000
    API_PATH=not-48-hex
    if vps_validate_config 2>/dev/null; then return 1; fi
    API_PATH=0123456789abcdef0123456789abcdef0123456789abcdef
    IMAGE_REF=attacker/sub-store:latest
    if vps_validate_config 2>/dev/null; then return 1; fi
}

test_config_file_is_root_only_and_config_show_redacts_api_path() {
    vps_defaults
    secret="$API_PATH"
    vps_save_config
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) ;;
        *)
            mode="$(stat -c '%a' "$SUB_STORE_VPS_CONFIG")"
            assert_equal 600 "$mode" 'config file mode'
            ;;
    esac
    displayed="$(vps_show_config)"
    case "$displayed" in *"$secret"*) return 1 ;; esac
    case "$displayed" in *'API_PATH=<hidden>'*) ;; *) return 1 ;; esac
    vps_load_config
    assert_equal "$secret" "$API_PATH" 'API path loaded from config'
}

test_config_parser_never_executes_file_contents() {
    marker="$TMP/untrusted-config-executed"
    printf 'API_PATH=$(touch %s)\n' "$marker" > "$SUB_STORE_VPS_CONFIG"
    chmod 600 "$SUB_STORE_VPS_CONFIG"
    vps_defaults
    if vps_load_config 2>/dev/null; then return 1; fi
    [ ! -e "$marker" ]
}

test_config_parser_rejects_missing_and_duplicate_keys() {
    vps_defaults
    vps_save_config
    sed '/^PUBLIC_URL=/d' "$SUB_STORE_VPS_CONFIG" > "$TMP/missing-key.conf"
    cp "$TMP/missing-key.conf" "$SUB_STORE_VPS_CONFIG"
    chmod 600 "$SUB_STORE_VPS_CONFIG"
    vps_defaults
    if vps_load_config 2>/dev/null; then return 1; fi

    vps_defaults
    vps_save_config
    printf '%s\n' 'FRONTEND_PORT=3010' >> "$SUB_STORE_VPS_CONFIG"
    chmod 600 "$SUB_STORE_VPS_CONFIG"
    vps_defaults
    if vps_load_config 2>/dev/null; then return 1; fi
}

test_operation_lock_serializes_and_releases() (
    VPS_LOCK_DIRECTORY="$TMP/operation-lock"
    vps_acquire_operation_lock
    [ -d "$VPS_LOCK_DIRECTORY" ] || return 1
    lock_pid="$(cat "$VPS_LOCK_DIRECTORY/pid")"
    assert_equal "$$" "$lock_pid" 'operation lock records current process'
    if vps_acquire_operation_lock 2>/dev/null; then return 1; fi
    vps_release_operation_lock
    [ ! -e "$VPS_LOCK_DIRECTORY" ]
)

test_operation_lock_recovers_dead_owner() (
    VPS_LOCK_DIRECTORY="$TMP/stale-operation-lock"
    mkdir "$VPS_LOCK_DIRECTORY"
    chmod 700 "$VPS_LOCK_DIRECTORY"
    printf '%s\n' 2147483647 > "$VPS_LOCK_DIRECTORY/pid"
    chmod 600 "$VPS_LOCK_DIRECTORY/pid"
    vps_acquire_operation_lock
    lock_pid="$(cat "$VPS_LOCK_DIRECTORY/pid")"
    assert_equal "$$" "$lock_pid" 'stale operation lock replaced by current process'
    vps_release_operation_lock
)

test_operation_lock_rejects_live_or_untrusted_lock() (
    VPS_LOCK_DIRECTORY="$TMP/live-operation-lock"
    mkdir "$VPS_LOCK_DIRECTORY"
    chmod 700 "$VPS_LOCK_DIRECTORY"
    printf '%s\n' "$$" > "$VPS_LOCK_DIRECTORY/pid"
    chmod 600 "$VPS_LOCK_DIRECTORY/pid"
    if vps_acquire_operation_lock 2>/dev/null; then return 1; fi
    rm -f "$VPS_LOCK_DIRECTORY/pid"
    rmdir "$VPS_LOCK_DIRECTORY"

    mkdir "$TMP/untrusted-lock-target"
    ln -s "$TMP/untrusted-lock-target" "$VPS_LOCK_DIRECTORY"
    if vps_acquire_operation_lock 2>/dev/null; then return 1; fi
    [ -d "$TMP/untrusted-lock-target" ]
)

test_main_wraps_mutating_commands_with_operation_lock() (
    VPS_LOCK_DIRECTORY="$TMP/dispatcher-lock"
    vps_require_root() { return 0; }
    vps_dispatch_command() {
        [ -d "$VPS_LOCK_DIRECTORY" ] || return 1
        [ "$(cat "$VPS_LOCK_DIRECTORY/pid")" = "$$" ]
    }
    vps_main update
    [ ! -e "$VPS_LOCK_DIRECTORY" ]
)

test_custom_api_path_is_validated_and_api_path_command_reveals_it() {
    vps_defaults
    API_PATH=abcdef0123456789ABCDEF0123456789abcdef0123456789
    vps_validate_config
    revealed="$(vps_print_api_path)"
    assert_equal "$API_PATH" "$revealed" 'explicit API path read command'
    API_PATH=abcdef0123456789ABCDEF0123456789abcdef012345678z
    if vps_validate_config 2>/dev/null; then return 1; fi
}

test_manual_api_path_set_redeploys_with_new_path() (
    vps_defaults
    vps_save_config
    expected_api_path=0123456789abcdef0123456789abcdef0123456789abcdef
    applied_api_path=
    vps_apply_config() {
        applied_api_path="$API_PATH"
    }
    vps_api_path_set "$expected_api_path"
    assert_equal "$expected_api_path" "$applied_api_path" 'API path applied to deployment'
    vps_load_config
    assert_equal "$expected_api_path" "$API_PATH" 'API path persisted after apply'
)

test_cron_uses_five_field_ranges() {
    vps_valid_cron '55 23 * * *'
    vps_valid_cron '*/10 0-23 1,15 * 0-7'
    if vps_valid_cron '60 23 * * *'; then return 1; fi
    if vps_valid_cron '55 24 * * *'; then return 1; fi
    if vps_valid_cron '55 23 0 * *'; then return 1; fi
    if vps_valid_cron '55 23 * 13 *'; then return 1; fi
    if vps_valid_cron '55 23 * * 8'; then return 1; fi
    if vps_valid_cron '55 23 * *'; then return 1; fi
}

write_os_release() {
    printf '%s\n' "$@" > "$SUB_STORE_VPS_OS_RELEASE"
}

test_missing_docker_uses_official_apt_repo_for_debian_family() {
    write_os_release 'ID=ubuntu' 'VERSION_ID="24.04"' 'VERSION_CODENAME=noble'
    vps_has_command() { case "$1" in apt-get) return 0 ;; *) return 1 ;; esac; }
    vps_detect_platform
    assert_equal apt "$VPS_PACKAGE_FAMILY" 'Ubuntu package family'
    assert_equal ubuntu "$VPS_DOCKER_DISTRO" 'Ubuntu Docker repo distro'
    assert_equal https://download.docker.com/linux/ubuntu "$VPS_DOCKER_REPO_URL" 'official Ubuntu Docker repo'
    write_os_release 'ID=debian' 'VERSION_ID="13"' 'VERSION_CODENAME=trixie'
    vps_detect_platform
    assert_equal debian "$VPS_DOCKER_DISTRO" 'Debian Docker repo distro'
    assert_equal https://download.docker.com/linux/debian "$VPS_DOCKER_REPO_URL" 'official Debian Docker repo'
    vps_has_command() { case "$1" in apt-get) return 0 ;; *) return 1 ;; esac; }
    apt_install_selected=0
    rpm_install_selected=0
    vps_package_installed() { return 1; }
    vps_install_docker_apt() { apt_install_selected=1; }
    vps_install_docker_rpm() { rpm_install_selected=1; }
    vps_service_start() { return 0; }
    vps_docker_info() { VPS_DOCKER_INFO=28.0.0; }
    vps_install_docker
    assert_equal 1 "$apt_install_selected" 'Ubuntu selects the APT installer'
    assert_equal 0 "$rpm_install_selected" 'Ubuntu skips the RPM installer'
    assert_equal 1 "$VPS_DOCKER_INSTALLED_BY_SCRIPT" 'APT install marker'
}

test_apt_installer_writes_only_official_repo_metadata() (
    write_os_release 'ID=ubuntu' 'VERSION_ID="24.04"' 'VERSION_CODENAME=noble'
    vps_has_command() { case "$1" in apt-get|curl) return 0 ;; *) return 1 ;; esac; }
    VPS_APT_KEYRING_FILE="$TMP/apt/etc/apt/keyrings/docker.asc"
    VPS_APT_SOURCE_FILE="$TMP/apt/etc/apt/sources.list.d/docker.sources"
    apt_calls_file="$TMP/apt-calls"
    download_urls_file="$TMP/apt-downloads"
    : > "$apt_calls_file"
    : > "$download_urls_file"
    apt-get() { printf '%s\n' "$*" >> "$apt_calls_file"; }
    dpkg() { printf 'amd64\n'; }
    vps_download_file() { printf '%s\n' "$1" >> "$download_urls_file"; printf 'fake docker signing key\n' > "$2"; }
    vps_detect_platform
    vps_install_docker_apt
    source_contents="$(cat "$VPS_APT_SOURCE_FILE")"
    printf '%s\n' "$source_contents" | grep -F 'URIs: https://download.docker.com/linux/ubuntu' >/dev/null
    printf '%s\n' "$source_contents" | grep -F 'Suites: noble' >/dev/null
    printf '%s\n' "$source_contents" | grep -F 'Signed-By: ' >/dev/null
    grep -F 'https://download.docker.com/linux/ubuntu/gpg' "$download_urls_file" >/dev/null
    grep -F 'docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin' "$apt_calls_file" >/dev/null
)

test_missing_docker_uses_official_rpm_repo_for_rpm_family() {
    vps_has_command() { case "$1" in dnf) return 0 ;; *) return 1 ;; esac; }
    write_os_release 'ID=rocky' 'VERSION_ID="9.5"' 'NAME="Rocky Linux"'
    vps_detect_platform
    assert_equal rpm "$VPS_PACKAGE_FAMILY" 'Rocky package family'
    assert_equal rocky "$VPS_DOCKER_DISTRO" 'Rocky Docker repo distro'
    assert_equal https://download.docker.com/linux/rocky "$VPS_DOCKER_REPO_URL" 'official Rocky Docker repo'
    write_os_release 'ID=fedora' 'VERSION_ID="43"' 'NAME="Fedora Linux"'
    vps_detect_platform
    assert_equal fedora "$VPS_DOCKER_DISTRO" 'Fedora Docker repo distro'
    write_os_release 'ID=rocky' 'VERSION_ID="9.5"' 'NAME="Rocky Linux"'
    vps_has_command() { case "$1" in dnf) return 0 ;; *) return 1 ;; esac; }
    apt_install_selected=0
    rpm_install_selected=0
    vps_package_installed() { return 1; }
    vps_install_docker_apt() { apt_install_selected=1; }
    vps_install_docker_rpm() { rpm_install_selected=1; }
    vps_service_start() { return 0; }
    vps_docker_info() { VPS_DOCKER_INFO=28.0.0; }
    vps_install_docker
    assert_equal 0 "$apt_install_selected" 'Rocky skips the APT installer'
    assert_equal 1 "$rpm_install_selected" 'Rocky selects the RPM installer'
    assert_equal 1 "$VPS_DOCKER_INSTALLED_BY_SCRIPT" 'RPM install marker'
}

test_rpm_installer_writes_official_repo_metadata() (
    write_os_release 'ID=rocky' 'VERSION_ID="9.5"' 'NAME="Rocky Linux"'
    vps_has_command() { case "$1" in dnf|curl) return 0 ;; *) return 1 ;; esac; }
    VPS_RPM_REPO_FILE="$TMP/rpm/etc/yum.repos.d/docker-ce.repo"
    rpm_calls_file="$TMP/rpm-calls"
    rpm_downloads_file="$TMP/rpm-downloads"
    : > "$rpm_calls_file"
    : > "$rpm_downloads_file"
    dnf() { printf '%s\n' "$*" >> "$rpm_calls_file"; }
    vps_download_file() { printf '%s\n' "$1" >> "$rpm_downloads_file"; printf '[docker-ce-stable]\n' > "$2"; }
    vps_detect_platform
    vps_install_docker_rpm
    grep -F 'https://download.docker.com/linux/rocky/docker-ce.repo' "$rpm_downloads_file" >/dev/null
    grep -F 'docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin' "$rpm_calls_file" >/dev/null
    grep -F '[docker-ce-stable]' "$VPS_RPM_REPO_FILE" >/dev/null
)

test_existing_docker_engine_skips_package_install() {
    vps_has_command() { case "$1" in docker) return 0 ;; *) return 1 ;; esac; }
    vps_guard_local_target() { return 0; }
    vps_docker_info() { VPS_DOCKER_INFO='28.0.0|Ubuntu'; return 0; }
    vps_install_docker_apt() { return 99; }
    vps_install_docker_rpm() { return 99; }
    vps_install_docker
    assert_equal 0 "$VPS_DOCKER_INSTALLED_BY_SCRIPT" 'existing Docker install marker'
}

test_conflicting_runtime_packages_are_not_replaced() {
    vps_has_command() {
        case "$1" in docker|podman|dockerd) return 1 ;; apt-get|dnf|yum|dpkg-query|rpm) return 0 ;; *) return 1 ;; esac
    }
    vps_detect_platform() { VPS_PACKAGE_FAMILY="$TEST_PACKAGE_FAMILY"; return 0; }
    vps_package_installed() { [ "$1" = "$TEST_CONFLICT_PACKAGE" ]; }
    install_attempted=0
    vps_install_docker_apt() { install_attempted=1; return 0; }
    vps_install_docker_rpm() { install_attempted=1; return 0; }

    TEST_PACKAGE_FAMILY=apt
    TEST_CONFLICT_PACKAGE=containerd
    if vps_install_docker 2>/dev/null; then return 1; fi
    assert_equal 0 "$install_attempted" 'APT conflict prevents repository and package changes'

    TEST_PACKAGE_FAMILY=rpm
    TEST_CONFLICT_PACKAGE=runc
    if vps_install_docker 2>/dev/null; then return 1; fi
    assert_equal 0 "$install_attempted" 'RPM conflict prevents repository and package changes'
}

test_unsupported_os_exits_before_changes() {
    write_os_release 'ID=alpine' 'VERSION_ID="3.20"' 'NAME="Alpine Linux"'
    vps_has_command() { case "$1" in docker|podman|dockerd) return 1 ;; *) return 0 ;; esac; }
    install_attempted=0
    vps_install_docker_apt() { install_attempted=1; }
    vps_install_docker_rpm() { install_attempted=1; }
    if vps_install_docker 2>/dev/null; then return 1; fi
    assert_equal 0 "$install_attempted" 'unsupported distro makes no package changes'
}

test_remote_docker_target_is_refused() {
    vps_has_command() { case "$1" in docker) return 0 ;; *) return 1 ;; esac; }
    if (DOCKER_HOST=tcp://example.invalid:2375 vps_install_docker) 2>/dev/null; then return 1; fi
    if (DOCKER_CONTEXT=production vps_install_docker) 2>/dev/null; then return 1; fi
}

test_ddns_host_is_preferred_and_no_ddns_uses_route_ipv4() {
    vps_route_ipv4() { printf '8.8.8.8\n'; }
    vps_has_tty() { return 0; }
    vps_prompt_line() { VPS_PROMPT_VALUE=store.example.com; }
    ACCESS_HOST=
    vps_configure_access_host
    assert_equal store.example.com "$ACCESS_HOST" 'DDNS hostname selection'
    ACCESS_HOST=
    vps_has_tty() { return 1; }
    vps_configure_access_host
    assert_equal 8.8.8.8 "$ACCESS_HOST" 'default route IPv4 selection'
}

test_private_route_address_prompts_or_requires_explicit_host() {
    vps_route_ipv4() { printf '10.4.3.2\n'; }
    vps_has_tty() { return 0; }
    vps_prompt_line() { VPS_PROMPT_VALUE=public.example.net; }
    ACCESS_HOST=
    vps_configure_access_host
    assert_equal public.example.net "$ACCESS_HOST" 'private route prompts for public host'
    ACCESS_HOST=
    vps_has_tty() { return 0; }
    vps_prompt_line() { VPS_PROMPT_VALUE=; }
    if vps_configure_access_host 2>/dev/null; then return 1; fi
    ACCESS_HOST=
    vps_has_tty() { return 0; }
    if vps_configure_access_host 2>/dev/null; then return 1; fi
    ACCESS_HOST=
    vps_has_tty() { return 1; }
    vps_configure_access_host
    assert_equal '' "$ACCESS_HOST" 'non-interactive private route remains unset'
}

test_container_args_keep_backend_loopback_and_data_in_named_volume() {
    vps_defaults
    ACCESS_HOST=store.example.com
    API_PATH=0123456789abcdef0123456789abcdef0123456789abcdef
    FRONTEND_PORT=8080
    BACKEND_PORT=3040
    docker_args_file="$TMP/docker-args"
    : > "$docker_args_file"
    vps_docker() {
        printf '%s\n' "$*" >> "$docker_args_file"
        [ "$1" = run ] && { printf 'container-id\n'; return 0; }
    }
    vps_create_container >/dev/null
    docker_args="$(cat "$docker_args_file")"
    printf '%s\n' "$docker_args" | grep -F -- '-p 8080:3001' >/dev/null
    printf '%s\n' "$docker_args" | grep -F -- '-p 127.0.0.1:3040:3000' >/dev/null
    printf '%s\n' "$docker_args" | grep -F -- '-v sub-store-data:/opt/app/data' >/dev/null
    printf '%s\n' "$docker_args" | grep -F -- 'SUB_STORE_FRONTEND_BACKEND_PATH=/0123456789abcdef0123456789abcdef0123456789abcdef' >/dev/null
}

test_ddns_management_url_and_install_summary_include_required_fields() (
    vps_defaults
    ACCESS_HOST=store.example.com
    API_PATH=0123456789abcdef0123456789abcdef0123456789abcdef
    vps_container_state() { printf 'running\n'; }
    vps_container_health() { printf 'healthy\n'; }
    vps_docker() {
        case "$1" in
            version) printf '28.0.0\n' ;;
            inspect)
                case "$*" in
                    *State.Status*) printf 'running\n' ;;
                    *Health.Status*) printf 'healthy\n' ;;
                    *io.sub-store-vps.image-ref*) printf 'xream/sub-store:latest\n' ;;
                    *Config.Image*) printf 'xream/sub-store:latest\n' ;;
                    *) printf 'unknown\n' ;;
                esac
                ;;
            volume) printf '/var/lib/docker/volumes/sub-store-data/_data\n' ;;
        esac
    }
    expected_url='http://store.example.com:3001/?api=http%3A%2F%2Fstore.example.com%3A3001%2F0123456789abcdef0123456789abcdef0123456789abcdef'
    assert_equal "$expected_url" "$(vps_management_url)" 'complete DDNS management URL'
    VPS_DOCKER_INSTALLED_BY_SCRIPT=1
    summary="$(vps_print_install_summary)"
    for required in \
        'Docker Engine: installed by this command (28.0.0)' \
        'Container: sub-store (running, health: healthy)' \
        'Image: xream/sub-store:latest' \
        'Frontend: 0.0.0.0:3001 -> container 3001' \
        'Backend: 127.0.0.1:3000 -> container 3000' \
        'sub-store-data -> /opt/app/data' \
        'Management URL: http://store.example.com:3001/?api=http%3A%2F%2Fstore.example.com%3A3001%2F0123456789abcdef0123456789abcdef0123456789abcdef' \
        'sub-store-vps status | api-path | logs --follow | config show'; do
        printf '%s\n' "$summary" | grep -F -- "$required" >/dev/null || return 1
    done
)

setup_fake_managed_container() {
    vps_defaults
    ACCESS_HOST=store.example.com
    API_PATH=0123456789abcdef0123456789abcdef0123456789abcdef
    vps_save_config
    FAKE_CONTAINER_EXISTS=1
    FAKE_STATE=running
    FAKE_HEALTH=healthy
    FAKE_NEW_HEALTH=healthy
    FAKE_CONFIG_IMAGE=xream/sub-store:latest
    FAKE_SOURCE_REF=xream/sub-store:latest
    FAKE_MANAGED_LABEL=true
    FAKE_MOUNT=volume:sub-store-data
    FAKE_IMAGE_ID=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    FAKE_NEXT_IMAGE_ID=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    FAKE_PULL_IMAGE_ID="$FAKE_IMAGE_ID"
    FAKE_BACKUP_EXISTS=0
    FAKE_VOLUME_PRESENT=1
    FAKE_VOLUME_LABEL=true
    FAKE_OTHER_IMAGE_USERS=
    FAKE_PULL_COUNT=0
    FAKE_RUN_COUNT=0
    FAKE_IMAGE_REMOVED=0
    FAKE_VOLUME_REMOVED=0
    FAKE_LOG_ARGS=
    vps_guard_local_target() { return 0; }
    vps_ensure_local_docker() { return 0; }
    vps_wait_until_healthy() { [ "$FAKE_HEALTH" = healthy ]; }
    vps_docker() {
        fake_docker_command="$1"
        shift
        case "$fake_docker_command" in
            inspect)
                if [ "${1:-}" = -f ]; then fake_format="$2"; fake_name="$3"; else fake_format=; fake_name="$1"; fi
                if [ "$fake_name" = sub-store ]; then
                    [ "$FAKE_CONTAINER_EXISTS" = 1 ] || return 1
                    fake_state="$FAKE_STATE"; fake_health="$FAKE_HEALTH"; fake_image="$FAKE_CONFIG_IMAGE"
                    fake_source_ref="$FAKE_SOURCE_REF"; fake_managed="$FAKE_MANAGED_LABEL"; fake_mount="$FAKE_MOUNT"; fake_id="$FAKE_IMAGE_ID"
                elif [ "$fake_name" = sub-store-vps-rollback-$$ ] || case "$fake_name" in sub-store-vps-rollback-*) true ;; *) false ;; esac; then
                    [ "$FAKE_BACKUP_EXISTS" = 1 ] || return 1
                    fake_state="$FAKE_BACKUP_STATE"; fake_health="$FAKE_BACKUP_HEALTH"; fake_image="$FAKE_BACKUP_CONFIG_IMAGE"
                    fake_source_ref="$FAKE_BACKUP_SOURCE_REF"; fake_managed="$FAKE_BACKUP_MANAGED_LABEL"; fake_mount="$FAKE_BACKUP_MOUNT"; fake_id="$FAKE_BACKUP_IMAGE_ID"
                else return 1
                fi
                case "$fake_format" in
                    *State.Status*) printf '%s\n' "$fake_state" ;;
                    *State.Running*) [ "$fake_state" = running ] && printf 'true\n' || printf 'false\n' ;;
                    *State.Health*) printf '%s\n' "$fake_health" ;;
                    *Mounts*) printf '%s|%s|%s|%s\n' "$fake_image" "$fake_managed" "$fake_source_ref" "$fake_mount" ;;
                    *io.sub-store-vps.image-ref*) printf '%s\n' "$fake_source_ref" ;;
                    *io.sub-store-vps.managed*) printf '%s\n' "$fake_managed" ;;
                    *Config.Image*) printf '%s\n' "$fake_image" ;;
                    *.Image*) printf '%s\n' "$fake_id" ;;
                    *) printf '%s|%s|%s|%s\n' "$fake_image" "$fake_managed" "$fake_source_ref" "$fake_mount" ;;
                esac
                ;;
            stop)
                FAKE_STATE=exited
                FAKE_HEALTH=none
                ;;
            start|restart)
                FAKE_STATE=running
                FAKE_HEALTH=healthy
                ;;
            rename)
                rename_from="$1"; rename_to="$2"
                if [ "$rename_from" = sub-store ]; then
                    FAKE_BACKUP_EXISTS=1; FAKE_BACKUP_STATE="$FAKE_STATE"; FAKE_BACKUP_HEALTH="$FAKE_HEALTH"
                    FAKE_BACKUP_CONFIG_IMAGE="$FAKE_CONFIG_IMAGE"; FAKE_BACKUP_SOURCE_REF="$FAKE_SOURCE_REF"
                    FAKE_BACKUP_MANAGED_LABEL="$FAKE_MANAGED_LABEL"; FAKE_BACKUP_MOUNT="$FAKE_MOUNT"; FAKE_BACKUP_IMAGE_ID="$FAKE_IMAGE_ID"
                    FAKE_CONTAINER_EXISTS=0
                elif [ "$rename_to" = sub-store ]; then
                    FAKE_CONTAINER_EXISTS=1; FAKE_STATE="$FAKE_BACKUP_STATE"; FAKE_HEALTH="$FAKE_BACKUP_HEALTH"
                    FAKE_CONFIG_IMAGE="$FAKE_BACKUP_CONFIG_IMAGE"; FAKE_SOURCE_REF="$FAKE_BACKUP_SOURCE_REF"
                    FAKE_MANAGED_LABEL="$FAKE_BACKUP_MANAGED_LABEL"; FAKE_MOUNT="$FAKE_BACKUP_MOUNT"; FAKE_IMAGE_ID="$FAKE_BACKUP_IMAGE_ID"
                    FAKE_BACKUP_EXISTS=0
                fi
                ;;
            rm)
                if [ "$1" = -f ]; then shift; fi
                if [ "$1" = sub-store ]; then FAKE_CONTAINER_EXISTS=0; else FAKE_BACKUP_EXISTS=0; fi
                ;;
            run)
                FAKE_RUN_COUNT=$((FAKE_RUN_COUNT + 1))
                FAKE_CONTAINER_EXISTS=1; FAKE_STATE=running; FAKE_HEALTH="$FAKE_NEW_HEALTH"
                FAKE_MANAGED_LABEL=true; FAKE_SOURCE_REF="$IMAGE_REF"; FAKE_MOUNT=volume:sub-store-data
                FAKE_IMAGE_ID="$FAKE_NEXT_IMAGE_ID"
                for fake_last_arg do :; done
                FAKE_CONFIG_IMAGE="$fake_last_arg"
                printf 'new-container-id\n'
                ;;
            pull) FAKE_PULL_COUNT=$((FAKE_PULL_COUNT + 1)) ;;
            image)
                case "$1" in
                    inspect)
                        case "$2" in *RepoTags*) printf 'xream/sub-store:latest\nxream/sub-store@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
                            *) printf '%s\n' "$FAKE_PULL_IMAGE_ID" ;;
                        esac
                        ;;
                    rm) FAKE_IMAGE_REMOVED=1 ;;
                esac
                ;;
            volume)
                case "$1" in
                    inspect)
                        [ "$FAKE_VOLUME_PRESENT" = 1 ] || return 1
                        case "${2:-}" in
                            -f)
                                case "$3" in *Labels*) printf '%s\n' "$FAKE_VOLUME_LABEL" ;; *Mountpoint*) printf '/var/lib/docker/volumes/sub-store-data/_data\n' ;; esac
                                ;;
                        esac
                        ;;
                    create) FAKE_VOLUME_PRESENT=1; FAKE_VOLUME_LABEL=true; printf 'sub-store-data\n' ;;
                    rm) FAKE_VOLUME_PRESENT=0; FAKE_VOLUME_REMOVED=1 ;;
                esac
                ;;
            ps) printf '%s\n' "$FAKE_OTHER_IMAGE_USERS" ;;
            logs) FAKE_LOG_ARGS="$*"; printf 'fake log line\n' ;;
            info) printf 'Server Version: 28.0.0\n' ;;
            version) printf '28.0.0\n' ;;
        esac
    }
}

test_config_set_recreates_container_and_preserves_volume() {
    setup_fake_managed_container
    vps_config_set frontend_port 8080
    assert_equal 1 "$FAKE_CONTAINER_EXISTS" 'replacement container exists'
    assert_equal 1 "$FAKE_RUN_COUNT" 'one replacement container created'
    assert_equal running "$FAKE_STATE" 'running state preserved'
    assert_equal 1 "$FAKE_VOLUME_PRESENT" 'data volume preserved'
    vps_load_config
    assert_equal 8080 "$FRONTEND_PORT" 'new port saved after successful apply'
}

test_config_set_keeps_stopped_container_stopped() {
    setup_fake_managed_container
    FAKE_STATE=exited
    vps_config_set backend_port 3100
    assert_equal exited "$FAKE_STATE" 'stopped state preserved after apply'
    assert_equal 1 "$FAKE_VOLUME_PRESENT" 'stopped apply preserves volume'
}

test_failed_health_check_restores_previous_config_and_container() {
    setup_fake_managed_container
    FAKE_NEW_HEALTH=unhealthy
    if vps_config_set frontend_port 8080 >/dev/null 2>&1; then return 1; fi
    assert_equal 1 "$FAKE_CONTAINER_EXISTS" 'previous container restored'
    assert_equal running "$FAKE_STATE" 'previous running state restored'
    assert_equal "$FAKE_IMAGE_ID" "$FAKE_BACKUP_IMAGE_ID" 'restored previous image identity'
    vps_load_config
    assert_equal 3001 "$FRONTEND_PORT" 'previous configuration remains saved'
    assert_equal 1 "$FAKE_VOLUME_PRESENT" 'rollback preserves data volume'
}

test_update_skips_recreate_when_image_digest_is_unchanged() {
    setup_fake_managed_container
    FAKE_PULL_IMAGE_ID="$FAKE_IMAGE_ID"
    vps_update_image
    assert_equal 1 "$FAKE_PULL_COUNT" 'update checks the configured image'
    assert_equal 0 "$FAKE_RUN_COUNT" 'unchanged digest does not recreate the container'
    assert_equal 1 "$FAKE_CONTAINER_EXISTS" 'unchanged update keeps current container'
}

test_update_recreates_only_when_image_id_changes() {
    setup_fake_managed_container
    FAKE_PULL_IMAGE_ID="$FAKE_NEXT_IMAGE_ID"
    vps_update_image
    assert_equal 1 "$FAKE_PULL_COUNT" 'changed update pulls configured image'
    assert_equal 1 "$FAKE_RUN_COUNT" 'changed image recreates container once'
    assert_equal "$FAKE_NEXT_IMAGE_ID" "$FAKE_IMAGE_ID" 'replacement uses the pulled immutable image ID'
    assert_equal 1 "$FAKE_VOLUME_PRESENT" 'image update preserves data volume'
}

test_unmanaged_official_container_is_preserved() {
    setup_fake_managed_container
    FAKE_MANAGED_LABEL=false
    if vps_verify_managed_container sub-store 2>/dev/null; then return 1; fi
    assert_equal 1 "$FAKE_CONTAINER_EXISTS" 'unmanaged official container remains untouched'
    assert_equal 0 "$FAKE_RUN_COUNT" 'unmanaged container is not replaced'
}

test_untrusted_container_is_preserved() {
    setup_fake_managed_container
    FAKE_CONFIG_IMAGE=attacker/sub-store:latest
    if vps_verify_managed_container sub-store 2>/dev/null; then return 1; fi
    assert_equal 1 "$FAKE_CONTAINER_EXISTS" 'untrusted same-name container remains untouched'
    assert_equal 0 "$FAKE_RUN_COUNT" 'untrusted container is not replaced'
}

test_remove_keeps_volume_by_default_and_deletes_only_with_flag() {
    setup_fake_managed_container
    vps_remove --yes >/dev/null
    assert_equal 0 "$FAKE_CONTAINER_EXISTS" 'default remove deletes container'
    assert_equal 1 "$FAKE_VOLUME_PRESENT" 'default remove preserves data volume'
    assert_equal 0 "$FAKE_VOLUME_REMOVED" 'default remove never calls volume deletion'

    setup_fake_managed_container
    vps_remove --delete-data --yes >/dev/null
    assert_equal 0 "$FAKE_CONTAINER_EXISTS" 'delete-data removes container'
    assert_equal 0 "$FAKE_VOLUME_PRESENT" 'delete-data removes managed volume'
    assert_equal 1 "$FAKE_VOLUME_REMOVED" 'delete-data explicitly removes volume'
}

test_remove_requires_yes_without_tty_and_keeps_shared_images() {
    setup_fake_managed_container
    vps_has_tty() { return 1; }
    if vps_remove >/dev/null 2>&1; then return 1; fi
    assert_equal 1 "$FAKE_CONTAINER_EXISTS" 'non-interactive removal without --yes changes nothing'
    FAKE_OTHER_IMAGE_USERS=another-container
    vps_remove --yes >/dev/null
    assert_equal 0 "$FAKE_CONTAINER_EXISTS" 'confirmed remove deletes managed container'
    assert_equal 0 "$FAKE_IMAGE_REMOVED" 'image shared with another container is retained'
}

test_config_directory_symlink_is_rejected() (
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac
    mkdir -p "$TMP/safe-config-dir"
    ln -s "$TMP/safe-config-dir" "$TMP/linked-config-dir"
    VPS_CONFIG_FILE="$TMP/linked-config-dir/sub-store-vps.conf"
    vps_defaults
    if vps_save_config 2>/dev/null; then return 1; fi
    [ ! -e "$TMP/safe-config-dir/sub-store-vps.conf" ]
)

test_status_url_logs_and_lifecycle_commands() {
    setup_fake_managed_container
    status_output="$(vps_container_status)"
    case "$status_output" in *"$API_PATH"*) return 1 ;; esac
    printf '%s\n' "$status_output" | grep -F 'State: running' >/dev/null
    vps_service_control stop >/dev/null
    assert_equal exited "$FAKE_STATE" 'stop command stops service'
    vps_service_control start >/dev/null
    assert_equal running "$FAKE_STATE" 'start command starts service'
    vps_service_control restart >/dev/null
    assert_equal running "$FAKE_STATE" 'restart command restarts service'
    vps_logs --follow >/dev/null
    case "$FAKE_LOG_ARGS" in *'--follow'*) ;; *) return 1 ;; esac
    expected_url='http://public.example.org:3001/?api=http%3A%2F%2Fpublic.example.org%3A3001%2F0123456789abcdef0123456789abcdef0123456789abcdef'
    assert_equal "$expected_url" "$(vps_url --host public.example.org)" 'explicit URL host'
}

test_command_dispatcher_hides_and_explicitly_reads_api_path() {
    setup_fake_managed_container
    config_output="$(vps_main config show)"
    case "$config_output" in *"$API_PATH"*) return 1 ;; esac
    api_output="$(vps_main api-path)"
    assert_equal "$API_PATH" "$api_output" 'dispatcher explicit API-path read'
}

test_documentation_covers_vps_install_commands_and_data_safety() {
    for document in "$ROOT/README.md" "$ROOT/docs/使用笔记.md"; do
        grep -F 'sub-store-vps install' "$document" >/dev/null || return 1
        grep -F 'sub-store-vps api-path' "$document" >/dev/null || return 1
        grep -F '3001' "$document" >/dev/null || return 1
        grep -F '3000' "$document" >/dev/null || return 1
        grep -F -- '--delete-data' "$document" >/dev/null || return 1
    done
    grep -F 'wget' "$ROOT/README.md" >/dev/null
    grep -F 'curl' "$ROOT/README.md" >/dev/null
    grep -F '不会自动卸载' "$ROOT/README.md" >/dev/null
    grep -F '不会自动卸载' "$ROOT/docs/使用笔记.md" >/dev/null
    grep -F 'VPS' "$ROOT/docs/PRD.md" >/dev/null
}

run_test() {
    test_name="$1"
    if ("$test_name"); then
        printf 'ok - %s\n' "$test_name"
    else
        printf 'FAIL - %s\n' "$test_name" >&2
        exit 1
    fi
}

run_test test_default_config
run_test test_default_optional_host_is_valid
run_test test_install_args_override_defaults
run_test test_validation_rejects_equal_ports_invalid_api_path_and_nonofficial_image
run_test test_config_file_is_root_only_and_config_show_redacts_api_path
run_test test_config_parser_never_executes_file_contents
run_test test_config_parser_rejects_missing_and_duplicate_keys
run_test test_operation_lock_serializes_and_releases
run_test test_operation_lock_recovers_dead_owner
run_test test_operation_lock_rejects_live_or_untrusted_lock
run_test test_main_wraps_mutating_commands_with_operation_lock
run_test test_custom_api_path_is_validated_and_api_path_command_reveals_it
run_test test_manual_api_path_set_redeploys_with_new_path
run_test test_cron_uses_five_field_ranges
run_test test_missing_docker_uses_official_apt_repo_for_debian_family
run_test test_apt_installer_writes_only_official_repo_metadata
run_test test_missing_docker_uses_official_rpm_repo_for_rpm_family
run_test test_rpm_installer_writes_official_repo_metadata
run_test test_existing_docker_engine_skips_package_install
run_test test_conflicting_runtime_packages_are_not_replaced
run_test test_unsupported_os_exits_before_changes
run_test test_remote_docker_target_is_refused
run_test test_ddns_host_is_preferred_and_no_ddns_uses_route_ipv4
run_test test_private_route_address_prompts_or_requires_explicit_host
run_test test_container_args_keep_backend_loopback_and_data_in_named_volume
run_test test_ddns_management_url_and_install_summary_include_required_fields
run_test test_config_set_recreates_container_and_preserves_volume
run_test test_config_set_keeps_stopped_container_stopped
run_test test_failed_health_check_restores_previous_config_and_container
run_test test_update_skips_recreate_when_image_digest_is_unchanged
run_test test_update_recreates_only_when_image_id_changes
run_test test_unmanaged_official_container_is_preserved
run_test test_untrusted_container_is_preserved
run_test test_remove_keeps_volume_by_default_and_deletes_only_with_flag
run_test test_remove_requires_yes_without_tty_and_keeps_shared_images
run_test test_config_directory_symlink_is_rejected
run_test test_status_url_logs_and_lifecycle_commands
run_test test_command_dispatcher_hides_and_explicitly_reads_api_path
run_test test_documentation_covers_vps_install_commands_and_data_safety

printf 'VPS config regressions passed.\n'
