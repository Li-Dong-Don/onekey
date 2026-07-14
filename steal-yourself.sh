#!/bin/sh
set -eu

# VLESS + XTLS-Reality "偷自己" installer
# Supported: Debian 10+, Ubuntu 20.04+, Alpine 3.14+ (systemd/OpenRC)

SCRIPT_VERSION="1.0.0"
XRAY_PORT="${XRAY_PORT:-443}"
CADDY_BACKEND_PORT="${CADDY_BACKEND_PORT:-8003}"
DOMAIN="${DOMAIN:-}"
DECOY_DOMAIN="${DECOY_DOMAIN:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
ASSUME_YES=0
FORCE=0
NO_COLOR="${NO_COLOR:-0}"

if [ "$NO_COLOR" = 1 ] || [ ! -t 1 ]; then
  RED='' GREEN='' YELLOW='' BLUE='' RESET=''
else
  RED='\033[31m' GREEN='\033[32m' YELLOW='\033[33m' BLUE='\033[34m' RESET='\033[0m'
fi

info() { printf "%b[信息]%b %s\n" "$BLUE" "$RESET" "$*"; }
ok() { printf "%b[完成]%b %s\n" "$GREEN" "$RESET" "$*"; }
warn() { printf "%b[警告]%b %s\n" "$YELLOW" "$RESET" "$*" >&2; }
die() { printf "%b[错误]%b %s\n" "$RED" "$RESET" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
用法: $0 [选项]

  --domain DOMAIN       Reality SNI 主域名（Cloudflare 灰云/仅 DNS）
  --decoy DOMAIN        伪装站域名（例如 Cloudflare Worker 橙云域名）
  --email EMAIL         Caddy 申请证书使用的邮箱（默认 admin@主域名）
  --yes                 非交互安装（必须提供主域名和伪装域名）
  --force               允许接管已被占用的 80/443 端口对应服务
  --help                 显示帮助

也可通过 DOMAIN、DECOY_DOMAIN、ACME_EMAIL 环境变量传参。
版本: $SCRIPT_VERSION
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --domain) [ "$#" -ge 2 ] || die "--domain 缺少参数"; DOMAIN=$2; shift 2 ;;
    --decoy) [ "$#" -ge 2 ] || die "--decoy 缺少参数"; DECOY_DOMAIN=$2; shift 2 ;;
    --email) [ "$#" -ge 2 ] || die "--email 缺少参数"; ACME_EMAIL=$2; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --force) FORCE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "未知参数: $1（使用 --help 查看帮助）" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行此脚本"

validate_domain() {
  value=$1
  echo "$value" | grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$' \
    || die "域名格式不正确: $value"
}

validate_email() {
  echo "$1" | grep -Eq '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' \
    || die "邮箱格式不正确: $1"
}

prompt_value() {
  var_name=$1 prompt=$2 current=$3
  if [ -z "$current" ]; then
    [ "$ASSUME_YES" -eq 0 ] || die "非交互模式缺少 $var_name"
    printf "%s: " "$prompt" >&2
    IFS= read -r current
  fi
  case "$var_name" in
    DOMAIN) DOMAIN=$current ;;
    DECOY_DOMAIN) DECOY_DOMAIN=$current ;;
    ACME_EMAIL) ACME_EMAIL=$current ;;
    *) die "内部参数错误: $var_name" ;;
  esac
}

prompt_value DOMAIN "Reality 主域名（灰云/仅 DNS）" "$DOMAIN"
prompt_value DECOY_DOMAIN "伪装站域名（橙云 Worker 或其他 HTTPS 站点）" "$DECOY_DOMAIN"
DOMAIN=$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]')
DECOY_DOMAIN=$(printf '%s' "$DECOY_DOMAIN" | tr '[:upper:]' '[:lower:]')
validate_domain "$DOMAIN"
validate_domain "$DECOY_DOMAIN"
[ "$DOMAIN" != "$DECOY_DOMAIN" ] || die "主域名和伪装站域名不能相同"
ACME_EMAIL=${ACME_EMAIL:-admin@$DOMAIN}
validate_email "$ACME_EMAIL"

