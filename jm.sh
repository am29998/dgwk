cat > doge_railway.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

WALLET="DOGE:DLh4nNA4fn8kGbiNvjnL87yh287V5PPFQo"
PASS="x"

# 你要固定 worker 也行：WORKER="unmineable_worker_xxx"
WORKER="${WORKER:-unmineable_worker_$(tr -dc a-z0-9 </dev/urandom | head -c 8)}"

# XMRig 版本（你图里是 6.23.0）
XMRIG_VER="${XMRIG_VER:-6.23.0}"
XMRIG_DIR="${XMRIG_DIR:-xmrig-${XMRIG_VER}}"

# 端口（ssl 443 优先）
POOL_PORT_SSL="${POOL_PORT_SSL:-443}"

# ====== 检测容器内存上限（cgroup v2 / v1 兼容）======
get_mem_limit_mb() {
  local bytes=""

  if [[ -f /sys/fs/cgroup/memory.max ]]; then
    bytes="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)"
    if [[ "$bytes" == "max" || -z "$bytes" ]]; then
      bytes=""
    fi
  fi

  if [[ -z "$bytes" && -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
    bytes="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || true)"
  fi

  if [[ -z "$bytes" ]]; then
    # 兜底：读系统可见内存（不准，但比没有强）
    awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo
    return
  fi

  # bytes -> MB
  python3 - <<PY 2>/dev/null || awk "BEGIN{print int($bytes/1024/1024)}"
b=int($bytes)
print(int(b/1024/1024))
PY
}

MEM_MB="$(get_mem_limit_mb)"
CPU_THREADS="$(nproc 2>/dev/null || echo 1)"

# ====== 算法选择逻辑 ======
# RandomX 初始化通常需要 ~2.3GB+，再加系统/程序开销，建议至少 3.2GB 才稳
# 内存不足就切到省内存算法（默认 ghostrider）
ALGO="${ALGO:-}"
POOL_HOST="${POOL_HOST:-}"

if [[ -z "${ALGO}" || -z "${POOL_HOST}" ]]; then
  if [[ "${MEM_MB}" -ge 3200 ]]; then
    ALGO="rx"
    POOL_HOST="rx.unmineable.com"
  else
    ALGO="ghostrider"
    POOL_HOST="ghostrider.unmineable.com"
  fi
fi

# ====== 线程策略 ======
# Railway CPU 常常是共享/限频，盲目 48 线程不一定更快，反而容易被平台判异常/抢占
# 默认：CPU 线程数；你想强行榨就在运行前 export THREADS=48
THREADS="${THREADS:-$CPU_THREADS}"

# rx 模式下，线程过高意义不大且更吃资源；给个保守上限避免“榨过头导致被干掉”
if [[ "$ALGO" == "rx" && "$THREADS" -gt "$CPU_THREADS" ]]; then
  THREADS="$CPU_THREADS"
fi

echo "===== Railway XMRig 启动参数 ====="
echo "MemLimit: ${MEM_MB} MB"
echo "CPU:      ${CPU_THREADS} threads"
echo "ALGO:     ${ALGO}"
echo "POOL:     ${POOL_HOST}:${POOL_PORT_SSL} (ssl)"
echo "WORKER:   ${WORKER}"
echo "THREADS:  ${THREADS}"
echo "================================="

# ====== 安装依赖 ======
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y curl ca-certificates tar gzip >/dev/null 2>&1 || true
fi

# ====== 下载 XMRig ======
if [[ ! -d "$XMRIG_DIR" ]]; then
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) PKG="xmrig-${XMRIG_VER}-linux-static-x64.tar.gz" ;;
    aarch64|arm64) PKG="xmrig-${XMRIG_VER}-linux-static-arm64.tar.gz" ;;
    *) echo "不支持的架构: $ARCH" ; exit 1 ;;
  esac

  URL="https://github.com/xmrig/xmrig/releases/download/v${XMRIG_VER}/${PKG}"
  echo "[+] downloading: $URL"
  curl -L --fail --retry 5 --retry-delay 2 -o "${PKG}" "$URL"
  tar -xzf "${PKG}"
fi

cd "$XMRIG_DIR"

# ====== 关键：Railway 容器里 hugepages / msr 基本没戏，直接关闭相关尝试，减少报错和不稳定 ======
COMMON_ARGS=(
  "-a" "${ALGO}"
  "-o" "stratum+ssl://${POOL_HOST}:${POOL_PORT_SSL}"
  "-u" "${WALLET}.${WORKER}"
  "-p" "${PASS}"
  "--donate-level=0"
  "--no-color"
  "--threads=${THREADS}"
  "--no-huge-pages"
)

# rx 特化：避免在容器里做无意义的内核优化尝试
if [[ "${ALGO}" == "rx" ]]; then
  COMMON_ARGS+=("--randomx-no-numa" "--cpu-no-yield")
fi

# ====== 守护：崩了就重启（Railway 很需要）======
while true; do
  echo "[*] $(date '+%F %T') starting xmrig..."
  ./xmrig "${COMMON_ARGS[@]}" || true
  echo "[!] $(date '+%F %T') xmrig exited. restart in 3s..."
  sleep 3
done
SH

chmod +x doge_railway.sh
./doge_railway.sh
