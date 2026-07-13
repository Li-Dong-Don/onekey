#!/usr/bin/env bash
# ================================================================
# VLESS + XTLS-Reality "偷自己" 一键安装脚本
# ----------------------------------------------------------------
# 功能概览：
# · 全自动安装 Xray-core + Reality 协议，独占 443 端口
# · 自动申请 TLS 证书（acme.sh + Let's Encrypt）
# · 自动修复证书续签（standalone 模式 pre/post hook）
# · 自动部署个人网盘登录页伪装页面
# · 80 端口 HTTP→HTTPS 跳转 + default_server 444 兜底保护
# · 自动识别并迁移现有网站端口（443→8443），卸载时自动还原
# · 检测面板 nginx 时跳过系统 nginx 安装，避免端口冲突
# · 菜单同步：双向对比新增/删除网站，自动同步 8443 监听
# · 卸载前确认提示，卸载后自动还原所有仍存在的网站配置
# ----------------------------------------------------------------
# 兼容系统：Debian 10+ / Ubuntu 20.04+ / Alpine 3.14+
# 兼容面板：宝塔 / 1Panel / 无面板
# 兼容建站：nginx / Apache / LAMP / LEMP / Docker 反代 / 手动部署
# 兼容服务：systemd / OpenRC
# ----------------------------------------------------------------
# 菜单选项：
# 1) 全新安装 2) 重新生成密钥 3) 查看凭据
# 4) 同步现有网站 5) 卸载并还原网站设置
# ================================================================

set -Eeuo pipefail
umask 077

readonly SCRIPT_VERSION="1.0.0"
readonly STATE_DIR="/etc/xray-selfsteal"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly MANIFEST="${STATE_DIR}/managed-files.tsv"
readonly SITE_INDEX="${STATE_DIR}/active-sites.list"
readonly XRAY_CONFIG="${STATE_DIR}/xray-config.json"
readonly XRAY_BIN="/usr/local/lib/xray-selfsteal/xray"
readonly CREDENTIALS="${STATE_DIR}/credentials.txt"
readonly CERT_DIR="${STATE_DIR}/certs"
readonly TXN_DIR="${STATE_DIR}/transaction"
readonly WEBROOT="/var/www/xray-selfsteal"
readonly ACME_HOME="/root/.acme.sh"

OS_ID=""; INIT_SYSTEM=""; WEB_KIND=""; PANEL="none"
WEB_BIN=""; WEB_CONF_DIR=""; WEB_SERVICE=""; WEB_CONTAINER=""; SELF_WEB_CONF=""
DOMAIN=""; EMAIL=""; UUID=""; PRIVATE_KEY=""; PUBLIC_KEY=""; SHORT_ID=""
PUBLIC_IP=""; INSTALLED_AT=""
ROLLBACK_NEEDED=0
INSTALL_IN_PROGRESS=0

if [[ -t 1 ]]; then
  C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_BLUE='\033[36m'; C_RESET='\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_RESET=''
fi

log()  { printf '%b[信息]%b %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%b[成功]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%b[警告]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%b[错误]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

on_error() {
  local line="$1" code="$2"
  printf '%b[错误]%b 第 %s 行执行失败（退出码 %s）。\n' "$C_RED" "$C_RESET" "$line" "$code" >&2
  if (( ROLLBACK_NEEDED )); then
    warn "正在回滚本次网站配置变更……"
    rollback_transaction || true
    if web_config_test >/dev/null 2>&1; then web_reload || true; fi
  fi
  if (( INSTALL_IN_PROGRESS )); then
    remove_xray_service >/dev/null 2>&1 || true
    rm -f "$STATE_FILE" "$XRAY_CONFIG" "$CREDENTIALS"
  fi
}
trap 'on_error "$LINENO" "$?"' ERR

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：sudo bash $0"
}

has() { command -v "$1" >/dev/null 2>&1; }

detect_os() {
  [[ -r /etc/os-release ]] || die "无法识别操作系统。"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  case "$OS_ID" in
    debian|ubuntu) ;;
    alpine) ;;
    *) die "仅支持 Debian、Ubuntu、Alpine；当前为 ${OS_ID}。" ;;
  esac
  if has systemctl && [[ -d /run/systemd/system ]]; then
    INIT_SYSTEM="systemd"
  elif has rc-service; then
    INIT_SYSTEM="openrc"
  else
    die "未检测到 systemd 或 OpenRC。"
  fi
}

install_packages() {
  log "安装基础依赖……"
  if [[ "$OS_ID" == "alpine" ]]; then
    apk add --no-cache bash curl ca-certificates openssl unzip socat jq coreutils findutils grep sed iproute2
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends bash curl ca-certificates openssl unzip socat jq iproute2
  fi
}