OS_ID='' OS_VERSION='' PKG='' INIT=''
[ -r /etc/os-release ] || die "无法识别操作系统"
# shellcheck disable=SC1091
. /etc/os-release
OS_ID=$ID
OS_VERSION=${VERSION_ID:-0}
case "$OS_ID" in
  debian)
    [ "${OS_VERSION%%.*}" -ge 10 ] || die "仅支持 Debian 10+"
    PKG=apt; INIT=systemd
    ;;
  ubuntu)
    major=${OS_VERSION%%.*}
    [ "$major" -ge 20 ] || die "仅支持 Ubuntu 20.04+"
    PKG=apt; INIT=systemd
    ;;
  alpine)
    major=${OS_VERSION%%.*}; minor=${OS_VERSION#*.}; minor=${minor%%.*}
    if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 14 ]; }; then
      die "仅支持 Alpine 3.14+"
    fi
    PKG=apk; INIT=openrc
    ;;
  *) die "不支持的系统: $OS_ID" ;;
esac

command -v ss >/dev/null 2>&1 && PORT_CMD=ss || PORT_CMD=''
port_pids() {
  port=$1
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u || true
  elif [ -n "$PORT_CMD" ]; then
    ss -H -ltnp "sport = :$port" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u || true
  fi
}

port_description() {
  port=$1 pids=$(port_pids "$port")
  [ -n "$pids" ] || return 0
  for pid in $pids; do
    name=$(ps -p "$pid" -o comm= 2>/dev/null || echo unknown)
    printf '%s(pid=%s) ' "$name" "$pid"
  done
}

stop_port_owners() {
  port=$1 pids=$(port_pids "$port")
  [ -n "$pids" ] || return 0
  desc=$(port_description "$port")
  foreign=0
  for pid in $pids; do
    name=$(ps -p "$pid" -o comm= 2>/dev/null || true)
    case "$name" in xray|caddy) ;; *) foreign=1 ;; esac
  done
  if [ "$foreign" -eq 1 ] && [ "$FORCE" -ne 1 ]; then
    die "端口 $port 已被占用: $desc。请先迁移服务，或确认可接管后使用 --force"
  fi
  warn "正在释放端口 $port，当前占用: $desc"
  for pid in $pids; do
    name=$(ps -p "$pid" -o comm= 2>/dev/null || true)
    case "$name" in
      xray) service_stop xray ;;
      caddy) service_stop caddy ;;
      nginx) service_stop nginx ;;
      apache2) service_stop apache2 ;;
      httpd) service_stop httpd ;;
      *) kill "$pid" 2>/dev/null || true ;;
    esac
  done
  sleep 1
  [ -z "$(port_pids "$port")" ] || die "无法释放端口 $port"
}

service_stop() {
  svc=$1
  if [ "$INIT" = systemd ]; then
    systemctl stop "$svc" 2>/dev/null || true
  else
    rc-service "$svc" stop 2>/dev/null || true
  fi
}

install_packages() {
  info "安装基础依赖"
  if [ "$PKG" = apt ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y bash curl ca-certificates unzip openssl jq lsof gnupg debian-keyring debian-archive-keyring apt-transport-https
  else
    apk add --no-cache curl ca-certificates unzip openssl jq lsof libcap
  fi
}

arch_name() {
  case "$(uname -m)" in
    x86_64|amd64) echo 64 ;;
    aarch64|arm64) echo arm64-v8a ;;
    armv7l|armv7) echo arm32-v7a ;;
    s390x) echo s390x ;;
    *) die "Xray 暂不支持此架构: $(uname -m)" ;;
  esac
}

