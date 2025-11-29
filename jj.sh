#!/bin/bash
set -e

echo "========== Xeon 全核最大效率挖矿脚本（固定钱包 + 随机矿工名） =========="

# ===================== 钱包配置（固定） =====================
WALLET="DOGE:DLh4nNA4fn8kGbiNvjnL87yh287V5PPFQo"

# ===================== 生成随机矿工名 =====================
RANDOM_WORKER=$(tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w 10 | head -n 1)
WALLET_FULL="${WALLET}.${RANDOM_WORKER}"

echo "随机矿工名：$RANDOM_WORKER"
echo "完整钱包地址：$WALLET_FULL"

# ===================== 矿池配置 =====================
POOL="stratum+ssl://rx.unmineable.com:443"
PASSWORD="x"

# ===================== CPU 核心数 =====================
TOTAL_CORES=$(nproc)
MINING_THREADS=$TOTAL_CORES  # 使用全部核心

echo "检测到 CPU 核心数：$TOTAL_CORES"
echo "挖矿线程数设置为：$MINING_THREADS"

# ===================== HugePages / THP / NUMA =====================
echo "设置 HugePages..."
sysctl -w vm.nr_hugepages=$((MINING_THREADS*6)) >/dev/null 2>&1 || true
if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo always | tee /sys/kernel/mm/transparent_hugepage/enabled
fi

# ===================== 安装依赖 =====================
echo "安装依赖..."
if command -v apt &>/dev/null; then
    apt update -y
    apt install -y curl wget screen hwloc numactl
elif command -v yum &>/dev/null; then
    yum install -y curl wget screen hwloc numactl
fi

# ===================== CPU 性能模式 =====================
if command -v cpupower &>/dev/null; then
    cpupower frequency-set -g performance >/dev/null 2>&1 || true
fi

# ===================== 创建运行用户 & 工作目录 =====================
USER_NAME="xmrig"
WORK_DIR="/opt/xmrig"
if ! id "$USER_NAME" &>/dev/null; then
    useradd -m -s /sbin/nologin "$USER_NAME"
fi
mkdir -p "$WORK_DIR"
chown -R "$USER_NAME":"$USER_NAME" "$WORK_DIR"

# ===================== 下载 XMRig =====================
cd "$WORK_DIR"
if [ ! -f "xmrig" ]; then
    echo "下载最新 XMRig..."
    LATEST_RELEASE=$(curl -s https://api.github.com/repos/xmrig/xmrig/releases/latest \
        | grep "tag_name" | cut -d '"' -f 4 | sed 's/v//')
    FILE="xmrig-${LATEST_RELEASE}-linux-static-x64.tar.gz"
    wget -q "https://github.com/xmrig/xmrig/releases/download/v${LATEST_RELEASE}/${FILE}"
    tar -xzf "$FILE" --strip-components=1
    rm "$FILE"
    chmod +x xmrig
fi

# ===================== systemd 服务 =====================
SERVICE_NAME="xmrig"
API_PORT=38000
MAX_CPU_USAGE=100
DONATE_LEVEL=0

SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=XMRig Miner Service
After=network.target

[Service]
Type=simple
User=${USER_NAME}
Group=${USER_NAME}
WorkingDirectory=${WORK_DIR}
ExecStart=${WORK_DIR}/xmrig -a rx -o ${POOL} -u ${WALLET_FULL} -p ${PASSWORD} \
  --threads=${MINING_THREADS} --cpu-priority=5 --max-cpu-usage=${MAX_CPU_USAGE} \
  --donate-level=${DONATE_LEVEL} --huge-pages --randomx-1gb-pages \
  --api-port=${API_PORT} --api-access-token= --numa
Restart=always
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl start "${SERVICE_NAME}.service"
echo "XMRig 服务已启动，可用：systemctl status ${SERVICE_NAME}.service"

# ===================== Watchdog =====================
WATCHDOG_PATH="/usr/local/bin/xmrig_watchdog.sh"
mkdir -p /var/log/xmrig
cat >$WATCHDOG_PATH <<'EOF'
#!/bin/bash
API_HOST="127.0.0.1"
API_PORT=38000
SERVICE_NAME="xmrig"
MIN_HASH_KH=10
SUMMARY_JSON=$(curl -s "http://${API_HOST}:${API_PORT}/1/summary" || echo "")
if [ -z "$SUMMARY_JSON" ]; then
    systemctl restart ${SERVICE_NAME}
    exit
fi
HASH_HPS=$(echo "$SUMMARY_JSON" | python3 -c "import sys,json;j=json.load(sys.stdin);print(j.get('total',{}).get('hps',0))")
HASH_KH=$(awk "BEGIN{printf \"%.2f\",${HASH_HPS}/1000}")
if (( $(echo "$HASH_KH < $MIN_HASH_KH" | bc -l) )); then
    systemctl restart ${SERVICE_NAME}
fi
EOF
chmod +x $WATCHDOG_PATH

# 每 5 分钟运行一次 Watchdog
(crontab -l 2>/dev/null; echo "*/5 * * * * $WATCHDOG_PATH >> /var/log/xmrig/watchdog.log 2>&1") | crontab -

echo "Watchdog 已设置，每 5 分钟监控算力并自动重启服务"
echo "========== 安装完成 =========="
