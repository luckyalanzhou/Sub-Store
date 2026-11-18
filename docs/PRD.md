# Sub-Store for iStoreOS 产品需求文档

| 项目 | 内容 |
| --- | --- |
| 产品 | Sub-Store for iStoreOS LuCI 插件与独立 VPS 管理命令 |
| 状态 | 根据当前仓库实现整理；实现行为以代码为准 |
| 目标平台 | iStoreOS 24.10（opkg）、iStoreOS 25.12（apk） |
| 上游应用 | 官方 Docker 镜像 `xream/sub-store` |

## 1. 产品概述

本项目为 iStoreOS/OpenWrt 提供 LuCI 管理界面和设备侧脚本，并为常见 Linux VPS 提供独立的 Shell 安装器与管理命令，用于安装、配置、运行、更新和卸载 Sub-Store。两条部署入口互相独立；都管理官方 Sub-Store Docker 镜像及其运行环境，不修改或重新打包上游应用。

## 2. 产品目标

1. 用户能够通过 LuCI 和标准 `.run` 安装包完成 Sub-Store 的部署与日常服务管理。
2. 用户能够配置访问地址、安全密钥和服务端口，并识别服务运行或健康异常。
3. 插件与应用镜像能够独立检测和更新，避免无变化时无谓拉取镜像或重建容器。
4. 安装、升级、回滚和卸载以保留用户数据为默认行为；数据删除必须由用户明确触发。
5. 安装器能适配目标系统的包管理器和 BusyBox `ash` 环境，并对失败操作给出可诊断结果。
6. VPS 用户可以通过一条 `curl` 或 `wget` 命令安装独立管理器；Docker Engine 缺失时使用 Docker 官方软件源安装，再部署官方 Sub-Store 容器。

## 3. 用户与场景

### 目标用户

- 在 iStoreOS/OpenWrt 路由器上运行 Sub-Store 的家庭或个人用户。
- 需要通过 LuCI 管理服务、更新和检查运行状态的设备管理员。
- 在受支持的 Linux VPS 上运行 Sub-Store、没有 LuCI 管理页面的服务器管理员。

### 主要场景

- 首次安装插件后，由用户在 LuCI 点击「安装」部署官方镜像。
- 修改端口、访问主机名、公开访问 URL、后端局域网访问、API 密钥或同步 Cron 设置。
- 查看服务状态、健康检查结果、版本和日志，执行启动、停止或重启。
- 检查并分别更新镜像和 LuCI 插件。
- 迁移旧数据目录到 Docker 数据卷、导出数据、卸载插件，或在明确选择时删除数据。
- 安装或更新失败时恢复此前插件文件或容器部署。
- 在 VPS 首次部署时设置端口、DDNS/公网地址、API 路径和同步 Cron，并通过 CLI 管理服务。

## 4. 范围

### 本项目负责

- LuCI 菜单、管理页、UCI 配置和 rpcd 操作接口。
- `.run` 安装、依赖安装、包管理器检测、升级事务和失败恢复。
- Docker 容器配置、服务生命周期、健康状态、镜像更新与数据卷管理。
- 插件更新、运行/维护日志、数据导出、旧目录迁移和安全卸载。
- VPS 独立安装器及 `sub-store-vps` CLI；使用 `/etc/sub-store-vps.conf` 保存 root-only 配置，并使用本机 Docker 默认 Unix socket 管理容器。

### 不在范围内

- 修改、重新打包或替代 Sub-Store 上游应用。
- 提供自有订阅处理后端或第三方镜像源。
- 保证用户网络中的 DNS、反向代理、证书、防火墙和远程访问策略可用。
- 在 LuCI 管理页中提供数据导出界面；当前数据导出通过设备端 `sub-storectl export-data` 命令执行。
- 把 VPS 安装、配置或服务控制集成进 iStoreOS 的 `.run`、LuCI、UCI 或 rpcd 流程。
- 在 VPS 上自动配置系统防火墙、云防火墙、TLS 证书或反向代理。

## 5. 核心功能需求

### FR-1 安装与升级

- 提供 `.run` 自解压安装包。
- 根据 `/etc/apk/arch` 等系统标志选择 `apk` 或 `opkg`，不能在 apk 系统上退回残留的 opkg。
- 检查并安装 Docker、LuCI、rpcd 和下载校验依赖。
- 安装、升级时保存事务所需的旧插件文件和容器状态；失败时执行恢复，并保留恢复所需状态以便诊断。
- 插件单独更新时不得改变 Docker 镜像或容器。

