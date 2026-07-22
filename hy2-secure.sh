#!/usr/bin/env bash
# Hysteria 2 安全生产部署脚本
# Debian/Ubuntu + systemd | 可信下载、强制校验、事务回滚、非 root 运行

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly SCRIPT_VERSION="3.0.2"
readonly DEFAULT_HY2_VERSION="v2.10.0"
readonly HY2_REPO="apernet/hysteria"
readonly HY2_BIN="/usr/local/bin/hy2"
readonly HY2_USER="hy2"
readonly HY2_GROUP="hy2"
readonly CONF_DIR="/etc/hy2"
readonly CONF_FILE="${CONF_DIR}/config.yaml"
readonly META_FILE="${CONF_DIR}/.install_meta"
readonly MODE_FILE="${CONF_DIR}/.run_mode"
readonly LOG_DIR="/var/log/hy2"
readonly SERVICE_FILE="/etc/systemd/system/hy2.service"
readonly LOGROTATE_FILE="/etc/logrotate.d/hy2"
readonly BACKUP_ROOT="/var/backups/hy2"

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; BLUE='\033[34m'; PLAIN='\033[0m'
info(){ printf '%b[INFO]%b %s\n' "$CYAN" "$PLAIN" "$*"; }
ok(){ printf '%b[OK]%b %s\n' "$GREEN" "$PLAIN" "$*"; }
warn(){ printf '%b[WARN]%b %s\n' "$YELLOW" "$PLAIN" "$*" >&2; }
err(){ printf '%b[ERR]%b %s\n' "$RED" "$PLAIN" "$*" >&2; }
die(){ err "$*"; exit 1; }

TX_ACTIVE=0
TX_BACKUP=""
DRY_RUN=0
ASSUME_YES=0
NON_INTERACTIVE=0
QUERY_PUBLIC_IP=1
ACTION="menu"
OFFLINE_BIN=""
OFFLINE_HASHES=""
VERSION_SET=0
PORT_SET=0
PASS_SET=0

HY2_VERSION="$DEFAULT_HY2_VERSION"
INSTALL_PROFILE="PRODUCTION"
RUN_MODE="STANDARD"
SET_PORT="8443"
SET_PASS=""
CERT_TYPE="selfsigned"
ACME_DOMAIN=""
ACME_EMAIL=""
ACME_TYPE="http"
CUSTOM_CERT=""
CUSTOM_KEY=""
CUSTOM_SNI=""
SELF_CN="bing.com"
BW_UP=""
BW_DOWN=""
IGNORE_CLIENT_BW="false"
MASQ_ENABLE="0"
MASQ_TYPE="proxy"
MASQ_URL="https://www.bing.com"
MASQ_STRING="OK"
MASQ_HTTP=""
MASQ_HTTPS=""
MASQ_FORCE_HTTPS="true"
LOG_TO_FILE="0"
ENABLE_OBFS="0"
OBFS_PASS=""
PROTECT_PRIVATE="1"

run(){
  if (( DRY_RUN )); then printf '[DRY-RUN]'; printf ' %q' "$@"; printf '\n'; return 0; fi
  "$@"
}

on_error(){
  local rc=$? line=${BASH_LINENO[0]:-unknown} cmd=${BASH_COMMAND:-unknown}
  err "第 ${line} 行执行失败（状态 ${rc}）：${cmd}"
  if (( TX_ACTIVE )); then
    err "正在恢复事务前状态……"
    rollback_transaction || err "自动回滚失败，请从 ${TX_BACKUP} 手动恢复"
  fi
  exit "$rc"
}
trap on_error ERR
trap 'warn "收到中断信号"; if (( TX_ACTIVE )); then rollback_transaction || true; fi; exit 130' INT TERM

require_root(){ (( EUID == 0 )) || die "必须使用 root 运行"; }
command_exists(){ command -v "$1" >/dev/null 2>&1; }
confirm(){
  local prompt=$1 default=${2:-n} ans
  (( ASSUME_YES )) && return 0
  (( NON_INTERACTIVE )) && [[ $default == y ]]
  read -r -p "$prompt" ans || return 1
  ans=${ans:-$default}; [[ $ans == y || $ans == Y ]]
}
pause(){ (( NON_INTERACTIVE )) || read -r -p '按回车继续……' _ || true; }

usage(){ cat <<'EOF'
用法：hy2-secure.sh [动作] [选项]
动作：
  install       安装/重装
  configure     事务式修改端口/密码
  upgrade       升级固定版本二进制
  status        查看状态
  client        输出客户端配置
  rollback      回滚最近一次备份
  uninstall     卸载
  menu          交互菜单（默认）
选项：
  --non-interactive        非交互模式
  --yes                    自动确认
  --dry-run                只显示操作和配置差异
  --version v2.10.0        固定 Hysteria 版本
  --port 8443              UDP 监听端口
  --password VALUE         认证密码
  --cert-type TYPE         selfsigned|acme|custom
  --domain DOMAIN          ACME 域名
  --email EMAIL            ACME 邮箱
  --custom-cert PATH       自备证书
  --custom-key PATH        自备私钥
  --custom-sni DOMAIN      自备证书客户端 SNI
  --offline-binary PATH    离线二进制
  --offline-hashes PATH    官方 hashes.txt
  --no-public-ip-query     禁止查询公网 IP
  --allow-private          不生成私网保护 ACL
EOF
}

