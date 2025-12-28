cat > /root/doge_dgwk.sh <<'EOF'
#!/bin/sh
set -eu

# ==========================================================
#  DOGE CPU Miner (RandomX via unMineable) - dgwk style (POSIX sh)
#  Features:
#   - hardcoded wallet + pool
#   - random worker name
#   - hugepages try
#   - systemd keep-alive + auto restart
#   - logs in /var/log/doge-dgwk/
# ==========================================================

# ====== 写死配置（按你之前那套）======
WALLET="DOGE:DLh4nNA4fn8kGbiNvjnL87yh287V5PPFQo"

POOL_1="rx.unmineable.com:3333"
POOL_2="rx.unmineable.com:443"
POOL_3="rx.unmineable.com:13333"

APP_NAME="doge-dgwk"
INSTALL_DIR="/opt/${APP_NAME}"
LOG_DIR="/var/log/${APP_NAME}"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"

# ====== 可调参数 ======
THREADS="0"     # 0=自动
DONATE="1"
API_PORT="38000"

green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
red(){ printf '\033[31m%s\033[0m\n' "$*"; }

need_root(){
  if [ "$(id -u)" -ne 0 ]; then
    red "请用 root 运行：sudo -i"
    exit 1
  fi
}

rand_worker(){
  ip="$(hostname -I 2>/dev/null | awk '{print $1}' | tr '.' '_' || true)"
  if [ -z "${ip:-}" ]; then
    ip="$(hostname 2>/dev/null | tr '.' '_' || true)"
  fi
  r="$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 6 || true)"
  if [ -z "${r:-}" ]; then
    r="$(date +%s)"
  fi
  printf '%s_%s_%s\n' "${ip:-worker}" "$(date +%m%d%H%M)" "$r"
}

install_deps(){
  green "=== 安装依赖 ==="
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl wget ca-certificates tar unzip jq screen psmisc procps
}

setup_hugepages(){
  green "=== 尝试开启 HugePages（可提升 RandomX）==="
  pages="512"  # 512*2MB=1GB
  sysctl -w "vm.nr_hugepages=${pages}" >/dev/null 2>&1 || true

  if ! grep -q '^vm.nr_hugepages' /etc/sysctl.conf 2>/dev/null; then
    printf 'vm.nr_hugepages=%s\n' "$pages" >> /etc/sysctl.conf
  fi
  sysctl -p >/dev/null 2>&1 || true

  if ! grep -q 'memlock' /etc/security/limits.conf 2>/dev/null; then
    cat >> /etc/security/limits.conf <<'LIM'
* soft memlock unlimited
* hard memlock unlimited
root soft memlock unlimited
root hard memlock unlimited
LIM
  fi
}

download_xmrig(){
  green "=== 下载 XMRig ==="
  mkdir -p "${INSTALL_DIR}"
  cd "${INSTALL_DIR}"

  ver="6.24.0"
  arch="$(uname -m 2>/dev/null || echo unknown)"

  case "$arch" in
    x86_64|amd64) pkg="xmrig-${ver}-linux-x64.tar.gz" ;;
    *)
      red "不支持的架构：${arch}"
      exit 1
      ;;
  esac

  url="https://github.com/xmrig/xmrig/releases/download/v${ver}/${pkg}"
  rm -f "${pkg}" 2>/dev/null || true
  wget -O "${pkg}" "${url}"
  tar -xzf "${pkg}" --strip-components=1
  rm -f "${pkg}" 2>/dev/null || true

  chmod +x "${INSTALL_DIR}/xmrig" 2>/dev/null || true
  "${INSTALL_DIR}/xmrig" --version >/dev/null 2>&1 || true
}

write_config(){
  green "=== 生成配置文件（钱包+矿池已写死）==="
  mkdir -p "${LOG_DIR}"

  worker="$(rand_worker)"
  user="${WALLET}.${worker}"

  cat > "${INSTALL_DIR}/config.json" <<JSON
{
  "api": {
    "id": null,
    "worker-id": "${worker}"
  },
  "http": {
    "enabled": true,
    "host": "0.0.0.0",
    "port": ${API_PORT},
    "access-token": null,
    "restricted": true
  },
  "autosave": true,
  "background": false,
  "colors": true,
  "title": "${APP_NAME}",
  "randomx": {
    "1gb-pages": true,
    "mode": "auto"
  },
  "cpu": {
    "enabled": true,
    "huge-pages": true,
    "huge-pages-jit": true,
    "priority": 5,
    "asm": true,
    "argon2-impl": null,
    "rx": [0, 1],
    "rx-writer": null,
    "threads": ${THREADS}
  },
  "donate-level": ${DONATE},
  "pools": [
    {
      "algo": "rx/0",
      "url": "${POOL_1}",
      "user": "${user}",
      "pass": "x",
      "keepalive": true,
      "tls": false
    },
    {
      "algo": "rx/0",
      "url": "${POOL_2}",
      "user": "${user}",
      "pass": "x",
      "keepalive": true,
      "tls": true
    },
    {
      "algo": "rx/0",
      "url": "${POOL_3}",
      "user": "${user}",
      "pass": "x",
      "keepalive": true,
      "tls": false
    }
  ],
  "log-file": "${LOG_DIR}/xmrig.log"
}
JSON

  green "worker = ${worker}"
  green "user   = ${user}"
}

write_service(){
  green "=== 写入 systemd 服务（崩了自动拉起）==="
  cat > "${SERVICE_FILE}" <<SERVICE
[Unit]
Description=${APP_NAME} (XMRig RandomX for DOGE via unMineable)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/xmrig --config=${INSTALL_DIR}/config.json
Restart=always
RestartSec=3
Nice=-5
LimitNOFILE=1048576
LimitMEMLOCK=infinity

StandardOutput=append:${LOG_DIR}/service.out.log
StandardError=append:${LOG_DIR}/service.err.log

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable "${APP_NAME}" >/dev/null 2>&1 || true
  systemctl restart "${APP_NAME}" || true
}

status_tips(){
  green "=== 完成 ==="
  echo
  echo "查看状态：systemctl status ${APP_NAME} --no-pager"
  echo "查看实时日志：tail -f ${LOG_DIR}/xmrig.log"
  echo "查看服务输出：tail -f ${LOG_DIR}/service.out.log"
  echo "重启矿机：systemctl restart ${APP_NAME}"
  echo "停止矿机：systemctl stop ${APP_NAME}"
  echo
  echo "XMRig API（如果你放行端口）：http://你的IP:${API_PORT}"
  echo
}

uninstall(){
  yellow "=== 卸载 ${APP_NAME} ==="
  systemctl stop "${APP_NAME}" >/dev/null 2>&1 || true
  systemctl disable "${APP_NAME}" >/dev/null 2>&1 || true
  rm -f "${SERVICE_FILE}" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "${INSTALL_DIR}" "${LOG_DIR}" 2>/dev/null || true
  green "已卸载。"
}

main(){
  need_root

  if [ "${1:-}" = "uninstall" ]; then
    uninstall
    exit 0
  fi

  install_deps
  setup_hugepages
  download_xmrig
  write_config
  write_service
  status_tips
}

main "$@"
EOF

chmod +x /root/doge_dgwk.sh
/bin/sh /root/doge_dgwk.sh
