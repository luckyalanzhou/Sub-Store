# VPS Docker 一键部署与命令行管理 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 提供一个面向常见 Linux VPS 的单脚本安装器和 `sub-store-vps` 管理命令；缺少 Docker 时安装官方 Engine，再部署官方 Sub-Store 容器，并提供无 LuCI 时所需的配置和状态命令。

**Architecture:** 新增独立 POSIX `sh` 脚本 `scripts/sub-store-vps.sh`，既可交互安装，也可安装到 `/usr/local/sbin/sub-store-vps` 后提供 CLI。配置保存在 root-only 文件，容器使用官方镜像和独立命名卷；不改动 iStoreOS payload、LuCI 或 UCI。

**Tech Stack:** POSIX Shell/BusyBox `ash`、Docker Engine 官方 APT/RPM 仓库、Docker CLI、shell 回归测试。

**Spec:** `docs/superpowers/specs/2026-11-18-vps-docker-install-design.md`

## Global Constraints

- 支持 Ubuntu、Debian、Fedora、CentOS Stream、RHEL、AlmaLinux、Rocky Linux、Oracle Linux 的受支持版本；其他系统在修改前退出。
- 只使用官方 `xream/sub-store` 镜像；默认镜像为 `xream/sub-store:latest`。
- 配置路径为 `/etc/sub-store-vps.conf`，权限为 `0600`；API 路径只由显式命令显示，普通配置输出必须隐藏。
- 数据卷为 `sub-store-data`，容器挂载点为 `/opt/app/data`；只有显式 `--delete-data` 才删除卷。
- 脚本只操作 VPS 本机 Docker 默认 Unix socket；拒绝远程 context、设置了 `DOCKER_HOST` 的目标和非官方同名容器。
- iStoreOS `.run`、LuCI、UCI 和设备端服务流程保持独立，不修改其运行逻辑。
- 容器前端默认发布 `3001`，后端默认只绑定 `127.0.0.1:3000`。

## Review Focus

- **不受支持的发行版或版本**：必须在改软件源前失败；由 Task 2 的 `test_unsupported_os_exits_before_changes` 覆盖。
- **远程 Docker context、`DOCKER_HOST` 或 Podman 兼容 CLI**：不得在意外目标上部署；由 Task 2 的 `test_remote_docker_target_is_refused` 覆盖。
- **已有 `sub-store` 容器/卷**：官方但未受本工具管理的容器不得被接管，非官方同名容器不得触碰；由 Task 3 的 `test_unmanaged_official_container_is_preserved` 和 `test_untrusted_container_is_preserved` 覆盖。
- **API 路径和安装摘要**：随机/自定义路径均须为 48 位十六进制，普通 `config show` 必须脱敏，安装摘要和专用读取命令显示路径；由 Task 1 和 Task 2 的对应测试覆盖。
- **配置应用、更新或移除期间失败**：旧容器与数据卷必须保留/恢复；由 Task 3 的回滚和 `--delete-data` 测试覆盖。

---

### Task 1: 配置文件、参数与交互设置

**Files:**
- Create: `scripts/sub-store-vps.sh`
- Create: `tests/vps-deploy.sh`

**Interfaces:**
- Produces shell functions `vps_defaults`, `vps_parse_install_args`, `vps_prompt_config`, `vps_validate_config`, `vps_load_config`, `vps_save_config`, `vps_show_config`。
- Configuration keys: `FRONTEND_PORT`, `ACCESS_HOST`, `PUBLIC_URL`, `BACKEND_PORT`, `BACKEND_LAN_ACCESS`, `API_PATH`, `IMAGE_REF`, `SYNC_CRON`。
- Test seams: `SUB_STORE_VPS_CONFIG` and `SUB_STORE_VPS_OS_RELEASE` may override host paths in tests; `SUB_STORE_VPS_SOURCE_ONLY=1` sources functions without dispatching `main`.
- Config parser reads only the fixed key whitelist; it must not `source`, `eval`, or execute `/etc/sub-store-vps.conf` contents.

- [ ] **Step 1: Write focused failing cases in `tests/vps-deploy.sh`**
  - `test_default_config`: asserts ports `3001/3000`, backend LAN access `0`, official `latest` image, Cron `55 23 * * *`, and 48-hex API path.
  - `test_install_args_override_defaults`: asserts a custom frontend port, API path and Cron are parsed.
  - `test_validation_rejects_equal_ports_invalid_api_path_and_nonofficial_image`.
  - `test_config_file_is_root_only_and_config_show_redacts_api_path`.
  - `test_custom_api_path_is_validated_and_api_path_command_reveals_it`.
  - `test_manual_api_path_set_redeploys_with_new_path`.
  - `test_cron_uses_five_field_ranges` using the same accepted ranges as `run/payload/root/usr/lib/sub-store/cron.sh`.