validate_domain() {
  local d="$1"
  [[ ${#d} -le 253 ]] || return 1
  [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

prompt_install_info() {
  local input=""
  while :; do
    read -r -p "请输入 Reality/伪装站点域名（已解析到本机）：" input
    input="${input,,}"
    validate_domain "$input" && break
    warn "域名格式不正确，请输入类似 cloud.example.com 的完整域名。"
  done
  DOMAIN="$input"
  read -r -p "Let's Encrypt 邮箱（可留空）：" EMAIL
  if [[ -n "$EMAIL" && ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    die "邮箱格式不正确。"
  fi
}

detect_public_ip() {
  PUBLIC_IP="$(curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    PUBLIC_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
  [[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="请填写服务器IP"
}

check_dns() {
  local resolved=""
  if has getent; then
    resolved="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)"
  fi
  if [[ -n "$resolved" && "$PUBLIC_IP" != "请填写服务器IP" && "$resolved" != "$PUBLIC_IP" ]]; then
    warn "${DOMAIN} 当前解析为 ${resolved}，本机公网 IP 为 ${PUBLIC_IP}。"
    read -r -p "仍要继续吗？[y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || die "已取消。请先修正 DNS。"
  fi
}

port_listeners() {
  local port="$1"
  ss -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print}' || true
}

check_docker_443() {
  has docker || return 0
  local hits
  hits="$(docker ps --format '{{.ID}}\t{{.Names}}\t{{.Ports}}' 2>/dev/null | grep -E '(^|[,:])([0-9.]*:)?443->' || true)"
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" >&2
    die "检测到 Docker 容器直接发布宿主机 443。自动重建容器风险过高；请先把该映射改为 8443，再重新运行。"
  fi
}

apache_is_active() {
  (has apache2 || has httpd) || return 1
  { port_listeners 80; port_listeners 443; } | grep -Eqi 'apache2|httpd'
}

ensure_camouflage_domain_unused() {
  local escaped file
  escaped="${DOMAIN//./\\.}"
  if [[ "$WEB_KIND" == "nginx" ]]; then
    while IFS= read -r file; do
      [[ "$file" == "$SELF_WEB_CONF" || ! -f "$file" ]] && continue
      if grep -Eq "^[[:space:]]*server_name[[:space:]][^;]*([[:space:]]|^)${escaped}([[:space:];]|$)" "$file"; then
        die "域名 ${DOMAIN} 已存在于网站配置 ${file}。请使用一个未建站的独立子域名，以免 SNI 冲突。"
      fi
    done < <(active_nginx_files)
  else
    while IFS= read -r file; do
      [[ "$file" == "$SELF_WEB_CONF" || ! -f "$file" ]] && continue
      if grep -Eiq "^[[:space:]]*Server(Name|Alias)[[:space:]].*([[:space:]]|^)${escaped}([[:space:]]|$)" "$file"; then
        die "域名 ${DOMAIN} 已存在于网站配置 ${file}。请使用一个未建站的独立子域名。"
      fi
    done < <(active_apache_files)
  fi
}

detect_web_stack() {
  PANEL="none"; WEB_KIND=""; WEB_BIN=""; WEB_CONF_DIR=""; WEB_SERVICE=""; WEB_CONTAINER=""; SELF_WEB_CONF=""

  if [[ -x /www/server/nginx/sbin/nginx ]]; then
    PANEL="bt"; WEB_KIND="nginx"; WEB_BIN="/www/server/nginx/sbin/nginx"
    WEB_CONF_DIR="/www/server/panel/vhost/nginx"; WEB_SERVICE="nginx"
  else
    local onepanel_nginx=""
    onepanel_nginx="$(find /opt/1panel/apps/openresty -type f -path '*/sbin/nginx' -perm -111 2>/dev/null | head -n1 || true)"
    if [[ -n "$onepanel_nginx" ]]; then
      PANEL="1panel"; WEB_KIND="nginx"; WEB_BIN="$onepanel_nginx"
      WEB_CONF_DIR="$(dirname "$(dirname "$onepanel_nginx")")/conf/conf.d"
      [[ -d "$WEB_CONF_DIR" ]] || WEB_CONF_DIR="/opt/1panel/apps/openresty/openresty/conf/conf.d"
      WEB_SERVICE="openresty"
      if has docker; then
        WEB_CONTAINER="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -Ei '1panel.*openresty|openresty.*1panel' | head -n1 || true)"
      fi
    elif has nginx && ! apache_is_active; then
      WEB_KIND="nginx"; WEB_BIN="$(command -v nginx)"; WEB_CONF_DIR="/etc/nginx/conf.d"; WEB_SERVICE="nginx"
    elif has apache2 || has httpd; then
      WEB_KIND="apache"
      WEB_BIN="$(command -v apache2ctl || command -v apachectl || command -v httpd)"
      if [[ "$OS_ID" == "alpine" ]]; then
        WEB_CONF_DIR="/etc/apache2/conf.d"; WEB_SERVICE="apache2"
      else
        WEB_CONF_DIR="/etc/apache2/sites-available"; WEB_SERVICE="apache2"
      fi
    fi
  fi

  if [[ -z "$WEB_KIND" ]]; then
    log "未发现 Web 服务，安装系统 nginx……"
    if [[ "$OS_ID" == "alpine" ]]; then
      apk add --no-cache nginx
      rc-update add nginx default >/dev/null 2>&1 || true
    else
      apt-get install -y --no-install-recommends nginx
      systemctl enable nginx >/dev/null 2>&1 || true
    fi
    WEB_KIND="nginx"; WEB_BIN="$(command -v nginx)"; WEB_CONF_DIR="/etc/nginx/conf.d"; WEB_SERVICE="nginx"
  fi

  mkdir -p "$WEB_CONF_DIR"
  if [[ "$WEB_KIND" == "nginx" ]]; then
    SELF_WEB_CONF="${WEB_CONF_DIR}/00-xray-selfsteal.conf"
  elif [[ "$OS_ID" == "alpine" ]]; then
    SELF_WEB_CONF="${WEB_CONF_DIR}/00-xray-selfsteal.conf"
  else
    SELF_WEB_CONF="${WEB_CONF_DIR}/00-xray-selfsteal.conf"
  fi
  log "Web 环境：${WEB_KIND}（面板：${PANEL}，程序：${WEB_BIN}）"
}

service_stop() {
  local svc="$1"
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    systemctl stop "$svc" >/dev/null 2>&1 || true
  else
    rc-service "$svc" stop >/dev/null 2>&1 || true
  fi
}

service_start() {
  local svc="$1"
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    systemctl start "$svc" >/dev/null 2>&1 || true
  else
    rc-service "$svc" start >/dev/null 2>&1 || true
  fi
}

web_stop() {
  if [[ -n "$WEB_CONTAINER" ]] && has docker; then
    docker stop "$WEB_CONTAINER" >/dev/null 2>&1 || true
  elif [[ "$PANEL" == "bt" && -x /etc/init.d/nginx ]]; then
    /etc/init.d/nginx stop >/dev/null 2>&1 || true
  else
    service_stop "$WEB_SERVICE"
  fi
}

web_start() {
  if [[ -n "$WEB_CONTAINER" ]] && has docker; then
    docker start "$WEB_CONTAINER" >/dev/null
  elif [[ "$PANEL" == "bt" && -x /etc/init.d/nginx ]]; then
    /etc/init.d/nginx start >/dev/null
  else
    service_start "$WEB_SERVICE"
  fi
}

web_config_test() {
  [[ -n "$WEB_BIN" ]] || return 0
  if [[ -n "$WEB_CONTAINER" ]] && has docker; then
    docker exec "$WEB_CONTAINER" nginx -t
  elif [[ "$WEB_KIND" == "nginx" ]]; then
    "$WEB_BIN" -t
  else
    "$WEB_BIN" configtest
  fi
}

web_reload() {
  if [[ -n "$WEB_CONTAINER" ]] && has docker; then
    docker exec "$WEB_CONTAINER" nginx -t >/dev/null
    docker exec "$WEB_CONTAINER" nginx -s reload
  elif [[ "$PANEL" == "bt" ]]; then
    "$WEB_BIN" -t >/dev/null
    "$WEB_BIN" -s reload
  elif [[ "$INIT_SYSTEM" == "systemd" ]] && systemctl cat "${WEB_SERVICE}.service" >/dev/null 2>&1; then
    systemctl reload "$WEB_SERVICE" >/dev/null 2>&1 || systemctl restart "$WEB_SERVICE"
  elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-service "$WEB_SERVICE" reload >/dev/null 2>&1 || rc-service "$WEB_SERVICE" restart
  elif [[ "$WEB_KIND" == "nginx" ]]; then
    "$WEB_BIN" -s reload
  fi
}

write_acme_hooks() {
  mkdir -p "$STATE_DIR"
  local stop_cmd start_cmd
  if [[ -n "$WEB_CONTAINER" ]]; then
    stop_cmd="docker stop ${WEB_CONTAINER} 2>/dev/null || true"
    start_cmd="docker start ${WEB_CONTAINER} 2>/dev/null || true"
  elif [[ "$PANEL" == "bt" && -x /etc/init.d/nginx ]]; then
    stop_cmd="/etc/init.d/nginx stop 2>/dev/null || true"
    start_cmd="/etc/init.d/nginx start 2>/dev/null || true"
  else
    stop_cmd="if command -v systemctl >/dev/null 2>&1; then systemctl stop ${WEB_SERVICE} 2>/dev/null || true; else rc-service ${WEB_SERVICE} stop 2>/dev/null || true; fi"
    start_cmd="if command -v systemctl >/dev/null 2>&1; then systemctl start ${WEB_SERVICE} 2>/dev/null || true; else rc-service ${WEB_SERVICE} start 2>/dev/null || true; fi"
  fi
  cat >"${STATE_DIR}/acme-pre.sh" <<EOF
#!/usr/bin/env sh
if command -v systemctl >/dev/null 2>&1; then
  systemctl stop xray-selfsteal 2>/dev/null || true
else
  rc-service xray-selfsteal stop 2>/dev/null || true
fi
${stop_cmd}
EOF
  cat >"${STATE_DIR}/acme-post.sh" <<EOF
#!/usr/bin/env sh
${start_cmd}
if command -v systemctl >/dev/null 2>&1; then
  systemctl start xray-selfsteal 2>/dev/null || true
else
  rc-service xray-selfsteal start 2>/dev/null || true
fi
EOF
  chmod 700 "${STATE_DIR}/acme-pre.sh" "${STATE_DIR}/acme-post.sh"
}

install_acme_and_issue_cert() {
  mkdir -p "$CERT_DIR"
  write_acme_hooks
  if [[ ! -x "${ACME_HOME}/acme.sh" ]]; then
    log "安装 acme.sh……"
    if [[ -n "$EMAIL" ]]; then
      curl -fsSL https://get.acme.sh | sh -s email="$EMAIL"
    else
      curl -fsSL https://get.acme.sh | sh
    fi
  fi

  log "使用 Let's Encrypt standalone 模式申请证书……"
  service_stop xray-selfsteal
  web_stop
  local issue_args=(--issue --standalone --server letsencrypt -d "$DOMAIN" --keylength ec-256 --force
    --pre-hook "${STATE_DIR}/acme-pre.sh" --post-hook "${STATE_DIR}/acme-post.sh")
  if ! "${ACME_HOME}/acme.sh" "${issue_args[@]}"; then
    web_start
    die "证书申请失败。请确认域名解析正确，且公网 80 端口可访问。"
  fi
  "${ACME_HOME}/acme.sh" --install-cert -d "$DOMAIN" --ecc \
    --key-file "${CERT_DIR}/site.key" \
    --fullchain-file "${CERT_DIR}/fullchain.pem" \
    --reloadcmd "${STATE_DIR}/acme-post.sh"
  chmod 600 "${CERT_DIR}/site.key" "${CERT_DIR}/fullchain.pem"
}

backup_file() {
  local file="$1" id backup
  [[ -f "$file" ]] || return 0
  mkdir -p "$BACKUP_DIR"
  touch "$MANIFEST"
  if awk -F '\t' -v f="$file" '$1==f{found=1} END{exit !found}' "$MANIFEST" 2>/dev/null; then
    return 0
  fi
  id="$(printf '%s' "$file" | sha256sum | awk '{print $1}')"
  backup="${BACKUP_DIR}/${id}"
  cp -a "$file" "$backup"
  printf '%s\t%s\n' "$file" "$backup" >>"$MANIFEST"
}

begin_transaction() {
  rm -rf "$TXN_DIR"
  mkdir -p "${TXN_DIR}/files"
  : >"${TXN_DIR}/manifest.tsv"
}

transaction_snapshot() {
  local file="$1" id snapshot
  [[ -f "${TXN_DIR}/manifest.tsv" ]] || return 0
  if awk -F '\t' -v f="$file" '$1==f{found=1} END{exit !found}' "${TXN_DIR}/manifest.tsv"; then
    return 0
  fi
  if [[ ! -e "$file" ]]; then
    printf '%s\t%s\n' "$file" "__ABSENT__" >>"${TXN_DIR}/manifest.tsv"
    return 0
  fi
  id="$(printf '%s' "$file" | sha256sum | awk '{print $1}')"
  snapshot="${TXN_DIR}/files/${id}"
  cp -a "$file" "$snapshot"
  printf '%s\t%s\n' "$file" "$snapshot" >>"${TXN_DIR}/manifest.tsv"
}

rollback_transaction() {
  [[ -f "${TXN_DIR}/manifest.tsv" ]] || return 0
  while IFS=$'\t' read -r file snapshot; do
    [[ -n "$file" ]] || continue
    if [[ "$snapshot" == "__ABSENT__" ]]; then
      rm -f "$file"
    elif [[ -f "$snapshot" ]]; then
      mkdir -p "$(dirname "$file")"
      cp -a "$snapshot" "$file"
    fi
  done <"${TXN_DIR}/manifest.tsv"
  rm -rf "$TXN_DIR"
}

commit_transaction() { rm -rf "$TXN_DIR"; }

restore_managed_files() {
  [[ -f "$MANIFEST" ]] || return 0
  while IFS=$'\t' read -r file backup; do
    [[ -n "$file" && -e "$file" && -f "$backup" ]] || continue
    cp -a "$backup" "$file"
  done <"$MANIFEST"
}

active_nginx_files() {
  "$WEB_BIN" -T 2>&1 | sed -n 's/^# configuration file \(.*\):$/\1/p' | sort -u
}

active_apache_files() {
  local roots=()
  [[ -d /etc/apache2 ]] && roots+=(/etc/apache2)
  [[ -d /etc/httpd ]] && roots+=(/etc/httpd)
  ((${#roots[@]})) || return 0
  find "${roots[@]}" -type f \( -name '*.conf' -o -name 'httpd.conf' \) 2>/dev/null
}

current_site_files() {
  local file resolved
  if [[ "$WEB_KIND" == "nginx" ]]; then
    while IFS= read -r file; do
      [[ -f "$file" && "$file" != "$SELF_WEB_CONF" ]] || continue
      grep -Eq '^[[:space:]]*server_name[[:space:]]+' "$file" || continue
      resolved="$(readlink -f "$file")"
      printf '%s\n' "$resolved"
    done < <(active_nginx_files)
  else
    while IFS= read -r file; do
      [[ -f "$file" && "$file" != "$SELF_WEB_CONF" ]] || continue
      grep -Eiq '^[[:space:]]*Server(Name|Alias)[[:space:]]+' "$file" || continue
      resolved="$(readlink -f "$file")"
      printf '%s\n' "$resolved"
    done < <(active_apache_files)
  fi | sort -u
}

migrate_nginx_file() {
  local file
  file="$(readlink -f "$1")"
  [[ "$file" == "$SELF_WEB_CONF" || ! -f "$file" ]] && return 0
  grep -Eq '^[[:space:]]*listen[[:space:]]+.*(443|8443|default_server)' "$file" || return 0
  backup_file "$file"
  transaction_snapshot "$file"
  sed -E -i \
    -e '/^[[:space:]]*listen[[:space:]]+/ s/:443([[:space:];])/:8443\1/' \
    -e '/^[[:space:]]*listen[[:space:]]+443([[:space:];]|$)/ s/listen([[:space:]]+)443/listen\18443/' \
    -e '/^[[:space:]]*listen[[:space:]]+/ s/[[:space:]]+default_server//g' \
    "$file"
  sed -E -i '/^[[:space:]]*listen[[:space:]]+.*8443/ {/proxy_protocol/! s/;/ proxy_protocol;/}' "$file"
  log "已同步 nginx 配置：${file}（443 → 8443，启用 PROXY protocol）"
}

migrate_apache_file() {
  local file
  file="$(readlink -f "$1")"
  [[ "$file" == "$SELF_WEB_CONF" || ! -f "$file" ]] && return 0
  grep -Eq '(^[[:space:]]*Listen[[:space:]]+([^:[:space:]]+:)?443([[:space:]]|$)|<VirtualHost[^>]*:443[[:space:]]*>)' "$file" || return 0
  backup_file "$file"
  transaction_snapshot "$file"
  sed -E -i \
    -e '/^[[:space:]]*Listen[[:space:]]+/ s/([:[:space:]])443([[:space:]]*)$/\18443\2/' \
    -e '/<VirtualHost[^>]*:443[[:space:]]*>/ s/:443([[:space:]]*>)/:8443\1/g' \
    "$file"
  log "已迁移 Apache 配置：${file}（443 → 8443）"
}

sync_websites() {
  local before after added removed
  load_state
  detect_web_stack
  before="$(mktemp)"; after="$(mktemp)"
  if [[ -f "$SITE_INDEX" ]]; then cp -a "$SITE_INDEX" "$before"; else : >"$before"; fi
  begin_transaction; ROLLBACK_NEEDED=1
  if [[ "$WEB_KIND" == "nginx" ]]; then
    while IFS= read -r file; do migrate_nginx_file "$file"; done < <(active_nginx_files)
  else
    while IFS= read -r file; do migrate_apache_file "$file"; done < <(active_apache_files)
  fi
  web_config_test
  web_reload
  current_site_files >"$after"
  added="$(comm -13 "$before" "$after" || true)"
  removed="$(comm -23 "$before" "$after" || true)"
  cp -a "$after" "$SITE_INDEX"
  [[ -z "$added" ]] || printf '%s\n' "新增网站配置：" "$added"
  [[ -z "$removed" ]] || printf '%s\n' "已删除/停用网站配置：" "$removed"
  rm -f "$before" "$after"
  commit_transaction; ROLLBACK_NEEDED=0
  ok "网站同步完成。新增的 443 监听已迁移到 8443；已删除的网站无需额外转发表清理。"
}

write_disguise_page() {
  mkdir -p "$WEBROOT"
  cat >"${WEBROOT}/index.html" <<'HTML'
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <title>私人云盘</title>
  <style>
  </style>
</head>
<body><main class="wrap"><section class="card"><div class="logo">☁</div><h1 class="title">私人云盘</h1><p class="sub">安全访问您的文件</p><form onsubmit="event.preventDefault();document.getElementById('msg').textContent='用户名或密码错误';"><label class="field">账号<input autocomplete="username" required></label><label class="field">密码<input type="password" autocomplete="current-password" required></label><button class="btn">登录</button><p id="msg" class="tip">您的连接已受到加密保护</p></form></section></main></body>
</html>
HTML
  chmod -R a+rX "$WEBROOT"
}

write_nginx_site() {
  transaction_snapshot "$SELF_WEB_CONF"
  cat >"$SELF_WEB_CONF" <<EOF
# Managed by xray-selfsteal. Do not edit by hand.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 8443 ssl proxy_protocol default_server;
    listen [::]:8443 ssl proxy_protocol default_server;
    server_name _;
    ssl_certificate ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/site.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;
    real_ip_header proxy_protocol;
    return 444;
}
server {
    listen 8443 ssl proxy_protocol;
    listen [::]:8443 ssl proxy_protocol;
    server_name ${DOMAIN};
    ssl_certificate ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/site.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;
    real_ip_header proxy_protocol;
    root ${WEBROOT};
    index index.html;
    location / { try_files \$uri \$uri/ /index.html; }
    location ~ /\\. { deny all; }
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy no-referrer always;
}
EOF
}

write_apache_site() {
  local listen_line=""
  if ! grep -RqsE '^[[:space:]]*Listen[[:space:]]+([^:[:space:]]+:)?8443([[:space:]]|$)' /etc/apache2 /etc/httpd 2>/dev/null; then
    listen_line="Listen 8443"
  fi
  transaction_snapshot "$SELF_WEB_CONF"
  cat >"$SELF_WEB_CONF" <<EOF
# Managed by xray-selfsteal. Apache does not support nginx's non-standard 444 code;
# unmatched hosts receive 404 instead.
${listen_line}
<VirtualHost *:80>
    ServerName ${DOMAIN}
    Redirect permanent / https://${DOMAIN}/
</VirtualHost>
<VirtualHost *:8443>
    ServerName ${DOMAIN}
    DocumentRoot ${WEBROOT}
    SSLEngine on
    SSLCertificateFile ${CERT_DIR}/fullchain.pem
    SSLCertificateKeyFile ${CERT_DIR}/site.key
    <Directory ${WEBROOT}>
        Require all granted
        Options -Indexes
    </Directory>
</VirtualHost>
EOF
  if [[ "$OS_ID" != "alpine" ]] && has a2enmod; then
    a2enmod ssl >/dev/null
    a2ensite "$(basename "$SELF_WEB_CONF")" >/dev/null
  fi
}

configure_web() {
  write_disguise_page
  begin_transaction; ROLLBACK_NEEDED=1
  if [[ "$WEB_KIND" == "nginx" ]]; then
    while IFS= read -r file; do migrate_nginx_file "$file"; done < <(active_nginx_files)
    write_nginx_site
  else
    while IFS= read -r file; do migrate_apache_file "$file"; done < <(active_apache_files)
    write_apache_site
  fi
  web_config_test
  web_start
  web_reload
}

xray_asset_name() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "Xray-linux-64.zip" ;;
    aarch64|arm64) echo "Xray-linux-arm64-v8a.zip" ;;
    armv7l) echo "Xray-linux-arm32-v7a.zip" ;;
    s390x) echo "Xray-linux-s390x.zip" ;;
    *) die "Xray 暂不支持当前架构：${arch}" ;;
  esac
}

install_xray_binary() {
  local asset tmp expected actual
  asset="$(xray_asset_name)"; tmp="$(mktemp -d)"
  log "下载最新版 Xray-core（${asset}）……"
  curl -fL --retry 3 -o "${tmp}/xray.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/${asset}"
  curl -fL --retry 3 -o "${tmp}/xray.zip.dgst" "https://github.com/XTLS/Xray-core/releases/latest/download/${asset}.dgst"
  expected="$(grep -Eio '[a-f0-9]{64}' "${tmp}/xray.zip.dgst" | head -n1)"
  actual="$(sha256sum "${tmp}/xray.zip" | awk '{print $1}')"
  [[ -n "$expected" && "$expected" == "$actual" ]] || die "Xray 下载文件校验失败。"
  unzip -oq "${tmp}/xray.zip" xray -d "$tmp"
  mkdir -p "$(dirname "$XRAY_BIN")"
  install -m 0755 "${tmp}/xray" "$XRAY_BIN"
  rm -rf "$tmp"
}

generate_keys() {
  local output
  UUID="$("$XRAY_BIN" uuid)"
  output="$("$XRAY_BIN" x25519)"
  PRIVATE_KEY="$(printf '%s\n' "$output" | awk -F': *' '/PrivateKey/{print $2; exit}')"
  PUBLIC_KEY="$(printf '%s\n' "$output" | awk -F': *' '/PublicKey|Password/{print $2; exit}')"
  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    PRIVATE_KEY="$(printf '%s\n' "$output" | awk 'NF{print $NF; exit}')"
    PUBLIC_KEY="$(printf '%s\n' "$output" | awk 'NF{v=$NF} END{print v}')"
  fi
  SHORT_ID="$(openssl rand -hex 8)"
  [[ -n "$UUID" && -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "生成 Reality 密钥失败。"
}

write_xray_config() {
  mkdir -p "$STATE_DIR"
  local xver=0
  [[ "$WEB_KIND" == "nginx" ]] && xver=1
  jq -n \
    --arg uuid "$UUID" --arg domain "$DOMAIN" --arg private "$PRIVATE_KEY" --arg sid "$SHORT_ID" --argjson xver "$xver" \
    '{log:{loglevel:"warning"},inbounds:[{listen:"0.0.0.0",port:443,protocol:"vless",settings:{clients:[{id:$uuid,flow:"xtls-rprx-vision"}],decryption:"none"},streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,target:"127.0.0.1:8443",xver:$xver,serverNames:[$domain],privateKey:$private,shortIds:[$sid]}},sniffing:{enabled:true,destOverride:["http","tls","quic"]}}],outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"blocked"}],policy:{levels:{"0":{handshake:2,connIdle:120}}}}' \
    >"$XRAY_CONFIG"
  chmod 600 "$XRAY_CONFIG"
  "$XRAY_BIN" run -test -config "$XRAY_CONFIG"
}

write_xray_service() {
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    cat >/etc/systemd/system/xray-selfsteal.service <<EOF
[Unit]
Description=Xray VLESS Reality Self-Steal
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target ${WEB_SERVICE}.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=${STATE_DIR}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xray-selfsteal >/dev/null
  else
    cat >/etc/init.d/xray-selfsteal <<EOF
#!/sbin/openrc-run
name="xray-selfsteal"
command="${XRAY_BIN}"
command_args="run -config ${XRAY_CONFIG}"
command_background="yes"
pidfile="/run/xray-selfsteal.pid"
output_log="/var/log/xray-selfsteal.log"
error_log="/var/log/xray-selfsteal.err"
depend() { need net; after ${WEB_SERVICE}; }
EOF
    chmod 755 /etc/init.d/xray-selfsteal
    rc-update add xray-selfsteal default >/dev/null 2>&1 || true
  fi
}

start_xray() {
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    systemctl restart xray-selfsteal
    systemctl is-active --quiet xray-selfsteal
  else
    rc-service xray-selfsteal restart
    rc-service xray-selfsteal status >/dev/null
  fi
}

save_state() {
  INSTALLED_AT="${INSTALLED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  {
    printf 'SCRIPT_VERSION=%q\n' "$SCRIPT_VERSION"
    printf 'DOMAIN=%q\n' "$DOMAIN"
    printf 'EMAIL=%q\n' "$EMAIL"
    printf 'UUID=%q\n' "$UUID"
    printf 'PRIVATE_KEY=%q\n' "$PRIVATE_KEY"
    printf 'PUBLIC_KEY=%q\n' "$PUBLIC_KEY"
    printf 'SHORT_ID=%q\n' "$SHORT_ID"
    printf 'PUBLIC_IP=%q\n' "$PUBLIC_IP"
    printf 'OS_ID=%q\n' "$OS_ID"
    printf 'INIT_SYSTEM=%q\n' "$INIT_SYSTEM"
    printf 'WEB_KIND=%q\n' "$WEB_KIND"
    printf 'WEB_BIN=%q\n' "$WEB_BIN"
    printf 'WEB_CONF_DIR=%q\n' "$WEB_CONF_DIR"
    printf 'WEB_SERVICE=%q\n' "$WEB_SERVICE"
    printf 'WEB_CONTAINER=%q\n' "$WEB_CONTAINER"
    printf 'SELF_WEB_CONF=%q\n' "$SELF_WEB_CONF"
    printf 'PANEL=%q\n' "$PANEL"
    printf 'INSTALLED_AT=%q\n' "$INSTALLED_AT"
  } >"$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "尚未安装，找不到 ${STATE_FILE}。"
  # shellcheck disable=SC1090
  . "$STATE_FILE"
}

write_credentials() {
  local name uri
  name="Reality-${DOMAIN}"
  uri="vless://${UUID}@${PUBLIC_IP}:443?encryption=none&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=%2F&type=tcp&flow=xtls-rprx-vision#${name}"
  cat >"$CREDENTIALS" <<EOF
VLESS + XTLS-Reality 客户端凭据
================================
地址：${PUBLIC_IP}
端口：443
UUID：${UUID}
传输：TCP
流控：xtls-rprx-vision
安全：Reality
SNI：${DOMAIN}
Fingerprint：chrome
Public Key：${PUBLIC_KEY}
Short ID：${SHORT_ID}

分享链接：
${uri}
EOF
  chmod 600 "$CREDENTIALS"
}

show_credentials() {
  load_state
  [[ -f "$CREDENTIALS" ]] || write_credentials
  printf '\n'; cat "$CREDENTIALS"; printf '\n'
}

install_all() {
  [[ ! -f "$STATE_FILE" ]] || die "已经安装。请从菜单选择其他操作，或先卸载。"
  detect_os
  install_packages
  prompt_install_info
  detect_public_ip
  check_dns
  check_docker_443
  detect_web_stack
  ensure_camouflage_domain_unused
  mkdir -p "$STATE_DIR" "$BACKUP_DIR" "$CERT_DIR"
  install_acme_and_issue_cert
  INSTALL_IN_PROGRESS=1
  configure_web
  install_xray_binary
  generate_keys
  write_xray_config
  write_xray_service
  start_xray
  save_state
  write_credentials
  current_site_files >"$SITE_INDEX"
  commit_transaction; ROLLBACK_NEEDED=0; INSTALL_IN_PROGRESS=0
  sleep 1
  port_listeners 443 | grep -q xray || warn "未能在端口检查结果中确认 xray，请查看服务日志。"
  ok "安装完成。"
  show_credentials
}

rotate_keys() {
  load_state
  [[ -x "$XRAY_BIN" ]] || die "Xray 程序不存在。"
  cp -a "$XRAY_CONFIG" "${XRAY_CONFIG}.before-rotate"
  cp -a "$STATE_FILE" "${STATE_FILE}.before-rotate"
  [[ -f "$CREDENTIALS" ]] && cp -a "$CREDENTIALS" "${CREDENTIALS}.before-rotate"
  generate_keys
  write_xray_config
  save_state
  write_credentials
  if ! start_xray; then
    cp -a "${XRAY_CONFIG}.before-rotate" "$XRAY_CONFIG"
    cp -a "${STATE_FILE}.before-rotate" "$STATE_FILE"
    [[ -f "${CREDENTIALS}.before-rotate" ]] && cp -a "${CREDENTIALS}.before-rotate" "$CREDENTIALS"
    start_xray || true
    die "新密钥启动失败，已恢复旧配置。"
  fi
  rm -f "${XRAY_CONFIG}.before-rotate" "${STATE_FILE}.before-rotate" "${CREDENTIALS}.before-rotate"
  ok "UUID、Reality 密钥与 Short ID 已全部重新生成。旧链接立即失效。"
  show_credentials
}

remove_xray_service() {
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    systemctl disable --now xray-selfsteal >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/xray-selfsteal.service
    systemctl daemon-reload
  else
    rc-service xray-selfsteal stop >/dev/null 2>&1 || true
    rc-update del xray-selfsteal default >/dev/null 2>&1 || true
    rm -f /etc/init.d/xray-selfsteal
  fi
}

uninstall_all() {
  load_state
  printf '%b即将卸载 Xray，并把所有受管网站配置恢复到安装前的 443 监听。%b\n' "$C_YELLOW" "$C_RESET"
  read -r -p "输入域名 ${DOMAIN} 确认卸载：" confirm
  [[ "$confirm" == "$DOMAIN" ]] || die "确认内容不匹配，已取消。"
  remove_xray_service
  rm -f "$SELF_WEB_CONF"
  if [[ "$WEB_KIND" == "apache" && "$OS_ID" != "alpine" ]] && has a2dissite; then
    a2dissite "$(basename "$SELF_WEB_CONF")" >/dev/null 2>&1 || true
  fi
  restore_managed_files
  web_config_test || die "还原后的 Web 配置校验失败；备份仍保留在 ${BACKUP_DIR}，未删除状态目录。"
  web_reload || web_start
  if [[ -x "${ACME_HOME}/acme.sh" ]]; then
    "${ACME_HOME}/acme.sh" --remove -d "$DOMAIN" --ecc >/dev/null 2>&1 || true
  fi
  rm -rf "$WEBROOT"
  rm -rf "$(dirname "$XRAY_BIN")"
  rm -rf "$STATE_DIR"
  ok "卸载完成，网站配置已恢复。系统/面板 nginx、Apache 和 acme.sh 均予以保留。"
}

status_summary() {
  if [[ -f "$STATE_FILE" ]]; then
    load_state
    printf '当前状态：已安装（%s，域名 %s，Web: %s/%s）\n' "$INSTALLED_AT" "$DOMAIN" "$WEB_KIND" "$PANEL"
  else
    printf '当前状态：未安装\n'
  fi
}

menu() {
  printf '\n%b================================================%b\n' "$C_BLUE" "$C_RESET"
  printf ' VLESS + XTLS-Reality 偷自己  v%s\n' "$SCRIPT_VERSION"
  printf '%b================================================%b\n' "$C_BLUE" "$C_RESET"
  status_summary
  cat <<'EOF'

1) 全新安装
2) 重新生成密钥
3) 查看凭据
4) 同步现有网站
5) 卸载并还原网站设置
0) 退出
EOF
  read -r -p "请选择 [0-5]：" choice
  case "$choice" in
    1) install_all ;;
    2) rotate_keys ;;
    3) show_credentials ;;
    4) sync_websites ;;
    5) uninstall_all ;;
    0) exit 0 ;;
    *) die "无效选项。" ;;
  esac
}

main() {
  require_root
  case "${1:-menu}" in
    install) install_all ;;
    rotate) rotate_keys ;;
    show) show_credentials ;;
    sync) sync_websites ;;
    uninstall) uninstall_all ;;
    menu) menu ;;
    -h|--help|help)
      printf '用法：sudo bash %s [install|rotate|show|sync|uninstall]\n' "$0"
      ;;
    *) die "未知命令：$1" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
