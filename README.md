# Hysteria 2 安全生产部署脚本

`hy2-secure.sh` 是对原脚本的安全重构版，目标平台为 Debian/Ubuntu + systemd。

VPS配置适配：
最低极限支持：128 MB 内存（低内存模式）
正常推荐：256 MB 内存（标准模式）
舒适配置：512 MB 内存（完整功能无压力）

## 关键变化

- 固定版本，默认 `v2.10.0`；只从 GitHub 官方 Release 下载。
- `hashes.txt` 获取或 SHA-256 校验失败时立即终止。
- 临时下载、精确文件名哈希匹配、原子替换。
- 安装、重装、改端口、升级均创建备份；启动失败自动回滚。
- systemd 使用专用 `hy2` 用户，只保留 `CAP_NET_BIND_SERVICE`。
- 自签证书带 SAN；客户端配置自动加入 `pinSHA256`。
- 正确生成纯 IPv6 地址及 URI 方括号。
- custom 证书复制到受控目录，并验证私钥匹配、SAN 与 SNI。
- 私网/链路本地地址保护 ACL 默认开启。
- 文件日志配套 logrotate。
- 检查 UDP 端口、ACME DNS、80/443 挑战端口、UFW/nftables 提示。
- cgroup 感知的低内存检测。
- 支持非交互、`--dry-run`、配置差异、升级与回滚。
- 公网 IP 查询会明确提示，可用 `--no-public-ip-query` 禁止。
- **自动配置本地防火墙**（UFW/iptables），支持交互式和命令行模式。
- **用户名备注**：自定义服务器显示名称，便于区分多个服务器。
- **Brutal 拥塞控制**：可选启用，适合高延迟网络。
- **协议嗅探**：默认启用，提升路由规则准确性。
- **伪装域名**：默认启用，降低被识别风险。
- **二维码生成**：快速导入配置到移动设备。

## 使用

前置条件：克隆仓库

```bash
git clone https://github.com/xuanxi369/hy2.git && cd hy2
```

方式一：菜单模式安装

```bash
chmod +x hy2-secure.sh
sudo ./hy2-secure.sh
```

方式二：交互式安装（会询问所有配置）

```bash
chmod +x hy2-secure.sh
sudo ./hy2-secure.sh install
```

方式三：命令行快速部署（跳过询问）

```bash
sudo ./hy2-secure.sh install --non-interactive --yes \
  --port 9527 --password 'MyPass' --user-name 'MyServer' \
  --enable-brutal --auto-firewall
```

## 调试

非交互自签安装 + 自动配置防火墙：

```bash
sudo ./hy2-secure.sh install --non-interactive --yes \
  --version v2.10.0 --port 8443 --password '强密码' --auto-firewall
```

ACME：

```bash
sudo ./hy2-secure.sh install --non-interactive --yes \
  --cert-type acme --domain hy2.example.com --email admin@example.com \
  --port 443 --password '强密码'
```

修改端口和密码（同样走备份、差异和回滚）：

```bash
sudo ./hy2-secure.sh configure --port 9443 --password '新密码' --yes
```

升级固定版本：

```bash
sudo ./hy2-secure.sh upgrade --version v2.10.0 --yes
```

只预览：

```bash
sudo ./hy2-secure.sh install --dry-run
```

离线安装必须同时提供二进制和从官方 Release 获取的 `hashes.txt`：

```bash
sudo ./hy2-secure.sh install \
  --offline-binary ./hysteria-linux-amd64 \
  --offline-hashes ./hashes.txt
```

## 注意

- 云厂商安全组仍需人工放行 UDP 服务端口（脚本无法自动配置云平台 API）。
- 脚本可自动配置本地防火墙（UFW/iptables），交互模式会询问，或使用 `--auto-firewall` 参数。
- 默认 ACL 会阻止客户端访问私网、回环和链路本地地址；确有需要时使用 `--allow-private`。
- 脚本会保留 `/var/backups/hy2`，卸载不会自动删除备份和专用用户。
- 防火墙规则在 `/etc/hy2/.firewall_managed` 中记录，卸载时可选择清理。
