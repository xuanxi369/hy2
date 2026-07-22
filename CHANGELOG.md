# Changelog

## 3.0.0

### P0
- 强制可信 SHA-256 校验，删除 best-effort 放行和第三方镜像。
- 临时下载、原子替换、事务备份和失败回滚。
- 修复纯 IPv6 客户端地址和分享链接。
- 自签证书默认输出 pinSHA256。
- custom 证书校验密钥匹配及 SAN/SNI，不再输出占位符。
- systemd 改为专用非 root 用户。
- 修改端口重新校验并走完整事务。

### P1
- 加入 logrotate，移除 CAP_NET_ADMIN。
- 精确匹配 Release 资产哈希，固定并记录版本。
- 检查端口占用、ACME DNS/挑战端口并提示防火墙。
- 默认启用私网保护 ACL。
- systemctl 操作检查状态。
- 菜单改为循环。
- YAML 字符串统一引用。
- 识别 cgroup 内存上限。
- 关闭 obfs 时不再把旧密码写入元数据。

### P2
- 使用 `set -Eeuo pipefail` 和统一错误陷阱。
- 分离参数、验证、配置生成和事务执行。
- 支持非交互、dry-run、差异预览、升级和回滚。
- 提供 ShellCheck/自动测试文件。
- 增加 Debian/Ubuntu/systemd 检查。
- 公网 IP 查询增加提示和关闭选项。