### FR-2 配置与访问

LuCI 提供以下配置：

| 配置 | 默认/规则 |
| --- | --- |
| 前端管理端口 | 默认 `3001`，有效端口 |
| 后端 API 端口 | 默认 `3000`，有效端口且不得与前端端口相同 |
| 访问主机名 | 可选域名或 IPv4，不含协议和端口 |
| 公开访问地址 | 可选 HTTP/HTTPS 地址，不含查询参数，端口范围 `1–65535` |
| 后端局域网直连 | 默认关闭 |
| API 密钥 | UCI `api_path`，48 位十六进制字符 |
| 镜像 | UCI `image`，默认 `xream/sub-store:latest`，允许官方仓库的标签或摘要 |
| 同步 Cron 表达式 | 默认 `55 23 * * *`，按五字段格式和字段范围验证 |

「安装」和「升级/应用」保存并应用设置。启动、停止和重启只控制现有容器。

### FR-3 服务管理和状态

- 页面显示服务状态和打开管理界面的入口。
- 顶部显示状态，底部操作栏按状态显示按钮。尚未安装显示安装，运行中显示升级/应用、停止、重启，已停止显示升级/应用、启动、删除。
- 删除需确认，保留配置与持久化数据，只清理归属明确且没有其他容器使用的镜像。
- 展示容器健康状态、Sub-Store 应用版本、插件版本和镜像信息。
- 服务尚未创建、Docker 不可用、维护操作进行中等状态应能被识别并反馈。

### FR-4 更新

- “升级/应用”应用已保存配置，并分别检查官方镜像和 LuCI 插件更新。
- 镜像按当前设备平台解析官方仓库的远端镜像摘要；只有摘要变化时才拉取并替换容器。
- 镜像无变化时不拉取。容器配置有变化时重建以应用配置。
- 插件更新从项目 GitHub Release 下载 `.run` 与 SHA-256 校验文件，校验后仅更新插件文件。
- 更新操作在后台排队执行，页面展示执行状态和维护日志；同一时刻拒绝并发维护操作。

### FR-5 日志与诊断

- 页面分开显示容器运行日志和插件维护日志。
- 日志清理按类别执行；清理运行日志时如需重启容器，应保留 Docker 数据卷；清理维护日志不得影响服务。
- 安装日志与后台操作日志有大小上限，并检查日志/锁状态路径的安全属性。

### FR-6 数据迁移、导出和卸载

- Sub-Store 持久化数据存放在 Docker 命名卷 `sub-store-data`，挂载至容器 `/opt/app/data`。
- 安装期间可将旧数据目录迁入数据卷；拒绝覆盖非空目标卷或不安全路径。
- `sub-storectl export-data <绝对路径>` 生成压缩数据导出文件；目标目录必须存在，目标文件不得位于数据卷内。
- `sub-storectl uninstall` 和 `sub-storectl uninstall --keep-data` 删除插件及受管容器，但保留数据卷。
- 仅 `sub-storectl uninstall --delete-data` 删除数据卷。

### FR-7 官方镜像和容器身份

- 受管理容器只允许使用 `xream/sub-store` 或等价 `docker.io/xream/sub-store` 镜像引用。
- 操作前检查容器身份；不匹配时安全停止，不移除或替换未受信任容器。
- 数据卷与容器生命周期分离，容器替换或更新不得重置用户数据。

### FR-8 VPS 独立部署与命令行管理

