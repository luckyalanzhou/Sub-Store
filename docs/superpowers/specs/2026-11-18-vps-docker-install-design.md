# VPS Docker 一键部署与命令行管理设计

## 意图

为 VPS 用户提供独立的一键部署和命令行管理入口。安装命令检查 Docker Engine；缺少时使用当前系统对应的 Docker 官方软件源安装并启动；然后部署官方 `xream/sub-store` 镜像。由于 VPS 没有本项目的 LuCI 页面，安装器同时提供交互式设置和后续命令管理。

## 目标

- 支持 Docker 官方安装平台中常见的 Ubuntu、Debian、Fedora、CentOS Stream、RHEL、AlmaLinux、Rocky Linux 和 Oracle Linux 的受支持版本；无法确认的系统或软件源组合在变更前安全退出。
- 提供一份跨发行版 POSIX Shell 脚本，可作为一次性安装器和安装后的 `sub-store-vps` 命令使用。
- 检查本机 Docker Engine；未安装时按发行版配置官方 APT/RPM 软件源、安装 Engine 并启动服务；已运行时跳过 Engine 安装。
- 使用官方 `xream/sub-store` 镜像、容器名 `sub-store`、命名卷 `sub-store-data`，容器数据挂载到 `/opt/app/data`，重启策略为 `unless-stopped`。
- 安装期间允许直接采用默认值，也允许输入自定义设置；API 路径默认生成随机 48 位十六进制字符串，也允许手动指定。
- 安装后提供命令读取 API 路径和访问地址，并查询/修改 LuCI 版本已有的配置项，执行主要容器生命周期操作。
- 所有更新、重建和默认移除操作保留 `sub-store-data`；只允许通过明确的 `--delete-data` 删除数据卷。
- VPS 入口与当前 iStoreOS `.run` 安装器、LuCI、UCI 和设备端服务流程完全分开，不修改或复用这些运行逻辑。

## 配置与默认值

交互终端中每项设置都显示默认值，直接回车采用默认值。API 路径提供随机生成值供采用，也接受手动的 48 位十六进制输入。无交互终端时采用默认值；命令行选项可覆盖默认值，便于自动化部署。

| 设置 | 默认值/规则 |
| --- | --- |
| 前端端口 | `3001`，有效端口 |
| 访问主机名 | 安装向导先询问是否使用已指向此 VPS 的 DDNS；没有时自动取默认路由 IPv4，可手动覆盖 |
| 公开访问地址 | 空；可选 HTTP/HTTPS URL，不含查询参数 |
| 后端 API 端口 | `3000`，有效端口且不得与前端相同 |
| 后端局域网直连 | 关闭；启用时后端 API 发布到所有接口，交互提示其公网风险 |
| API 路径 | 随机 48 位十六进制；允许手动指定 |
| 镜像 | `xream/sub-store:latest`；只允许官方仓库的标签或 SHA-256 摘要 |
| 同步 Cron | `55 23 * * *`；按五字段范围验证 |

配置保存在 root 所有且权限为 `0600` 的 `/etc/sub-store-vps.conf`。普通配置展示隐藏 API 路径；`sub-store-vps api-path` 是显式读取密钥的命令。

## 命令界面

脚本托管于项目 GitHub 的 `main` 分支。初次安装时先下载到临时文件，再安装成管理命令并运行；更新管理命令时重新运行同一下载/安装命令，不自动自更新：

  `curl` 和 `wget` 都可用时任选一种；前提是 VPS 已安装对应下载工具：

  ```sh
  # curl
  curl -fsSL https://raw.githubusercontent.com/luckyalanzhou/sub-store/main/scripts/sub-store-vps.sh -o /tmp/sub-store-vps.sh && \
  sudo install -m 755 /tmp/sub-store-vps.sh /usr/local/sbin/sub-store-vps && \
  sudo /usr/local/sbin/sub-store-vps install
  ```

  ```sh
  # wget
  wget -qO /tmp/sub-store-vps.sh https://raw.githubusercontent.com/luckyalanzhou/sub-store/main/scripts/sub-store-vps.sh && \
  sudo install -m 755 /tmp/sub-store-vps.sh /usr/local/sbin/sub-store-vps && \
  sudo /usr/local/sbin/sub-store-vps install
  ```

安装命令支持交互设置和参数覆盖，例如 `install --frontend-port 8080 --api-path random`。交互安装结束后可用以下命令管理：

```text
sub-store-vps status
sub-store-vps config show
sub-store-vps config set <key> <value>
sub-store-vps api-path
sub-store-vps api-path rotate
sub-store-vps url [--host <IP-or-domain>]
sub-store-vps start | stop | restart
sub-store-vps update
sub-store-vps logs [--follow]
sub-store-vps remove [--delete-data]
```

`config set` 覆盖上表中的全部可配置项并应用变更；API 路径通过专用读取/轮换子命令管理。配置变更或镜像更新需要重建容器时，先保留旧配置和容器状态，健康检查成功后完成替换；失败时恢复旧容器。移除默认保留数据卷，`--delete-data` 才删除它。镜像清理只针对身份和使用情况都已确认的官方镜像。

所有命令要求 root 权限，普通用户通过 `sudo sub-store-vps ...` 调用。`url` 优先使用配置中的公开地址或访问主机名；安装时会询问 DDNS 域名，没有则自动使用默认路由 IPv4。若检测到的地址是私网地址或无法检测，交互模式要求用户填写公网 IP/域名；无交互模式提示用 `--host` 指定地址。不向第三方查询公网 IP。

