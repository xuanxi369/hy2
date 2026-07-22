# Changelog

## 3.1.0

- 新增自动配置本地防火墙功能（支持 UFW 和 iptables）
- 添加 `--auto-firewall` 参数用于非交互模式自动配置
- 交互式安装时询问是否自动配置防火墙
- 卸载时可选择清理防火墙规则
- 防火墙规则自动持久化（iptables-persistent 或 /etc/iptables/rules.v4）
- 改进防火墙检测逻辑，区分云安全组和本地防火墙
- 在 `/etc/hy2/.firewall_managed` 记录防火墙管理状态

## 3.0.2

- 修复 Hysteria 2 ACL CIDR 语法：CIDR 地址必须直接写入 `reject(10.0.0.0/8)`，不能使用不存在的 `cidr:` 前缀。
- 同步修复 IPv4、IPv6、回环、链路本地和 CGNAT 保护规则。
- 增加断言，禁止生成任何 `reject(cidr:...)` 规则。

## 3.0.1

- 修复官方 `hashes.txt` 使用 `build/文件名` 时无法匹配资产的问题。
- 仍按 basename 精确匹配，避免把 amd64 误匹配为 amd64-avx。
- 同时兼容 GNU sha256sum 与 BSD `SHA256 (file) = hash` 格式。
- 改为先下载 hashes.txt，再下载约 20 MB 二进制。
- 不存在的版本现在给出明确提示，而不是原始 ERR 行号。
- Release URL 改为可读的 `app/vX.Y.Z` 形式。
- 新增真实发布格式回归测试。

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