install_xray() {
  info "安装 Xray-core"
  if [ "$INIT" = systemd ]; then
    curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o /tmp/xray-install.sh
    bash /tmp/xray-install.sh install -u root
    rm -f /tmp/xray-install.sh
  else
    arch=$(arch_name)
    release=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest)
    url=$(printf '%s' "$release" | jq -r --arg suffix "linux-$arch.zip" '.assets[] | select(.name | ascii_downcase | endswith($suffix)) | .browser_download_url' | head -n1)
    [ -n "$url" ] && [ "$url" != null ] || die "无法获取 Xray 下载地址"
    rm -rf /tmp/xray-install && mkdir -p /tmp/xray-install
    curl -fL "$url" -o /tmp/xray-install/xray.zip
    unzip -oq /tmp/xray-install/xray.zip -d /tmp/xray-install
    install -m 0755 /tmp/xray-install/xray /usr/local/bin/xray
    mkdir -p /usr/local/share/xray /usr/local/etc/xray /var/log/xray
    [ ! -f /tmp/xray-install/geoip.dat ] || install -m 0644 /tmp/xray-install/geoip.dat /usr/local/share/xray/geoip.dat
    [ ! -f /tmp/xray-install/geosite.dat ] || install -m 0644 /tmp/xray-install/geosite.dat /usr/local/share/xray/geosite.dat
    rm -rf /tmp/xray-install
  fi
}

install_caddy() {
  info "安装 Caddy"
  if [ "$PKG" = apt ]; then
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
      | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
      -o /etc/apt/sources.list.d/caddy-stable.list
    chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    chmod o+r /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
  else
    apk add --no-cache caddy
  fi
}

backup_file() {
  file=$1
  [ -e "$file" ] || return 0
  backup_dir=${BACKUP_DIR:-/var/backups/reality-selfsteal-$(date +%Y%m%d-%H%M%S)}
  BACKUP_DIR=$backup_dir
  mkdir -p "$backup_dir"
  cp -a "$file" "$backup_dir/$(basename "$file")"
}

json_escape() {
  printf '%s' "$1" | jq -Rr @json
}