- 提供跨发行版 POSIX Shell 脚本和 `sub-store-vps` 管理命令；脚本要求 root，只操作本机 Docker 默认 Unix socket。
- 仅接受 Docker 官方文档列出的 Ubuntu、Debian、Fedora、CentOS Stream、RHEL、AlmaLinux、Rocky Linux 和 Oracle Linux 受支持版本。未知系统、无效版本、远程 Docker context、`DOCKER_HOST` 或 Podman 兼容 CLI 在危险变更前必须拒绝。
- Docker Engine 缺失时按发行版使用 Docker 官方 APT/RPM 软件源安装并启动；不得运行 convenience script、删除旧运行时或自动替换 Podman。
- 首次安装支持交互默认值和非交互参数。前端默认 `3001` 且发布到所有接口，后端默认 `3000` 且绑定 `127.0.0.1`；DDNS 用户输入优先，没有时使用默认路由 IPv4，不向第三方查询公网 IP。
- API 路径默认随机生成 48 位十六进制值；安装摘要和 `api-path` 命令可以显式显示。配置文件权限为 `0600`，`config show` 隐藏路径。
- `config set` 验证并应用配置；配置/镜像替换需在健康检查失败时恢复旧容器和设置。原先停止的容器应用后仍保持停止。
- `status`、`url`、`start`、`stop`、`restart`、`update`、`logs` 和 `remove` 提供无 LuCI 场景的管理能力。更新与默认移除保留 `sub-store-data`；只有明确指定 `--delete-data` 才删除数据卷。
- 普通删除需要确认，非交互模式须使用 `--yes`；只允许清理官方且未被其他容器/镜像引用的镜像。
- VPS 入口不调用 iStoreOS `.run`、UCI、rpcd 或设备端 `sub-storectl`，不改变路由器现有流程。

## 6. 技术架构

```text
浏览器 / LuCI
  ├─ manage.js：原生 LuCI 表单、轮询状态、发起后台操作
  ├─ status（Lua）：组合 UCI/容器/健康/版本/日志状态
  └─ rpcd file.exec → job.sh：操作锁、后台执行、状态快照和有界日志
                          └─ /usr/bin/sub-storectl
                               ├─ UCI 配置渲染及端口映射
                               ├─ Docker 容器和官方镜像管理
                               ├─ 数据卷迁移、导出、保留或显式删除
                               └─ 插件更新与健康诊断

makeself .run → install.sh → opkg/apk → LuCI 插件、服务脚本和 Docker 部署

VPS install script → Docker 官方 APT/RPM → 本机 Docker Engine → xream/sub-store
                              └→ /etc/sub-store-vps.conf (0600)
```

### 技术组件

- 前端：LuCI JavaScript 表单组件及 LuCI 原生样式。
- 状态/RPC：Lua、rpcd file.exec ACL。
- 设备端：POSIX Shell，兼容 BusyBox `ash`；UCI、Docker CLI、cron。
- 健康检查和版本识别：Node.js 脚本，在官方容器中检查前端资源、API 和应用版本。
- 发布：`scripts/build-run.sh` 使用 makeself 生成 `.run`；GitHub Actions 分离源码验证、固件集成和正式发布。
- VPS：`scripts/sub-store-vps.sh` 通过独立 CLI 管理 root-only 配置、Docker Engine、容器和命名卷；不读取 LuCI/UCI 状态。

## 7. 质量属性与约束

- **兼容性：** 支持 iStoreOS 24.10/opkg 与 25.12/apk；Shell 脚本通过 `sh -n` 和 BusyBox `ash -n` 检查。
- **数据安全：** 更新、回滚和默认卸载保留数据；明确删除选项才可删除数据卷。
- **路径安全：** 操作锁、日志、备份和导出文件检查符号链接、所有者和权限；不安全时停止。
- **更新可靠性：** 镜像和插件按各自检测结果处理；插件包执行 SHA-256 验证。
- **界面一致性：** 使用 LuCI 原生控件；保存、应用和服务控制语义清楚。
- **可诊断性：** 后台操作有可轮询状态、阶段、结果和有界日志。
- **发布边界：** 源码 CI 不构建发布包；正式 `.run` 通过手动发布工作流构建，遵循版本递增和失败恢复流程。
- **VPS 网络安全：** 脚本不改防火墙；文档说明 Docker 端口发布可能绕过常规 UFW/firewalld 规则，并建议用云防火墙和 HTTPS 反向代理限制公网访问。

## 8. 验收标准

