# 本地 LuCI 预览

依赖 Docker Desktop 和本机已有的 `qidian-luci-preview:latest` 镜像。该镜像来自 `D:\Projects\QiDian\scripts\luci-preview`，包含 OpenWrt 24.10 和 Argon 2.4.7。

在项目根目录运行：

```powershell
docker build -f scripts/luci-preview/Dockerfile -t sub-store-luci-preview .
docker run --rm --name sub-store-luci-preview -p 127.0.0.1:18081:80 -e SUB_STORE_PREVIEW_STATE=running sub-store-luci-preview
```

访问 http://127.0.0.1:18081/cgi-bin/luci/admin/services/sub-store，使用 root 和空密码登录。初始状态支持 `running`、`exited`、`not-created`。源码修改后重新构建镜像。

状态和操作由模拟脚本提供，不连接宿主机 Docker 或真实服务。主题版本与设备可能不同，预览不能替代设备验证。
