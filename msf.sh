#!/usr/bin/env bash
set -euo pipefail

# =========================
# DOGE CPU Miner (RandomX via unMineable)
# Container/Railway-friendly:
#  - Detects REAL usable CPU (cgroup quota + cpuset + nproc)
#  - Auto downloads xmrig (linux x64)
#  - Random worker name
#  - Hugepages best-effort
#  - Watchdog loop keep-alive (no systemd required)
# Logs: ./logs/
# =========================

# ---- Fixed config (按你之前那套钱包) ----
WALLET="DOGE:DLh4nNA4fn8kGbiNvjnL87yh287V5PPFQo"
# 你选择 b：优先走 443（常见更稳），同时给个明文端口做备选
POOL_SSL="stratum+ssl://rx.unmineable.com:443"
POOL_TCP="stratum+tcp://rx.unmineable.com:3333"

PASS="x"
ALGO="rx"

# ---- Paths ----
BASE_DIR="$(pwd)"
BIN_DIR="$BASE_DIR/xmrig-bin"
LOG_DIR="$BASE_DIR/logs"
mkdir -p "$BIN_DIR" "$LOG_DIR"

log() { echo "[$(date '+%F %T')] $*"; }

# ---- Detect usable cores in container (cgroup v2/v1 + cpuset + nproc) ----
count_cpuset_cores() {
  local f
  for f in /sys/fs/cgroup/cpuset.cpus.effective /sys/fs/cgroup/cpuset.cpus; do
    if [[ -r "$f" ]]; then
      local s; s="$(tr -d ' \n' < "$f")"
      if [[ -n "$s" ]]; then
        # Convert like 0-3,6,8-9 => count
        python3 - <<'PY' "$s" 2>/dev/null || true
import sys
s=sys.argv[1]
total=0
for part in s.split(','):
    if '-' in part:
        a,b=part.split('-')
        total += int(b)-int(a)+1
    else:
        total += 1
print(total)
PY
        return 0
      fi
    fi
  done
  echo 999999
}

count_quota_cores_cgv2() {
  local f="/sys/fs/cgroup/cpu.max"
  if [[ -r "$f" ]]; then
    local q p
    read -r q p < "$f" || true
    if [[ "${q:-}" == "max" || -z "${q:-}" || -z "${p:-}" ]]; then
      echo 999999
      return 0
    fi
    # ceil(q/p)
    python3 - <<'PY' "$q" "$p" 2>/dev/null || true
import sys, math
q=int(sys.argv[1]); p=int(sys.argv[2])
print(max(1, math.floor((q + p - 1)/p)))
PY
    return 0
  fi
  echo 999999
}

count_quota_cores_cgv1() {
  local qf="/sys/fs/cgroup/cpu/cpu.cfs_quota_us"
  local pf="/sys/fs/cgroup/cpu/cpu.cfs_period_us"
  if [[ -r "$qf" && -r "$pf" ]]; then
    local q p
    q="$(cat "$qf" 2>/dev/null || echo -1)"
    p="$(cat "$pf" 2>/dev/null || echo 100000)"
    if [[ "$q" == "-1" || -z "$q" || -z "$p" ]]; then
      echo 999999
      return 0
    fi
    python3 - <<'PY' "$q" "$p" 2>/dev/null || true
import sys, math
q=int(sys.argv[1]); p=int(sys.argv[2])
print(max(1, math.floor((q + p - 1)/p)))
PY
    return 0
  fi
  echo 999999
}

detect_threads() {
  local nproc_ cores_cpuset quota2 quota1 quota
  nproc_="$(nproc 2>/dev/null || echo 1)"
  cores_cpuset="$(count_cpuset_cores || echo 999999)"
  quota2="$(count_quota_cores_cgv2 || echo 999999)"
  quota1="$(count_quota_cores_cgv1 || echo 999999)"

  quota="$quota2"
  [[ "$quota1" -lt "$quota" ]] && quota="$quota1"

  # take min(nproc, cpuset, quota)
  local m="$nproc_"
  [[ "$cores_cpuset" -lt "$m" ]] && m="$cores_cpuset"
  [[ "$quota" -lt "$m" ]] && m="$quota"

  # safety
  [[ "$m" -lt 1 ]] && m=1
  echo "$m"
}

# ---- Download xmrig (linux x64) ----
download_xmrig() {
  local arch
  arch="$(uname -m)"
  if [[ "$arch" != "x86_64" && "$arch" != "amd64" ]]; then
    log "当前架构: $arch（此脚本默认下载 Linux x64 的 xmrig）。"
    log "如果你是 ARM，请告诉我架构我给你换包。"
    exit 1
  fi

  local url version tar
  # 固定一个稳定版本（不需要你额外输入）
  version="6.24.0"
  tar="xmrig-${version}-linux-static-x64.tar.gz"
  url="https://github.com/xmrig/xmrig/releases/download/v${version}/${tar}"

  if [[ -x "$BIN_DIR/xmrig" ]]; then
    log "xmrig 已存在，跳过下载。"
    return 0
  fi

  log "下载 xmrig v${version} ..."
  command -v curl >/dev/null 2>&1 || { log "缺少 curl，正在安装..."; apt-get update -y && apt-get install -y curl; }
  command -v tar >/dev/null 2>&1 || { log "缺少 tar，正在安装..."; apt-get update -y && apt-get install -y tar; }

  curl -L --fail --retry 3 --retry-delay 1 -o "$BIN_DIR/$tar" "$url"
  tar -xzf "$BIN_DIR/$tar" -C "$BIN_DIR"
  # 解包后目录形如 xmrig-6.24.0/
  mv "$BIN_DIR/xmrig-${version}/xmrig" "$BIN_DIR/xmrig"
  rm -rf "$BIN_DIR/xmrig-${version}" "$BIN_DIR/$tar"
  chmod +x "$BIN_DIR/xmrig"
  log "xmrig 就绪：$BIN_DIR/xmrig"
}

# ---- Hugepages best-effort ----
try_hugepages() {
  # 容器里通常没权限，失败也不退出
  ( sysctl -w vm.nr_hugepages=128 >/dev/null 2>&1 || true )
  ( echo 128 > /proc/sys/vm/nr_hugepages >/dev/null 2>&1 || true )
}

random_worker() {
  # 生成短 worker，避免太长被池子截断
  local r
  r="$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 8 || echo "worker")"
  echo "unmineable_${r}"
}

start_miner_once() {
  local threads worker logf
  threads="$(detect_threads)"
  worker="$(random_worker)"
  logf="$LOG_DIR/miner_$(date '+%F_%H%M%S').log"

  log "检测到可用 CPU 线程数(按配额/绑核/实际核数取最小)：$threads"
  log "worker：$worker"
  log "日志：$logf"

  try_hugepages

  # 先尝试 443 SSL（你选 b），不通再走 3333
  set +e
  "$BIN_DIR/xmrig" -a "$ALGO" -o "$POOL_SSL" -u "${WALLET}.${worker}" -p "$PASS" \
    --threads="$threads" --donate-level=0 --log-file="$logf"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    log "SSL 443 退出(rc=$rc)，切换到 3333 重试..."
    "$BIN_DIR/xmrig" -a "$ALGO" -o "$POOL_TCP" -u "${WALLET}.${worker}" -p "$PASS" \
      --threads="$threads" --donate-level=0 --log-file="$logf"
  fi
}

main() {
  download_xmrig

  log "进入 watchdog 常驻模式（xmrig 退出就自动拉起）"
  while true; do
    start_miner_once || true
    log "xmrig 已退出，5 秒后重启..."
    sleep 5
  done
}

main "$@"
