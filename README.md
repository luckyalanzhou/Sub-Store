# Sub-Store for iStoreOS

LuCI 管理插件，用于在 iStoreOS/OpenWrt 上安装和管理官方 [`xream/sub-store`](https://hub.docker.com/r/xream/sub-store) Docker 镜像。插件负责设备侧安装、配置和容器生命周期；Sub-Store 应用本身由官方镜像提供。

## 产品目标

- 让用户在 LuCI 中配置并管理 Sub-Store 服务，无需手工维护容器参数。
- 支持 iStoreOS 24.10（opkg）和 25.12（apk）的安装与升级。
- 在镜像、插件更新、安装失败恢复和卸载过程中保护 Docker 数据卷及用户数据。
- 让服务状态、健康情况和维护结果可以在 LuCI 中查看。

## 功能

- 自解压 `.run` 安装器：检测并使用系统对应的包管理器，安装 Docker/LuCI 依赖，安装或升级插件，并在失败时回滚插件或容器部署。
- LuCI 管理页：显示服务状态及访问入口；配置前端和后端端口、访问主机名、公开地址、后端局域网访问、API 密钥和 Cron 表达式。
- 页面顶部显示服务状态。底部操作栏在未安装时显示「安装」，运行中显示「升级/应用、停止、重启」，已停止时显示「升级/应用、启动、删除」。
- 更新维护：「升级/应用」保存并应用设置，分别检查官方镜像和 LuCI 插件。只有镜像变化时才拉取；容器配置变化时可重建容器以应用设置。
- 日志和操作反馈：查看运行日志及维护日志，追踪后台操作状态，按类别清理日志。
- 数据保护：数据保存在 Docker 命名卷 `sub-store-data`；安装、更新、回滚和默认卸载保留该卷。可通过设备命令导出数据；只有明确指定 `--delete-data` 才会删除数据卷。
- 安全边界：验证受管理容器为官方 `xream/sub-store` 镜像；对安装锁、操作状态及数据导出目标做安全检查。

数据导出和卸载命令示例：

```sh
# 在路由器上以 root 执行；目标目录必须已存在且位于数据卷之外
sub-storectl export-data /mnt/usb/sub-store-data.tar.gz

# 卸载插件和容器，保留 Docker 数据卷（默认行为）
sub-storectl uninstall

# 明确删除 Docker 数据卷及其中的数据
sub-storectl uninstall --delete-data
```

## 安装与开发

正式安装包从 [GitHub Releases](https://github.com/luckyalanzhou/sub-store/releases) 获取。在路由器上执行下载的 `.run` 文件：

```sh
chmod 755 sub-store-<版本>.run
./sub-store-<版本>.run
```

首次执行安装包后，在 LuCI 的「服务 → sub-store」页面配置并点击底部「安装」，此时才部署容器。已有部署可通过「升级/应用」保存并应用设置。

镜像引用和 API 路径分别保存在 UCI 的 `image` 和 `api_path` 中，部署时由脚本复核。镜像仅接受官方 `xream/sub-store`，默认使用 `latest`。已停止的容器可在确认后删除，配置和数据卷会保留。

操作详情见 [使用笔记](docs/使用笔记.md)。

从源码构建发布包需要 Linux 构建环境、`makeself` 和版本号：

```sh
VERSION=1.2.3 ./scripts/build-run.sh
```

输出写入 `dist/sub-store-1.2.3.run`。仓库 CI 的源码验证不会构建或发布正式安装包；正式发布通过 GitHub Actions 的 `Build sub-store installer` 手动工作流执行。

## 技术架构

```text
LuCI manage.js ── rpcd/status + rpcd/file.exec ── job.sh ── sub-storectl
       │                                         │              ├─ UCI 配置
       └─ status Lua ── 容器状态/健康/日志       │              ├─ Docker CLI / 官方镜像
                                                 └─ 操作锁和有界维护日志
安装器 (.run / makeself) ── opkg 或 apk ── LuCI 插件与系统服务
                                                   └─ Docker 卷 sub-store-data
```

- LuCI 页面使用原生 LuCI 表单与主题；配置存于 UCI `sub-store.main`。
- `sub-storectl` 是服务控制、配置渲染、镜像更新、数据导出和卸载的设备端命令入口。
- Docker 容器使用固定命名卷 `/opt/app/data` 保存 Sub-Store 数据；镜像来源限定为官方 `xream/sub-store`。
- 安装器和运行脚本以 BusyBox `ash` 为目标 Shell；包管理器根据系统选择 `opkg` 或 `apk`。
- `tests/` 覆盖 Shell、Lua、Node.js 和 Python 行为。源码 CI 还使用 BusyBox ash 执行兼容性回归；iStoreOS 固件 QEMU 集成流程需手动启动。

## 支持范围

- 目标系统：iStoreOS 24.10（opkg）和 25.12（apk）。
- 运行依赖：Docker 服务、LuCI/rpcd 及安装器需要的下载、校验工具。缺少依赖时安装器尝试从设备已配置的软件源安装。
- 访问端口默认值：前端 `3001`，后端 API `3000`；两者不能相同。
- 路由器型号、架构、第三方软件源可用性、外网连通性和反向代理配置取决于设备环境；本仓库源码 CI 不等同于真实路由器验证。

## 相关文档

- [产品需求文档](docs/PRD.md)：目标用户、范围、功能需求、技术约束和验收标准。
- [项目规则](AGENTS.md)：仓库开发、安全、兼容性和发布约束。
