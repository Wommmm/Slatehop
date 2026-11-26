# 管理 Mac 的远程访问

## 租客如何连接

向机主取得设备地址、端口和远控密码，在 SlateHop 首页连接。被控 Mac 会在每次新连接时检查密码和租期。租期届满后，新连接会被拒绝，已经建立的会话可以继续使用。密码重置后，可在设备列表里编辑原记录，填写机主提供的新密码。

## 机主如何操作

对于由机主管理的专用宿主，使用独立的管理员终端连接到被控 Mac。机主工具支持三项操作。截止时间参数使用 UTC Unix 毫秒，显示给租客时会转换为本地时间。

| 操作 | 用途 |
| --- | --- |
| `status` | 查看当前状态和有效期。 |
| `renew <截止时间>` | 延长有效期，租客下次仍使用原密码。 |
| `reset <截止时间>` | 生成新密码并设置截止时间。新密码只随本次操作返回，请私下交给租客。 |

这些命令依赖专用宿主安装以及管理员权限。机主脚本的固定位置为 `/Library/SlateHopOperator/operator-admin.sh`，应由 root 所有，并由机主从独立 SSH 通道调用。租客应使用普通 macOS 账户。普通桌面 App 可以连接设备和显示租期。

## 从源码了解管理工具

[专用宿主安装器](../tools/slatehop-host-admin/managed-host-install.sh)支持安装、更新与回退，并核对部署方的签名团队、归档校验值和服务身份。[机主命令行工具](../tools/slatehop-host-admin/operator-admin.sh)负责读取状态、续期和重置。要在开发用 Mac 上预览管理窗口，可运行以下命令。演示数据保存在内存中。

```sh
admin_app="$(bash tools/slatehop-host-admin/build.sh)" && open -n "$admin_app" --args --demo
```