- [ ] **Step 2: Run the focused regression and confirm the new cases fail**

Run: `busybox ash tests/vps-deploy.sh`

Expected: FAIL because `scripts/sub-store-vps.sh` and the tested functions do not exist yet.

- [ ] **Step 3: Implement the POSIX shell configuration layer**
  - In `scripts/sub-store-vps.sh`, define the eight config keys, defaults, option parser, interactive prompt, validator, secure read/write, redacted display, and explicit `api-path` output.
  - Interactive prompts use Enter for the displayed default. API path defaults to random 48-hex and accepts a custom value. Non-TTY mode never prompts and allows flags to override defaults.
  - Keep config writes atomic: write a temporary file in the same directory with umask `077`, then rename it into place.

- [ ] **Step 4: Run focused regression and syntax checks**

Run: `busybox ash tests/vps-deploy.sh`

Expected: PASS for defaults, argument parsing, validation, redaction, path permissions, and API-path retrieval.

Run: `sh -n scripts/sub-store-vps.sh && busybox ash -n scripts/sub-store-vps.sh`

Expected: both parsers accept the POSIX shell script.

---

### Task 2: Cross-distro Docker installation, initial deployment, and summary

**Files:**
- Modify: `scripts/sub-store-vps.sh`
- Modify: `tests/vps-deploy.sh`

**Interfaces:**
- Consumes Task 1 configuration functions.
- Produces `vps_detect_platform`, `vps_install_docker`, `vps_ensure_local_docker`, `vps_detect_address`, `vps_deploy_container`, `vps_print_install_summary`.
- Supported input: `/etc/os-release`, local Docker context, optional DDNS host, optional custom settings.

- [ ] **Step 1: Add mocked failing cases for Engine detection and safe targeting**
  - `test_missing_docker_uses_official_apt_repo_for_debian_family`.
  - `test_missing_docker_uses_official_rpm_repo_for_rpm_family`.
  - `test_existing_docker_engine_skips_package_install`.
  - `test_unsupported_os_exits_before_changes`.
  - `test_remote_docker_target_is_refused`.
  - `test_ddns_host_is_preferred_and_no_ddns_uses_route_ipv4`.
  - `test_private_route_address_prompts_or_requires_explicit_host`.

- [ ] **Step 2: Run the focused cases and confirm they fail**

Run: `busybox ash tests/vps-deploy.sh`

Expected: FAIL because platform detection, Engine installation and address handling are not implemented.

- [ ] **Step 3: Implement Docker Engine detection and installation**
  - Use `/etc/os-release` plus available `apt-get`/`dnf`/`yum` to select the Docker official repository instructions for the supported distribution.
  - Do not run Docker's convenience script, remove existing packages, or replace Podman/other runtimes automatically.
  - Start the local Docker service when installed but inactive. Require an unset `DOCKER_HOST` and the local default Unix-socket context before any deployment.

- [ ] **Step 4: Implement DDNS/IP choice and initial container creation**
  - In TTY mode ask whether a DDNS hostname already points to this VPS; accept a hostname or detect the local default-route IPv4. If only a private/unusable route address is found, request a public host instead of printing an inaccessible URL.
  - In non-TTY mode use `--access-host`/`--public-url`; if neither is usable, print the `url --host` recovery command without blocking.
  - Create/reuse `sub-store-data`, publish the frontend on the configured port, bind backend API to loopback unless explicitly enabled, set a random API path, official image, restart policy, log bounds, and health check.
  - Refuse to adopt any existing same-name container unless the tool's root-only config file exists and the image identity is official.

- [ ] **Step 5: Implement the post-install summary and prove it**
  - Print Engine installed/skipped state and version, image/container health, frontend/backend ports and bind addresses, volume name and host/container mount paths, full API path, complete frontend management URL, and status/API/log command examples.
  - Mark the URL/API path as private information. Do not write the full path to non-root-readable logs.
  - `test_install_summary_includes_ports_paths_url_and_management_commands` asserts each required summary field.

- [ ] **Step 6: Run mocked Docker install and summary cases**

Run: `busybox ash tests/vps-deploy.sh`

Expected: PASS for apt/rpm selection, skip-existing Engine behavior, unsupported OS refusal, local-only target check, DDNS/default-route selection, container arguments, volume path, and final summary fields.

---

### Task 3: VPS command management and data-safe lifecycle

**Files:**
- Modify: `scripts/sub-store-vps.sh`
- Modify: `tests/vps-deploy.sh`

