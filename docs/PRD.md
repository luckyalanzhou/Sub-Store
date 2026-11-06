# Sub-Store for iStoreOS 产品需求文档

| 项目 | 内容 |
| --- | --- |
| 产品 | Sub-Store for iStoreOS LuCI 插件 |
| 状态 | 根据当前仓库实现整理；实现行为以代码为准 |
| 目标平台 | iStoreOS 24.10（opkg）、iStoreOS 25.12（apk） |
| 上游应用 | 官方 Docker 镜像 `xream/sub-store` |

## 1. 产品概述

本项目为 iStoreOS/OpenWrt 提供 LuCI 管理界面和设备侧脚本，用于安装、配置、运行、更新和卸载 Sub-Store。它管理官方 Sub-Store Docker 镜像及其运行环境，不修改或重新打包上游应用。

## 2. 产品目标

1. 用户能够通过 LuCI 和标准 `.run` 安装包完成 Sub-Store 的部署与日常服务管理。
2. 用户能够配置访问地址、安全密钥和服务端口，并识别服务运行或健康异常。
3. 插件与应用镜像能够独立检测和更新，避免无变化时无谓拉取镜像或重建容器。
4. 安装、升级、回滚和卸载以保留用户数据为默认行为；数据删除必须由用户明确触发。
5. 安装器能适配目标系统的包管理器和 BusyBox `ash` 环境，并对失败操作给出可诊断结果。

## 3. 用户与场景

### 目标用户

- 在 iStoreOS/OpenWrt 路由器上运行 Sub-Store 的家庭或个人用户。
- 需要通过 LuCI 管理服务、更新和检查运行状态的设备管理员。

### 主要场景

- 首次安装插件后，由用户在 LuCI 点击「安装」部署官方镜像。
- 修改端口、访问主机名、公开访问 URL、后端局域网访问、API 密钥或同步 Cron 设置。
- 查看服务状态、健康检查结果、版本和日志，执行启动、停止或重启。
- 检查并分别更新镜像和 LuCI 插件。
- 迁移旧数据目录到 Docker 数据卷、导出数据、卸载插件，或在明确选择时删除数据。
- 安装或更新失败时恢复此前插件文件或容器部署。

## 4. 范围

### 本项目负责

- LuCI 菜单、管理页、UCI 配置和 rpcd 操作接口。
- `.run` 安装、依赖安装、包管理器检测、升级事务和失败恢复。
- Docker 容器配置、服务生命周期、健康状态、镜像更新与数据卷管理。
- 插件更新、运行/维护日志、数据导出、旧目录迁移和安全卸载。

### 不在范围内

- 修改、重新打包或替代 Sub-Store 上游应用。
- 提供自有订阅处理后端或第三方镜像源。
- 保证用户网络中的 DNS、反向代理、证书、防火墙和远程访问策略可用。
- 在 LuCI 管理页中提供数据导出界面；当前数据导出通过设备端 `sub-storectl export-data` 命令执行。

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
```

### 技术组件

- 前端：LuCI JavaScript 表单组件及 LuCI 原生样式。
- 状态/RPC：Lua、rpcd file.exec ACL。
- 设备端：POSIX Shell，兼容 BusyBox `ash`；UCI、Docker CLI、cron。
- 健康检查和版本识别：Node.js 脚本，在官方容器中检查前端资源、API 和应用版本。
- 发布：`scripts/build-run.sh` 使用 makeself 生成 `.run`；GitHub Actions 分离源码验证、固件集成和正式发布。

## 7. 质量属性与约束

- **兼容性：** 支持 iStoreOS 24.10/opkg 与 25.12/apk；Shell 脚本通过 `sh -n` 和 BusyBox `ash -n` 检查。
- **数据安全：** 更新、回滚和默认卸载保留数据；明确删除选项才可删除数据卷。
- **路径安全：** 操作锁、日志、备份和导出文件检查符号链接、所有者和权限；不安全时停止。
- **更新可靠性：** 镜像和插件按各自检测结果处理；插件包执行 SHA-256 验证。
- **界面一致性：** 使用 LuCI 原生控件；保存、应用和服务控制语义清楚。
- **可诊断性：** 后台操作有可轮询状态、阶段、结果和有界日志。
- **发布边界：** 源码 CI 不构建发布包；正式 `.run` 通过手动发布工作流构建，遵循版本递增和失败恢复流程。

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

## 9. 发布与验收边界

- 每次源码推送和 Pull Request 执行 `.github/workflows/validate.yml`，验证源码和回归行为，不构建正式安装包。
- 固件级安装测试由 `.github/workflows/istoreos-integration.yml` 手动启动；通过静态测试或源码 CI 不能推断所有路由器型号、架构、软件源和网络均已验证。
- 正式发布由 `.github/workflows/build-run.yml` 手动启动；自动定时任务用于检查官方镜像 smoke 状态，不等同于发布新版本。
- 当前验收条目描述本仓库已编码的目标行为；设备上的可用性还受 Docker 存储空间、软件源、网络、端口冲突及用户代理配置影响。