parse_args(){
  [[ $# -gt 0 && $1 != --* ]] && { ACTION=$1; shift; }
  while (($#)); do
    case $1 in
      --non-interactive) NON_INTERACTIVE=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --version) HY2_VERSION=${2:?}; VERSION_SET=1; shift ;;
      --port) SET_PORT=${2:?}; PORT_SET=1; shift ;;
      --password) SET_PASS=${2:?}; PASS_SET=1; shift ;;
      --cert-type) CERT_TYPE=${2:?}; shift ;;
      --domain) ACME_DOMAIN=${2:?}; shift ;;
      --email) ACME_EMAIL=${2:?}; shift ;;
      --custom-cert) CUSTOM_CERT=${2:?}; shift ;;
      --custom-key) CUSTOM_KEY=${2:?}; shift ;;
      --custom-sni) CUSTOM_SNI=${2:?}; shift ;;
      --offline-binary) OFFLINE_BIN=${2:?}; shift ;;
      --offline-hashes) OFFLINE_HASHES=${2:?}; shift ;;
      --no-public-ip-query) QUERY_PUBLIC_IP=0 ;;
      --allow-private) PROTECT_PRIVATE=0 ;;
      --help|-h) usage; exit 0 ;;
      *) die "未知参数：$1" ;;
    esac
    shift
  done
}