| ID | 验收条件 | 验证依据 |
| --- | --- | --- |
| AC-1 | 安装器在 apk 标志存在时选用 apk，即使系统同时残留 opkg；否则按可用系统选择 opkg/apk。 | `tests/package-manager.sh`、`tests/install-permissions.sh` |
| AC-2 | 安装、更新及失败回滚不丢失 `sub-store-data`；普通卸载保留卷，只有 `--delete-data` 删除卷。 | `tests/docker-volume-storage.sh`、`tests/install-recovery.sh`、`tests/uninstall-cleanup.sh` |
| AC-3 | 非官方镜像容器不会被插件作为受管容器替换或删除。 | `tests/image-update.sh`、`tests/install-recovery.sh` |
| AC-4 | 镜像摘要未变化时不拉取；镜像或容器配置有变化时才重新部署并验证服务健康，失败可恢复之前部署。 | `tests/image-update.sh`、`.github/workflows/build-run.yml` 中的 Docker smoke job |
| AC-5 | 插件更新包在安装前完成 SHA-256 校验，并且插件单独更新不改变 Docker 镜像和容器。 | `tests/plugin-update.sh`、`tests/plugin-install-rollback.sh` |
| AC-6 | LuCI 表单拒绝相同前后端端口、无效公开地址/API 密钥/Cron；保存只保存，保存并应用会重启以应用配置。 | `tests/luci-view.test.js`、`tests/cron-validation.sh` |
| AC-7 | LuCI 能呈现服务、健康、版本和日志状态；异步维护操作显示运行/成功/失败结果，并阻止并发操作。 | `tests/luci-status.lua`、`tests/luci-view.test.js`、`tests/operation-feedback.sh` |
| AC-8 | 导出拒绝相对路径、数据卷内目标和不安全目标；成功导出可被识别为归档，导出过程保障一致性。 | `tests/export-data.sh` |
| AC-9 | 安装锁、状态目录、日志、备份或导出路径若权限/所有者/符号链接不符合要求，相关操作安全失败且不覆盖不可信目标。 | `tests/install-operation-lock.sh`、`tests/install-log.sh`、`tests/install-permissions.sh`、`tests/export-data.sh` |
| AC-10 | 所有目标 Shell 文件通过 POSIX `sh -n` 和 BusyBox `ash -n`；Lua、Node.js 和 Python 检查按源码 CI 执行。 | `.github/workflows/validate.yml` |
| AC-11 | 在 iStoreOS 24.10 和 25.12 固件环境完成安装/更新集成验证后，才能宣称固件级验收通过。 | 手动 `.github/workflows/istoreos-integration.yml`；源码 CI 不替代此项 |
| AC-12 | VPS 脚本只接受受支持发行版/版本并选择对应 Docker 官方仓库；其他系统在写入软件源或安装软件前失败。 | `tests/vps-deploy.sh`、Docker 官方安装文档 |
| AC-13 | Docker 缺失时按 APT/RPM 分支安装并启动；已有 Docker Engine 不重复安装；远程 context、`DOCKER_HOST` 和 Podman 兼容 CLI 不会成为部署目标。 | `tests/vps-deploy.sh`、Ubuntu/Debian/Fedora/RHEL Docker 官方安装文档 |
| AC-14 | 安装默认值和参数可用；DDNS/默认路由选择不调用第三方 IP 查询；API 路径为 48 位十六进制、普通配置输出脱敏、安装摘要可读。 | `tests/vps-deploy.sh` |
| AC-15 | VPS 配置应用和镜像更新维持卷与容器原运行状态；健康检查失败后恢复旧配置和容器；同一镜像 ID 不重建。 | `tests/vps-deploy.sh` |
| AC-16 | VPS 默认删除保留数据卷；只有显式 `--delete-data` 删除且删除前确认；非交互移除必须给出 `--yes`，共用或非官方镜像不被清理。 | `tests/vps-deploy.sh` |
| AC-17 | VPS 文档提供 curl/wget 下载命令、配置参数、命令参考、端口边界、API 路径隐私和防火墙/TLS 注意事项；其入口不修改 iStoreOS `.run`、LuCI 或 UCI 流程。 | README、使用笔记、源码差异检查 |
| AC-18 | VPS 脚本和回归在 POSIX `sh` 与 BusyBox `ash` 语法下通过，并与现有 iStoreOS shell 回归一起运行。 | `.github/workflows/validate.yml` |

## 9. 发布与验收边界

- 每次源码推送和 Pull Request 执行 `.github/workflows/validate.yml`，验证源码和回归行为，不构建正式安装包。
- 固件级安装测试由 `.github/workflows/istoreos-integration.yml` 手动启动；通过静态测试或源码 CI 不能推断所有路由器型号、架构、软件源和网络均已验证。
- 正式发布由 `.github/workflows/build-run.yml` 手动启动；自动定时任务用于检查官方镜像 smoke 状态，不等同于发布新版本。
- 当前验收条目描述本仓库已编码的目标行为；设备上的可用性还受 Docker 存储空间、软件源、网络、端口冲突及用户代理配置影响。