write_configs() {
  mkdir -p /usr/local/etc/xray /etc/caddy /var/lib/reality-selfsteal
  backup_file /usr/local/etc/xray/config.json
  backup_file /etc/caddy/caddy.json

  UUID=$(/usr/local/bin/xray uuid 2>/dev/null || xray uuid)
  KEY_OUTPUT=$(/usr/local/bin/xray x25519 2>/dev/null || xray x25519)
  PRIVATE_KEY=$(printf '%s\n' "$KEY_OUTPUT" | sed -nE 's/^(Private key|PrivateKey):[[:space:]]*//p' | head -n1)
  PUBLIC_KEY=$(printf '%s\n' "$KEY_OUTPUT" | sed -nE 's/^(Public key|Password|Password \(PublicKey\)):[[:space:]]*//p' | head -n1)
  [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] || die "无法解析 xray x25519 输出"
  SHORT_ID=$(openssl rand -hex 8)

  domain_json=$(json_escape "$DOMAIN")
  decoy_json=$(json_escape "$DECOY_DOMAIN")
  email_json=$(json_escape "$ACME_EMAIL")
  uuid_json=$(json_escape "$UUID")
  private_json=$(json_escape "$PRIVATE_KEY")
  short_json=$(json_escape "$SHORT_ID")

  cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "port": "443", "network": "udp", "outboundTag": "block" },
      { "type": "field", "ip": ["geoip:cn", "geoip:private"], "outboundTag": "block" }
    ]
  },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $XRAY_PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": $uuid_json, "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "127.0.0.1:$CADDY_BACKEND_PORT",
        "xver": 1,
        "serverNames": [$domain_json],
        "privateKey": $private_json,
        "shortIds": [$short_json]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
  }],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "policy": { "levels": { "0": { "handshake": 2, "connIdle": 120 } } }
}
EOF

  cat > /etc/caddy/caddy.json <<EOF
{
  "admin": { "listen": "127.0.0.1:2019" },
  "apps": {
    "http": {
      "servers": {
        "http_redirect": {
          "listen": [":80"],
          "routes": [{
            "match": [{ "host": [$domain_json] }],
            "handle": [{
              "handler": "static_response",
              "headers": { "Location": ["https://{http.request.host}{http.request.uri}"] },
              "status_code": 301
            }]
          }],
          "protocols": ["h1", "h2"]
        },
        "reality_backend": {
          "listen": ["127.0.0.1:$CADDY_BACKEND_PORT"],
          "listener_wrappers": [
            { "wrapper": "proxy_protocol", "allow": ["127.0.0.1/32"] },
            { "wrapper": "tls" }
          ],
          "routes": [{
            "match": [{ "host": [$domain_json] }],
            "handle": [
              {
                "handler": "headers",
                "response": { "set": {
                  "Strict-Transport-Security": ["max-age=31536000; includeSubDomains; preload"]
                } }
              },
              {
                "handler": "reverse_proxy",
                "upstreams": [{ "dial": "$DECOY_DOMAIN:443" }],
                "headers": { "request": { "set": { "Host": [$decoy_json] } } },
                "transport": { "protocol": "http", "tls": { "server_name": $decoy_json } }
              }
            ]
          }],
          "tls_connection_policies": [{
            "match": { "sni": [$domain_json] },
            "alpn": ["h2", "http/1.1"]
          }],
          "protocols": ["h1", "h2"]
        }
      }
    },
    "tls": {
      "certificates": { "automate": [$domain_json] },
      "automation": { "policies": [{
        "subjects": [$domain_json],
        "issuers": [{ "module": "acme", "email": $email_json }]
      }] }
    }
  }
}
EOF
  chmod 600 /usr/local/etc/xray/config.json
  if getent group caddy >/dev/null 2>&1; then
    chown root:caddy /etc/caddy/caddy.json
    chmod 640 /etc/caddy/caddy.json
  else
    chmod 644 /etc/caddy/caddy.json
  fi

  cat > /var/lib/reality-selfsteal/client.env <<EOF
DOMAIN=$DOMAIN
PORT=$XRAY_PORT
UUID=$UUID
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
FLOW=xtls-rprx-vision
FINGERPRINT=chrome
EOF
  chmod 600 /var/lib/reality-selfsteal/client.env
}

write_services() {
  if [ "$INIT" = systemd ]; then
    mkdir -p /etc/systemd/system/caddy.service.d
    cat > /etc/systemd/system/caddy.service.d/reality-json.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/caddy.json
ExecReload=
ExecReload=/usr/bin/caddy reload --config /etc/caddy/caddy.json --force
EOF
    systemctl daemon-reload
  else
    cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run
name="xray"
description="Xray Service"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/run/xray.pid"
output_log="/var/log/xray/access.log"
error_log="/var/log/xray/error.log"
depend() { need net; after firewall; }
EOF
    chmod 755 /etc/init.d/xray
    caddy_bin=$(command -v caddy)
    cat > /etc/init.d/caddy <<EOF
#!/sbin/openrc-run
name="caddy"
description="Caddy web server for Reality fallback"
command="$caddy_bin"
command_args="run --environ --config /etc/caddy/caddy.json"
command_background="yes"
pidfile="/run/caddy.pid"
output_log="/var/log/caddy.log"
error_log="/var/log/caddy.log"
depend() { need net; after firewall; }
EOF
    chmod 755 /etc/init.d/caddy
  fi
}

validate_configs() {
  info "检查配置"
  /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
  caddy validate --config /etc/caddy/caddy.json
}