validate_port(){ [[ ${1:-} =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
validate_version(){ [[ $1 =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; }
validate_domain(){ [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
validate_email(){ [[ $1 =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; }
validate_bandwidth(){ [[ -z $1 || $1 =~ ^[0-9]+([.][0-9]+)?[[:space:]]*(bps|b|kbps|kb|k|mbps|mb|m|gbps|gb|g|tbps|tb|t)$ ]]; }
random_secret(){ openssl rand -base64 48 | tr -dc 'A-Za-z0-9._~-' | head -c "${1:-32}" || true; printf '\n'; }
yaml_quote(){ local s=${1//\'/\'\'}; printf "'%s'" "$s"; }
urlencode(){
  local LC_ALL=C
  local s=$1 out='' c i
  for ((i=0;i<${#s};i++)); do c=${s:i:1}; case $c in [a-zA-Z0-9.~_-]) out+=$c;; *) printf -v c '%%%02X' "'$c"; out+=$c;; esac; done
  printf '%s' "$out"
}
meta_get(){ local key=$1 def=${2:-} v=''; [[ -r $META_FILE ]] && v=$(awk -F= -v k="$key" '$1==k{sub(/^[^=]*=/,"");x=$0}END{print x}' "$META_FILE"); printf '%s\n' "${v:-$def}"; }

load_meta(){
  [[ -r $META_FILE ]] || return 0
  HY2_VERSION=$(meta_get version "$HY2_VERSION")
  INSTALL_PROFILE=$(meta_get profile "$INSTALL_PROFILE")
  RUN_MODE=$(meta_get run_mode "$RUN_MODE")
  CERT_TYPE=$(meta_get cert_type "$CERT_TYPE")
  ACME_DOMAIN=$(meta_get acme_domain "$ACME_DOMAIN")
  ACME_EMAIL=$(meta_get acme_email "$ACME_EMAIL")
  ACME_TYPE=$(meta_get acme_type "$ACME_TYPE")
  CUSTOM_CERT=$(meta_get custom_cert "$CUSTOM_CERT")
  CUSTOM_KEY=$(meta_get custom_key "$CUSTOM_KEY")
  CUSTOM_SNI=$(meta_get custom_sni "$CUSTOM_SNI")
  SELF_CN=$(meta_get self_cn "$SELF_CN")
  SET_PORT=$(meta_get port "$SET_PORT")
  BW_UP=$(meta_get bw_up "$BW_UP"); BW_DOWN=$(meta_get bw_down "$BW_DOWN")
  IGNORE_CLIENT_BW=$(meta_get ignore_client_bw "$IGNORE_CLIENT_BW")
  MASQ_ENABLE=$(meta_get masq_enable "$MASQ_ENABLE"); MASQ_TYPE=$(meta_get masq_type "$MASQ_TYPE")
  MASQ_URL=$(meta_get masq_url "$MASQ_URL"); MASQ_STRING=$(meta_get masq_string "$MASQ_STRING")
  MASQ_HTTP=$(meta_get masq_http "$MASQ_HTTP"); MASQ_HTTPS=$(meta_get masq_https "$MASQ_HTTPS")
  LOG_TO_FILE=$(meta_get log_to_file "$LOG_TO_FILE")
  ENABLE_OBFS=$(meta_get obfs "$ENABLE_OBFS"); OBFS_PASS=$(meta_get obfs_pass "$OBFS_PASS")
  PROTECT_PRIVATE=$(meta_get protect_private "$PROTECT_PRIVATE")
}

write_meta_to(){
  local f=$1
  cat >"$f" <<EOF
script_version=${SCRIPT_VERSION}
version=${HY2_VERSION}
profile=${INSTALL_PROFILE}
run_mode=${RUN_MODE}
cert_type=${CERT_TYPE}
acme_domain=${ACME_DOMAIN}
acme_email=${ACME_EMAIL}
acme_type=${ACME_TYPE}
custom_cert=$([[ $CERT_TYPE == custom ]] && printf '%s' "$CONF_DIR/certs/custom.crt")
custom_key=$([[ $CERT_TYPE == custom ]] && printf '%s' "$CONF_DIR/certs/custom.key")
custom_sni=${CUSTOM_SNI}
self_cn=${SELF_CN}
port=${SET_PORT}
bw_up=${BW_UP}
bw_down=${BW_DOWN}
ignore_client_bw=${IGNORE_CLIENT_BW}
masq_enable=${MASQ_ENABLE}
masq_type=${MASQ_TYPE}
masq_url=${MASQ_URL}
masq_string=${MASQ_STRING}
masq_http=${MASQ_HTTP}
masq_https=${MASQ_HTTPS}
log_to_file=${LOG_TO_FILE}
obfs=${ENABLE_OBFS}
obfs_pass=$([[ $ENABLE_OBFS == 1 ]] && printf '%s' "$OBFS_PASS")
protect_private=${PROTECT_PRIVATE}
installed_at=$(date -Iseconds)
EOF
  chmod 600 "$f"
}

check_platform(){
  [[ -r /etc/os-release ]] || die "无法识别操作系统"
  # shellcheck disable=SC1091
  . /etc/os-release
  case ${ID:-} in debian|ubuntu) ;; *) die "仅支持 Debian/Ubuntu，当前为 ${ID:-unknown}";; esac
  [[ $(ps -p 1 -o comm= 2>/dev/null) == systemd ]] || die "PID 1 不是 systemd"
  command_exists systemctl || die "缺少 systemctl"
  validate_version "$HY2_VERSION" || die "版本格式无效：$HY2_VERSION"
  case $(uname -m) in x86_64|amd64) HY2_ARCH=amd64;; aarch64|arm64) HY2_ARCH=arm64;; *) die "不支持架构：$(uname -m)";; esac

  local required=(curl openssl awk sed grep sha256sum install mktemp ss getent flock)
  local missing=() c
  for c in "${required[@]}"; do command_exists "$c" || missing+=("$c"); done
  if ((${#missing[@]})); then
    info "安装依赖：${missing[*]}"
    run apt-get update -qq
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl openssl ca-certificates coreutils procps iproute2 dnsutils util-linux logrotate
  fi
  for c in "${required[@]}"; do command_exists "$c" || die "关键依赖不可用：$c"; done
  detect_memory
}

detect_memory(){
  local host_bytes cgroup_bytes max_bytes
  host_bytes=$(awk '/MemTotal/{print $2*1024}' /proc/meminfo)
  cgroup_bytes=$host_bytes
  if [[ -r /sys/fs/cgroup/memory.max ]]; then
    max_bytes=$(cat /sys/fs/cgroup/memory.max)
    [[ $max_bytes =~ ^[0-9]+$ ]] && cgroup_bytes=$max_bytes
  elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
    max_bytes=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
    [[ $max_bytes =~ ^[0-9]+$ && $max_bytes -lt 9223372036854771712 ]] && cgroup_bytes=$max_bytes
  fi
  (( cgroup_bytes < host_bytes )) && host_bytes=$cgroup_bytes
  RAM_MB=$((host_bytes/1024/1024))
  if (( RAM_MB <= 200 )); then RUN_MODE=LOW_RAM; else [[ $RUN_MODE == LOW_RAM ]] && RUN_MODE=STANDARD; fi
  info "有效内存限制：${RAM_MB} MiB；模式：${RUN_MODE}"
}

validate_inputs(){
  validate_port "$SET_PORT" || die "端口无效：$SET_PORT"
  [[ -n $SET_PASS ]] || SET_PASS=$(random_secret 32)
  validate_bandwidth "$BW_UP" || die "上行带宽格式无效"
  validate_bandwidth "$BW_DOWN" || die "下行带宽格式无效"
  case $CERT_TYPE in
    selfsigned) [[ -n $SELF_CN ]] || die "自签名称不能为空" ;;
    acme)
      validate_domain "$ACME_DOMAIN" || die "ACME 域名无效"
      validate_email "$ACME_EMAIL" || die "ACME 邮箱无效"
      [[ $ACME_TYPE == http || $ACME_TYPE == tls ]] || die "ACME 类型只能是 http/tls"
      ;;
    custom)
      [[ -r $CUSTOM_CERT && -r $CUSTOM_KEY ]] || die "自备证书或私钥不可读"
      validate_domain "$CUSTOM_SNI" || die "必须提供有效的 --custom-sni"
      openssl x509 -in "$CUSTOM_CERT" -noout -checkhost "$CUSTOM_SNI" >/dev/null 2>&1 || die "证书 SAN 不包含 ${CUSTOM_SNI}"
      ;;
    *) die "未知证书类型：$CERT_TYPE";;
  esac
}

check_port_free(){
  local proto=$1 port=$2
  if ss -H -ln${proto} 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"; then
    if systemctl is-active --quiet hy2 2>/dev/null && [[ $port == $(meta_get port '') ]]; then return 0; fi
    die "${proto^^} 端口 ${port} 已被占用"
  fi
}

preflight_network(){
  check_port_free u "$SET_PORT"
  if [[ $CERT_TYPE == acme ]]; then
    local challenge_port=80 proto=t
    [[ $ACME_TYPE == tls ]] && challenge_port=443
    check_port_free "$proto" "$challenge_port"
    local resolved
    resolved=$(getent ahosts "$ACME_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)
    [[ -n $resolved ]] || die "ACME 域名无法解析：$ACME_DOMAIN"
    info "ACME DNS：$(tr '\n' ' ' <<<"$resolved")"
  fi
  if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    if ! ufw status | grep -Eq "${SET_PORT}/udp[[:space:]]+ALLOW"; then warn "UFW 已启用，但未确认 ${SET_PORT}/udp 已放行"; fi
  fi
  if command_exists nft && nft list ruleset >/dev/null 2>&1; then info "检测到 nftables，请确认 UDP ${SET_PORT} 入站规则"; fi
  warn "云服务器还需在安全组中放行 UDP ${SET_PORT}"
}

create_service_user(){
  getent group "$HY2_GROUP" >/dev/null || run groupadd --system "$HY2_GROUP"
  id "$HY2_USER" >/dev/null 2>&1 || run useradd --system --gid "$HY2_GROUP" --home-dir "$CONF_DIR" --shell /usr/sbin/nologin "$HY2_USER"
}

release_base(){ printf 'https://github.com/%s/releases/download/app/%s' "$HY2_REPO" "$HY2_VERSION"; }
extract_expected_hash(){
  local hashes=$1 asset=$2
  awk -v wanted="$asset" '
    NF >= 2 {
      hash=$1
      file=$NF
      sub(/^\*/, "", file)
      gsub(/\\/, "/", file)
      count=split(file, parts, "/")
      base=parts[count]
      if (base == wanted && hash ~ /^[[:xdigit:]]+$/ && length(hash) == 64) {
        print tolower(hash)
        exit
      }
    }
    /^SHA256 \(/ {
      line=$0
      sub(/^SHA256 \(/, "", line)
      split(line, pair, /\) = /)
      file=pair[1]
      count=split(file, parts, "/")
      base=parts[count]
      hash=pair[2]
      if (base == wanted && hash ~ /^[[:xdigit:]]+$/ && length(hash) == 64) {
        print tolower(hash)
        exit
      }
    }
  ' "$hashes"
}
secure_download_binary(){
  local out=$1 asset="hysteria-linux-${HY2_ARCH}" work hashes expected actual
  work=$(mktemp -d); hashes="$work/hashes.txt"
  if [[ -n $OFFLINE_BIN || -n $OFFLINE_HASHES ]]; then
    [[ -r $OFFLINE_BIN && -r $OFFLINE_HASHES ]] || die "离线安装必须同时提供二进制和官方 hashes.txt"
    cp "$OFFLINE_BIN" "$out"; cp "$OFFLINE_HASHES" "$hashes"
  else
    local base; base=$(release_base)
    info "仅从 GitHub 官方 Release 下载 ${HY2_VERSION}"
    if ! curl --proto '=https' --tlsv1.2 -fL --retry 3 --connect-timeout 15 -o "$hashes" "${base}/hashes.txt"; then
      die "无法下载 ${HY2_VERSION} 的 hashes.txt；该版本可能不存在，请检查 GitHub Release 标签"
    fi
    if ! curl --proto '=https' --tlsv1.2 -fL --retry 3 --connect-timeout 15 -o "$out" "${base}/${asset}"; then
      die "无法下载 ${HY2_VERSION} 的 ${asset}；请确认版本和架构"
    fi
  fi
  expected=$(extract_expected_hash "$hashes" "$asset")
  [[ $expected =~ ^[0-9a-f]{64}$ ]] || {
    warn "hashes.txt 中与当前架构有关的条目："
    grep -F "${asset}" "$hashes" >&2 || true
    die "官方哈希中没有找到文件名为 ${asset} 的精确条目"
  }
  actual=$(sha256sum "$out" | awk '{print $1}')
  [[ ${actual,,} == ${expected,,} ]] || die "SHA-256 校验失败：期望 ${expected}，实际 ${actual}"
  [[ $(od -An -tx1 -N4 "$out" | tr -d ' \n') == 7f454c46 ]] || die "下载文件不是 ELF"
  chmod 755 "$out"; rm -rf "$work"
  ok "SHA-256 校验通过：${actual}"
}

backup_state(){
  local dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)-$$"
  run mkdir -p "$dir"
  local p name
  for p in "$HY2_BIN" "$CONF_DIR" "$SERVICE_FILE" "$LOGROTATE_FILE"; do
    name=$(sed 's#^/##;s#/#__#g' <<<"$p")
    if [[ -e $p ]]; then run cp -a "$p" "$dir/$name"; else run touch "$dir/$name.absent"; fi
  done
  printf '%s\n' "$dir"
}

begin_transaction(){ TX_BACKUP=$(backup_state); TX_ACTIVE=1; info "事务备份：$TX_BACKUP"; }
restore_backup(){
  local dir=$1 p name
  [[ -d $dir ]] || die "备份不存在：$dir"
  systemctl stop hy2 >/dev/null 2>&1 || true
  for p in "$HY2_BIN" "$CONF_DIR" "$SERVICE_FILE" "$LOGROTATE_FILE"; do
    name=$(sed 's#^/##;s#/#__#g' <<<"$p")
    rm -rf "$p"
    [[ -e $dir/$name ]] && cp -a "$dir/$name" "$p"
  done
  systemctl daemon-reload
  [[ -f $SERVICE_FILE ]] && systemctl enable --now hy2 || true
}
rollback_transaction(){ local dir=${1:-$TX_BACKUP}; TX_ACTIVE=0; restore_backup "$dir"; warn "已回滚到：$dir"; }
commit_transaction(){ TX_ACTIVE=0; ok "事务已提交；备份保留在 ${TX_BACKUP}"; }

prepare_certificates(){
  local stage=$1
  mkdir -p "$stage/certs" "$stage/acme" "$stage/masq"
  case $CERT_TYPE in
    selfsigned)
      openssl req -x509 -nodes -newkey rsa:3072 -sha256 -days 825 \
        -keyout "$stage/certs/server.key" -out "$stage/certs/server.crt" \
        -subj "/CN=${SELF_CN}" -addext "subjectAltName=DNS:${SELF_CN}" >/dev/null 2>&1
      ;;
    custom)
      openssl x509 -in "$CUSTOM_CERT" -noout >/dev/null
      openssl pkey -in "$CUSTOM_KEY" -noout >/dev/null
      local cert_pub key_pub
      cert_pub=$(openssl x509 -in "$CUSTOM_CERT" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')
      key_pub=$(openssl pkey -in "$CUSTOM_KEY" -pubout -outform DER | sha256sum | awk '{print $1}')
      [[ $cert_pub == "$key_pub" ]] || die "证书与私��不匹配"
      cp "$CUSTOM_CERT" "$stage/certs/custom.crt"; cp "$CUSTOM_KEY" "$stage/certs/custom.key"
      ;;
    acme) ;;
  esac
  chmod 750 "$stage" "$stage/certs" "$stage/acme" "$stage/masq"
  find "$stage/certs" -type f -name '*.key' -exec chmod 640 {} + 2>/dev/null || true
  find "$stage/certs" -type f -name '*.crt' -exec chmod 644 {} + 2>/dev/null || true
}

generate_config(){
  local out=$1 pass_q; pass_q=$(yaml_quote "$SET_PASS")
  {
    printf 'listen: %s\n\n' "$(yaml_quote ":${SET_PORT}")"
    case $CERT_TYPE in
      selfsigned) printf 'tls:\n  cert: %s\n  key: %s\n  sniGuard: dns-san\n' "$(yaml_quote "$CONF_DIR/certs/server.crt")" "$(yaml_quote "$CONF_DIR/certs/server.key")";;
      custom) printf 'tls:\n  cert: %s\n  key: %s\n  sniGuard: dns-san\n' "$(yaml_quote "$CONF_DIR/certs/custom.crt")" "$(yaml_quote "$CONF_DIR/certs/custom.key")";;
      acme)
        printf 'acme:\n  domains:\n    - %s\n  email: %s\n  ca: letsencrypt\n  dir: %s\n  type: %s\n' "$(yaml_quote "$ACME_DOMAIN")" "$(yaml_quote "$ACME_EMAIL")" "$(yaml_quote "$CONF_DIR/acme")" "$ACME_TYPE"
        [[ $ACME_TYPE == http ]] && printf '  http:\n    altPort: 80\n' || printf '  tls:\n    altPort: 443\n'
        ;;
    esac
    printf '\nauth:\n  type: password\n  password: %s\n' "$pass_q"
    if [[ -n $BW_UP || -n $BW_DOWN ]]; then
      printf '\nbandwidth:\n'; [[ -n $BW_UP ]] && printf '  up: %s\n' "$(yaml_quote "$BW_UP")"; [[ -n $BW_DOWN ]] && printf '  down: %s\n' "$(yaml_quote "$BW_DOWN")"
    fi
    printf '\nignoreClientBandwidth: %s\n' "$IGNORE_CLIENT_BW"
    if [[ $RUN_MODE == LOW_RAM ]]; then
      cat <<'EOF'

quic:
  initStreamReceiveWindow: 2097152
  maxStreamReceiveWindow: 2097152
  initConnReceiveWindow: 5242880
  maxConnReceiveWindow: 5242880
  maxIdleTimeout: 30s
  maxIncomingStreams: 256
EOF
    fi
    if [[ $ENABLE_OBFS == 1 ]]; then
      printf '\nobfs:\n  type: salamander\n  salamander:\n    password: %s\n' "$(yaml_quote "$OBFS_PASS")"
    fi
    if [[ $PROTECT_PRIVATE == 1 ]]; then
      cat <<'EOF'

acl:
  inline:
    - reject(127.0.0.0/8)
    - reject(10.0.0.0/8)
    - reject(172.16.0.0/12)
    - reject(192.168.0.0/16)
    - reject(169.254.0.0/16)
    - reject(100.64.0.0/10)
    - reject(::1/128)
    - reject(fc00::/7)
    - reject(fe80::/10)
EOF
    fi
    if [[ $MASQ_ENABLE == 1 && $RUN_MODE != LOW_RAM ]]; then
      printf '\nmasquerade:\n  type: %s\n' "$MASQ_TYPE"
      case $MASQ_TYPE in
        proxy) printf '  proxy:\n    url: %s\n    rewriteHost: true\n    insecure: false\n' "$(yaml_quote "$MASQ_URL")";;
        string) printf '  string:\n    content: %s\n    statusCode: 200\n    headers:\n      content-type: text/plain\n' "$(yaml_quote "$MASQ_STRING")";;
        file) printf '  file:\n    dir: %s\n' "$(yaml_quote "$CONF_DIR/masq")";;
      esac
      [[ -n $MASQ_HTTP ]] && printf '  listenHTTP: %s\n' "$(yaml_quote "$MASQ_HTTP")"
      [[ -n $MASQ_HTTPS ]] && printf '  listenHTTPS: %s\n  forceHTTPS: %s\n' "$(yaml_quote "$MASQ_HTTPS")" "$MASQ_FORCE_HTTPS"
    fi
  } >"$out"
  chmod 640 "$out"
}

generate_unit(){
  local out=$1 mem_lines=''
  if [[ $RUN_MODE == LOW_RAM ]]; then
    local mem_limit=$(( RAM_MB * 70 / 100 )); (( mem_limit < 48 )) && mem_limit=48
    mem_lines="Environment=GOGC=20\nEnvironment=GOMEMLIMIT=${mem_limit}MiB\nMemoryHigh=$((RAM_MB*80/100))M\nMemoryMax=$((RAM_MB*90/100))M"
  fi
  cat >"$out" <<EOF
[Unit]
Description=Hysteria 2 Service
Documentation=https://v2.hysteria.network/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${HY2_USER}
Group=${HY2_GROUP}
ExecStart=${HY2_BIN} server -c ${CONF_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
WorkingDirectory=${CONF_DIR}
UMask=0027
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
RestrictNamespaces=true
SystemCallArchitectures=native
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ReadWritePaths=-${CONF_DIR}/acme ${LOG_DIR}
RuntimeDirectory=hy2
TasksMax=1024
${mem_lines}
EOF
  if [[ $LOG_TO_FILE == 1 ]]; then
    printf 'StandardOutput=append:%s/hy2.log\nStandardError=append:%s/hy2.err.log\n' "$LOG_DIR" "$LOG_DIR" >>"$out"
  else
    printf 'StandardOutput=journal\nStandardError=journal\nSyslogIdentifier=hy2\n' >>"$out"
  fi
  cat >>"$out" <<'EOF'

[Install]
WantedBy=multi-user.target
EOF
}

generate_logrotate(){ cat >"$1" <<EOF
${LOG_DIR}/*.log {
  daily
  rotate 14
  size 20M
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
  su ${HY2_USER} ${HY2_GROUP}
}
EOF
}

show_diff(){
  local old=$1 new=$2 label=$3
  info "配置差异：${label}"
  if [[ -r $old ]]; then diff -u "$old" "$new" || true; else sed 's/^/+/' "$new"; fi
}

install_transaction(){
  check_platform; validate_inputs; preflight_network
  local work stage_bin stage_conf stage_unit stage_meta stage_logrotate
  work=$(mktemp -d); stage_bin="$work/hy2"; stage_conf="$work/config.yaml"; stage_unit="$work/hy2.service"; stage_meta="$work/install_meta"; stage_logrotate="$work/logrotate"
  secure_download_binary "$stage_bin"
  prepare_certificates "$work/conf"
  generate_config "$stage_conf"; generate_unit "$stage_unit"; write_meta_to "$stage_meta"; generate_logrotate "$stage_logrotate"
  show_diff "$CONF_FILE" "$stage_conf" config.yaml
  show_diff "$SERVICE_FILE" "$stage_unit" hy2.service
  (( DRY_RUN )) && { ok "Dry-run 完成，未修改系统"; rm -rf "$work"; return; }
  confirm "应用以上变更？(y/N): " n || { info "已取消"; rm -rf "$work"; return; }

  begin_transaction
  create_service_user
  systemctl stop hy2 >/dev/null 2>&1 || true
  install -d -m 0750 -o root -g "$HY2_GROUP" "$CONF_DIR"
  install -d -m 0750 -o "$HY2_USER" -g "$HY2_GROUP" "$CONF_DIR/acme" "$LOG_DIR"
  install -d -m 0750 -o root -g "$HY2_GROUP" "$CONF_DIR/certs" "$CONF_DIR/masq"
  cp -a "$work/conf/certs/." "$CONF_DIR/certs/" 2>/dev/null || true
  cp -a "$work/conf/masq/." "$CONF_DIR/masq/" 2>/dev/null || true
  chown -R root:"$HY2_GROUP" "$CONF_DIR/certs" "$CONF_DIR/masq"
  chown -R "$HY2_USER":"$HY2_GROUP" "$CONF_DIR/acme" "$LOG_DIR"
  install -m 0755 "$stage_bin" "${HY2_BIN}.new"; mv -f "${HY2_BIN}.new" "$HY2_BIN"
  install -m 0640 -o root -g "$HY2_GROUP" "$stage_conf" "$CONF_FILE"
  install -m 0600 -o root -g root "$stage_meta" "$META_FILE"
  printf '%s\n' "$RUN_MODE" >"$MODE_FILE"; chmod 600 "$MODE_FILE"
  install -m 0644 "$stage_unit" "$SERVICE_FILE"
  install -m 0644 "$stage_logrotate" "$LOGROTATE_FILE"
  systemctl daemon-reload
  systemctl enable hy2 >/dev/null
  if ! systemctl restart hy2; then journalctl -u hy2 -n 80 --no-pager || true; rollback_transaction; die "服务启动失败，已回滚"; fi
  sleep 2
  if ! systemctl is-active --quiet hy2; then journalctl -u hy2 -n 80 --no-pager || true; rollback_transaction; die "健康检查失败，已回滚"; fi
  commit_transaction; rm -rf "$work"; ok "安装完成：Hysteria ${HY2_VERSION}"
  print_client
}

upgrade_binary(){
  local requested_version=$HY2_VERSION
  check_platform; [[ -r $META_FILE ]] || die "尚未安装"; load_meta
  (( VERSION_SET )) && HY2_VERSION=$requested_version
  validate_version "$HY2_VERSION" || die "版本格式无效：$HY2_VERSION"
  local tmp; tmp=$(mktemp); secure_download_binary "$tmp"
  (( DRY_RUN )) && { "$tmp" version || true; rm -f "$tmp"; return; }
  begin_transaction
  systemctl stop hy2
  install -m 0755 "$tmp" "${HY2_BIN}.new"; mv -f "${HY2_BIN}.new" "$HY2_BIN"
  if ! systemctl start hy2 || ! systemctl is-active --quiet hy2; then rollback_transaction; die "升级失败，已回滚"; fi
  local meta_tmp; meta_tmp=$(mktemp); write_meta_to "$meta_tmp"; install -m 0600 "$meta_tmp" "$META_FILE"; rm -f "$meta_tmp" "$tmp"
  commit_transaction; ok "已升级到 ${HY2_VERSION}"
}

cert_fingerprint(){ openssl x509 -in "$1" -outform DER 2>/dev/null | sha256sum | awk '{print $1}'; }
extract_password(){
  local v
  v=$(awk '/^[[:space:]]+password:/{sub(/^[^:]+:[[:space:]]*/,"");print;exit}' "$CONF_FILE")
  v=${v#\'}; v=${v%\'}; v=${v//\'\'/\'}
  printf '%s\n' "$v"
}
public_hosts(){
  PUBLIC_V4=''; PUBLIC_V6=''
  (( QUERY_PUBLIC_IP )) || return 0
  warn "将向 api64.ipify.org 查询公网 IP；可用 --no-public-ip-query 禁止"
  PUBLIC_V4=$(curl -4fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)
  PUBLIC_V6=$(curl -6fsS --max-time 4 https://api64.ipify.org 2>/dev/null || true)
}
print_client(){
  [[ -r $META_FILE && -r $CONF_FILE ]] || die "尚未安装"
  load_meta; SET_PASS=$(extract_password); public_hosts
  local host='YOUR_SERVER_IP' uri_host sni insecure=false fp=''
  if [[ $CERT_TYPE == acme ]]; then host=$ACME_DOMAIN; sni=$ACME_DOMAIN
  elif [[ $CERT_TYPE == custom ]]; then sni=$CUSTOM_SNI; [[ -n $PUBLIC_V4 ]] && host=$PUBLIC_V4 || { [[ -n $PUBLIC_V6 ]] && host="[$PUBLIC_V6]"; }
  else sni=$SELF_CN; insecure=true; [[ -n $PUBLIC_V4 ]] && host=$PUBLIC_V4 || { [[ -n $PUBLIC_V6 ]] && host="[$PUBLIC_V6]"; }; [[ -r $CONF_DIR/certs/server.crt ]] && fp=$(cert_fingerprint "$CONF_DIR/certs/server.crt")
  fi
  uri_host=$host
  cat <<EOF
server: ${host}:${SET_PORT}
auth: $(yaml_quote "$SET_PASS")
tls:
  sni: $(yaml_quote "$sni")
  insecure: ${insecure}
EOF
  [[ -n $fp ]] && printf '  pinSHA256: %s\n' "$(yaml_quote "$fp")"
  if [[ $ENABLE_OBFS == 1 ]]; then printf 'obfs:\n  type: salamander\n  salamander:\n    password: %s\n' "$(yaml_quote "$OBFS_PASS")"; fi
  local link="hysteria2://$(urlencode "$SET_PASS")@${uri_host}:${SET_PORT}/?sni=$(urlencode "$sni")&insecure=$([[ $insecure == true ]] && echo 1 || echo 0)"
  [[ -n $fp ]] && link+="&pinSHA256=$(urlencode "$fp")"
  [[ $ENABLE_OBFS == 1 ]] && link+="&obfs=salamander&obfs-password=$(urlencode "$OBFS_PASS")"
  printf '分享链接：%s\n' "$link"
}

reconfigure(){
  [[ -r $META_FILE && -r $CONF_FILE ]] || die "尚未安装"
  local requested_port=$SET_PORT requested_pass=$SET_PASS
  load_meta
  (( PORT_SET )) && SET_PORT=$requested_port
  if (( PASS_SET )); then SET_PASS=$requested_pass; else SET_PASS=$(extract_password); fi
  if (( ! NON_INTERACTIVE )); then
    local x
    read -r -p "新端口 [${SET_PORT}]：" x || true; SET_PORT=${x:-$SET_PORT}
    read -r -p '新密码 [回车保持]：' x || true; [[ -n $x ]] && SET_PASS=$x
  fi
  validate_port "$SET_PORT" || die "端口无效：$SET_PORT"
  install_transaction
}

show_status(){
  systemctl status hy2 --no-pager -l || true
  [[ -x $HY2_BIN ]] && "$HY2_BIN" version || true
  [[ -r $META_FILE ]] && { echo "版本：$(meta_get version unknown)；端口：$(meta_get port unknown)；模式：$(meta_get run_mode unknown)"; }
  ss -lunp | grep -E ":$(meta_get port 0)\\b" || true
}

manual_rollback(){
  local latest
  latest=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{sub(/^[^ ]+ /,"");print}' || true)
  [[ -n $latest ]] || die "没有可用备份"
  warn "将回滚到：$latest"; confirm "确认回滚？(y/N): " n || return 0
  restore_backup "$latest"; ok "回滚完成"
}

service_control(){
  local action=$1
  case $action in start|stop|restart|enable|disable) systemctl "$action" hy2;; *) die "无效服务操作";; esac
  ok "systemctl ${action} 成功"
}