**Interfaces:**
- CLI commands: `install`, `status`, `config show`, `config set <key> <value>`, `api-path`, `api-path set <48-hex>`, `api-path rotate`, `url [--host <host>]`, `start`, `stop`, `restart`, `update`, `logs [--follow]`, `remove [--delete-data] [--yes]`.
- Produces `vps_container_status`, `vps_apply_config`, `vps_update_image`, `vps_remove`.

- [ ] **Step 1: Add failing cases for settings and existing-container behavior**
  - `test_config_set_recreates_container_and_preserves_volume`.
  - `test_config_set_keeps_stopped_container_stopped`.
  - `test_failed_health_check_restores_previous_config_and_container`.
  - `test_update_skips_recreate_when_image_digest_is_unchanged`.
  - `test_unmanaged_official_container_is_preserved`.
  - `test_untrusted_container_is_preserved`.
  - `test_remove_keeps_volume_by_default_and_deletes_only_with_flag`.
  - `test_status_url_logs_and_lifecycle_commands`.

- [ ] **Step 2: Run the focused cases and confirm they fail**

Run: `busybox ash tests/vps-deploy.sh`

Expected: FAIL because lifecycle and management commands are not implemented.

- [ ] **Step 3: Implement status, URL, logs, and service controls**
  - `status` reports running/stopped/health/image without exposing API path.
  - `url` prefers public URL, then access host; `--host` creates the complete management URL.
  - `start`, `stop`, `restart`, and `logs [--follow]` target only the verified local official container.
  - `api-path rotate` generates a new 48-hex path and applies it without changing the data volume.
  - `api-path set <48-hex>` and `config set api_path <48-hex>` validate custom paths and apply them through the same rollback-safe path.

- [ ] **Step 4: Implement validated `config set` and image update with rollback**
  - Validate all eight fields before touching the container.
  - Preserve the prior container running state and configuration. Recreate only when the effective deployment config changes; on failed health check restore the prior container/config.
  - `update` pulls only the configured official reference; if its immutable image ID/digest is unchanged, do not recreate the container.

- [ ] **Step 5: Implement safe `remove` semantics**
  - Require confirmation before removing the verified container.
  - Preserve `sub-store-data` by default. Remove it only when the user passes `--delete-data` and confirms.
  - In non-TTY mode require `--yes` for removal; `--delete-data` remains separately required to delete the volume.
  - Delete an image only if it is verified official, no other repo reference names it, and no other container uses it.

- [ ] **Step 6: Run management and failure-recovery cases**

Run: `busybox ash tests/vps-deploy.sh`

Expected: PASS for settings, lifecycle, unchanged-image behavior, rollback, unmanaged-container refusal, and explicit-only data deletion.

---

### Task 4: User documentation and source validation integration

**Files:**
- Modify: `README.md`
- Modify: `docs/PRD.md`
- Modify: `docs/使用笔记.md`
- Modify: `.github/workflows/validate.yml`
- Modify: `tests/vps-deploy.sh`

**Interfaces:**
  - Documents both `curl` and `wget` downloader/install commands, prompt/default behavior, noninteractive flags, configuration keys, manager commands, DDNS/IP selection, port bindings, API-path privacy/read command, and persistent-volume semantics.
- CI runs the VPS script syntax checks with both POSIX `sh` and BusyBox `ash`, then runs `tests/vps-deploy.sh` alongside existing regressions.

- [ ] **Step 1: Add documentation assertions to `tests/vps-deploy.sh`**
  - Assert the README and usage notes mention the install command, `sub-store-vps api-path`, port defaults, and `--delete-data` behavior.

- [ ] **Step 2: Update README, PRD, and usage notes**
  - Keep the iStoreOS `.run` path clearly identified as the existing LuCI product flow.
    - Add VPS installation as an independent option with supported distributions, `curl` and `wget` download/install commands, prompt defaults, full command reference, install summary example, and firewall/TLS notes.

- [ ] **Step 3: Wire syntax and shell regressions into `.github/workflows/validate.yml`**
  - Add `scripts/sub-store-vps.sh` and `tests/vps-deploy.sh` to the POSIX `sh -n`/BusyBox `ash -n` list.
  - Run the mocked VPS regression under BusyBox `ash`.

- [ ] **Step 4: Run focused and existing source regressions**

Run: `busybox ash tests/vps-deploy.sh`

Expected: PASS.

Run: `.github/workflows/validate.yml` commands locally for shell syntax and existing `tests/` regressions.

Expected: PASS; no changes to the iStoreOS behavior or current OpenWrt tests.

---