安装成功后立即输出摘要：Docker 是否由脚本安装及版本、官方镜像和容器状态、前后端端口与监听地址、数据卷名及宿主机/容器挂载路径、48 位 API 路径、前端完整管理网址，以及后续 `status`、`api-path`、`logs` 命令。管理网址包含 API 路径；终端明确提示不要公开分享该地址。未配置公网主机名时显示 `url --host <VPS公网IP或域名>` 的补全方法。

## 安装与部署规则

- 通过 `/etc/os-release` 和系统包管理器选择 Docker 官方软件源及安装命令；不通过通用 convenience script 安装生产 VPS 的 Docker Engine。
- 不自动移除旧 Docker/Podman 包或替换容器运行时；遇到冲突时报告建议并停止。
- 所有命令要求 root 权限；只操作 VPS 本机 Docker Engine 的默认 Unix socket。设置 `DOCKER_HOST`、切换到远程 Docker context 或检测到兼容运行时时拒绝部署。
- Docker 已安装但服务未运行时，尝试启动系统 Docker 服务。
- 检查同名 `sub-store` 容器：配置文件存在且镜像身份为官方时视为本工具既有部署；已有官方容器但没有本工具配置文件时拒绝接管且保持不变；非官方容器存在时同样拒绝。
- 交互安装先询问是否有指向本机的 DDNS 域名；没有时使用默认路由的 IPv4。若检测结果属于私网地址或不可用，交互模式要求输入可访问的 IP/域名；不调用外部 IP 查询服务。
- 镜像必须匹配 `xream/sub-store` 官方命名空间。前端默认绑定所有接口的 `3001`；后端默认绑定 `127.0.0.1:3000`。API 路径随机生成并配置到前端代理。
- 不修改系统防火墙。文档说明 Docker 发布端口可能绕过 UFW/firewalld 规则，推荐通过云防火墙或 HTTPS 反向代理限制访问。

## 非目标

- 修改或替代 iStoreOS `.run`、LuCI、UCI、rpcd 和设备端 `sub-storectl`。
- 安装反向代理、TLS 证书或修改云服务商防火墙规则。
- 支持 Docker 官方平台列表以外的操作系统，或绕过系统包管理器安装 Docker。
- 更新 LuCI 插件或提供 LuCI 专属维护日志。

## 实现方式与取舍

1. **跨发行版 POSIX Shell 脚本及本地管理命令（采用）**：按 Docker 官方平台选择 APT/RPM 安装方式，交互配置后以 Docker CLI 部署；一份源文件同时提供安装和后续操作，满足用户的一键入口和无 LuCI 管理需求。
2. **Compose 文件加初始化脚本**：配置声明更直观，但部署依赖 Compose 配置文件和额外操作，不符合用户选择的跨发行版单脚本入口。
3. **Docker convenience script**：系统覆盖较广，但 Docker 官方将其定位为开发和测试用安装方式，不用于本方案的生产 VPS 安装。

## 验收标准

- Docker 不存在时，系统检测正确、安装 Engine 并启动服务，之后成功部署官方容器。
- Docker 已安装且运行时，跳过 Engine 安装；服务未运行时尝试启动，不能误操作远程 Docker context。
  - `curl` 和 `wget` 下载方式均有文档说明，并指向 GitHub 上的脚本；安装与管理命令均要求 root 权限。
- 发现无本工具配置文件的同名官方容器时不接管；远程 Docker context 或 `DOCKER_HOST` 不会被误操作。
- 交互安装可回车采用默认端口和其他设置；API 路径随机生成，也能设置合法自定义值；无 TTY 时不阻塞，支持参数覆盖。
- `api-path` 可读取已保存的 48 位 API 路径；`config show` 隐藏该值。
- 有 DDNS 时 `url` 使用用户输入的域名；无 DDNS 时使用默认路由 IPv4。私网或无法检测时要求输入 IP/域名或提供 `--host`，不查询外部 IP 服务。
- 安装成功摘要显示 Engine/镜像/容器状态、端口、监听地址、API 路径、数据卷路径、前端管理网址和管理命令；API 路径不写入非 root 可读配置或日志。
- `config set` 能验证并应用所有表格设置；配置应用和镜像更新健康检查失败时恢复旧容器及设置，且保留数据卷。
- `status/start/stop/restart/update/logs/remove` 提供清楚的结果；默认 `remove` 保留卷，只有 `--delete-data` 删除卷。
- 不支持的系统、端口冲突、无效镜像引用和同名非官方容器均在危险变更前明确失败。
- README、PRD 和使用笔记覆盖一键命令、安装时交互项、管理命令、API 路径读取、数据保护和网络安全边界。
- iStoreOS 安装包和设备端逻辑没有新增运行时依赖或行为变化。

## 参考

- Docker 官方平台与安装矩阵：https://docs.docker.com/engine/install/
- Docker Ubuntu 安装：https://docs.docker.com/engine/install/ubuntu/
- Docker Debian 安装：https://docs.docker.com/engine/install/debian/
- Docker Fedora 安装：https://docs.docker.com/engine/install/fedora/
- Docker CentOS 安装：https://docs.docker.com/engine/install/centos/
- Docker RHEL 安装：https://docs.docker.com/engine/install/rhel/
- Docker 端口与防火墙说明：https://docs.docker.com/engine/network/packet-filtering-firewalls/