uninstall(){
  confirm "彻底卸载 Hysteria 2？(y/N): " n || return 0
  begin_transaction
  systemctl disable --now hy2 >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$LOGROTATE_FILE" "$HY2_BIN"; rm -rf "$CONF_DIR"
  systemctl daemon-reload
  commit_transaction
  warn "专用用户和备份目录已保留，便于审计或恢复"
}

ask_install(){
  check_platform
  read -r -p "监听端口 [${SET_PORT}]：" x || true; SET_PORT=${x:-$SET_PORT}; validate_port "$SET_PORT" || die "端口无效"
  read -r -p '连接密码 [回车随机生成]：' SET_PASS || true; [[ -n $SET_PASS ]] || SET_PASS=$(random_secret 32)
  echo '证书：1) 自签 2) ACME 3) 自备'; read -r -p '选择 [1]：' x || true
  case ${x:-1} in
    2) CERT_TYPE=acme; read -r -p '域名：' ACME_DOMAIN; read -r -p '邮箱：' ACME_EMAIL;;
    3) CERT_TYPE=custom; read -r -p '证书路径：' CUSTOM_CERT; read -r -p '私钥路径：' CUSTOM_KEY; read -r -p '证书 DNS SNI：' CUSTOM_SNI;;
    *) CERT_TYPE=selfsigned; read -r -p "自签 SAN [${SELF_CN}]：" x || true; SELF_CN=${x:-$SELF_CN};;
  esac
  confirm '启用私网/元数据地址保护 ACL？(Y/n)：' y && PROTECT_PRIVATE=1 || PROTECT_PRIVATE=0
  confirm '启用文件日志？(y/N)：' n && LOG_TO_FILE=1 || LOG_TO_FILE=0
  confirm '启用 Salamander？(y/N)：' n && { ENABLE_OBFS=1; OBFS_PASS=$(random_secret 24); } || { ENABLE_OBFS=0; OBFS_PASS=''; }
  install_transaction
}