configure_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    info "放行 UFW 的 80/tcp 和 $XRAY_PORT/tcp"
    ufw allow 80/tcp >/dev/null
    ufw allow "$XRAY_PORT/tcp" >/dev/null
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    info "放行 firewalld 的 80/tcp 和 $XRAY_PORT/tcp"
    firewall-cmd --permanent --add-port=80/tcp >/dev/null
    firewall-cmd --permanent --add-port="$XRAY_PORT/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
  fi
}

start_services() {
  stop_port_owners 80
  stop_port_owners "$XRAY_PORT"
  if [ "$INIT" = systemd ]; then
    systemctl enable xray caddy
    systemctl restart caddy
    systemctl restart xray
    systemctl is-active --quiet caddy || die "Caddy 启动失败，请运行 journalctl -u caddy -n 100 查看日志"
    systemctl is-active --quiet xray || die "Xray 启动失败，请运行 journalctl -u xray -n 100 查看日志"
  else
    rc-update add caddy default >/dev/null
    rc-update add xray default >/dev/null
    rc-service caddy restart
    rc-service xray restart
    rc-service caddy status >/dev/null || die "Caddy 启动失败"
    rc-service xray status >/dev/null || die "Xray 启动失败"
  fi
}

verify_endpoint() {
  info "等待 Caddy 获取证书并检查回落站点"
  attempt=1
  while [ "$attempt" -le 6 ]; do
    if curl -fsS --max-time 8 --resolve "$DOMAIN:$XRAY_PORT:127.0.0.1" \
      "https://$DOMAIN:$XRAY_PORT/" >/dev/null 2>&1; then
      ok "HTTPS 回落站点工作正常"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 5
  done
  warn "暂未通过 HTTPS 回落检查。若 DNS 刚生效，请稍后重试；并检查域名 A/AAAA 记录和云防火墙的 80/443 端口。"
  return 0
}

show_result() {
  # shellcheck disable=SC1091
  . /var/lib/reality-selfsteal/client.env
  uri="vless://${UUID}@${DOMAIN}:${PORT}?encryption=none&flow=${FLOW}&security=reality&sni=${DOMAIN}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Reality-${DOMAIN}"
  printf '\n%b安装完成%b\n' "$GREEN" "$RESET"
  printf '%s\n' "----------------------------------------"
  printf '地址:       %s\n' "$DOMAIN"
  printf '端口:       %s\n' "$PORT"
  printf 'UUID:       %s\n' "$UUID"
  printf 'Flow:       %s\n' "$FLOW"
  printf 'SNI:        %s\n' "$DOMAIN"
  printf '公钥 pbk:   %s\n' "$PUBLIC_KEY"
  printf 'Short ID:   %s\n' "$SHORT_ID"
  printf '指纹 fp:    %s\n' "$FINGERPRINT"
  printf '传输:       tcp\n'
  printf '%s\n' "----------------------------------------"
  printf '分享链接:\n%s\n' "$uri"
  printf '\n配置保存于: /var/lib/reality-selfsteal/client.env\n'
  [ -z "${BACKUP_DIR:-}" ] || printf '原配置备份: %s\n' "$BACKUP_DIR"
  printf '\n请确认：%s 为 Cloudflare 灰云（仅 DNS），且 A/AAAA 记录指向本机。\n' "$DOMAIN"
  printf '伪装域名 %s 必须能通过 HTTPS 正常访问。\n' "$DECOY_DOMAIN"
}

info "系统: $OS_ID $OS_VERSION；初始化系统: $INIT"
warn "此方案将由 Caddy 使用 80 端口、Xray 独占 TCP $XRAY_PORT 端口。"
if [ "$ASSUME_YES" -eq 0 ]; then
  printf "继续安装？[y/N]: " >&2
  IFS= read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) die "用户取消" ;; esac
fi

install_packages
stop_port_owners 80
stop_port_owners "$XRAY_PORT"
install_xray
install_caddy
write_configs
write_services
validate_configs
configure_firewall
start_services
verify_endpoint
show_result