menu(){
  while true; do
    clear || true
    cat <<EOF
Hysteria 2 安全部署脚本 v${SCRIPT_VERSION}
1. 安装/重装     2. 修改端口/密码    3. 升级固定版本
4. 状态          5. 客户端配置       6. 查看日志
7. 回滚最近备份  8. 启动             9. 停止
10. 重启         11. 卸载            0. 退出
EOF
    read -r -p '选择：' x || exit 0
    case $x in
      1) ask_install;; 2) reconfigure;; 3) read -r -p "目标版本 [${HY2_VERSION}]：" v || true; HY2_VERSION=${v:-$HY2_VERSION}; VERSION_SET=1; upgrade_binary;;
      4) show_status;; 5) print_client;; 6) journalctl -u hy2 -n 100 --no-pager;; 7) manual_rollback;;
      8) service_control start;; 9) service_control stop;; 10) service_control restart;; 11) uninstall;; 0) break;; *) warn '无效选项';;
    esac
    pause
  done
}

main(){
  require_root; parse_args "$@"
  exec 9>/run/lock/hy2-secure.lock; flock -n 9 || die "已有另一个实例正在运行"
  case $ACTION in
    menu) menu;; install) install_transaction;; configure) reconfigure;; upgrade) upgrade_binary;;
    status) show_status;; client) print_client;; rollback) manual_rollback;; uninstall) uninstall;; *) usage; die "未知动作：$ACTION";;
  esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
