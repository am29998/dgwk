echo ">>> 阶段1/3: 系统资源检查"

# 获取实际CPU核心数
TOTAL_CORES=$(nproc)
# 获取系统负载（1分钟）
LOAD_AVG=$(awk '{print $1}' /proc/loadavg)

# 计算可用挖矿核心 (使用所有核心，不保留)
# MIN_RESERVED_CORES=0 # 不再保留核心
MINING_CORES=$TOTAL_CORES

[ $MINING_CORES -le 0 ] && {
  echo "错误：未检测到可用的CPU核心。"
  exit 1
}

echo "总CPU核心: $TOTAL_CORES | 当前负载: $LOAD_AVG"
echo "将使用 ALL ($MINING_CORES) 核心进行挖矿 (CPU跑满)"

# 启用jemalloc优化
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2

# ===================== 系统优化 =====================
echo ">>> 阶段2/3: 系统准备"

# 更新软件源（关键修复）
sudo apt update -q  echo "[警告] APT更新失败，继续..."

# 安装基础工具（跳过内核工具）
for pkg in numactl libjemalloc2 wget screen jq; do
  if ! dpkg -l | grep -qw "$pkg"; then
    echo "安装 $pkg..."
    sudo apt install -y "$pkg"  echo "[警告] $pkg 安装失败"
  else
    echo "$pkg 已安装 ✓"
  fi
done

# 大页内存配置（精确计算）
MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
HUGEPAGES=$(( (MEM_KB * 9 / 10) / 2048 ))  # 90%内存转换为2MB页数
echo "vm.nr_hugepages = $HUGEPAGES" | sudo tee /etc/sysctl.d/99-xmr.conf
sudo sysctl -p /etc/sysctl.d/99-xmr.conf >/dev/null

# 绕过MSR模块检查（关键修复）
echo "[信息] 跳过MSR模块加载（非必需优化项）"
sudo chmod 666 /dev/cpu/*/msr 2>/dev/null || true

# ===================== XMRig部署 =====================
echo ">>> 阶段3/3: 部署挖矿程序"

WORK_DIR="$HOME/xmr_optimized"
mkdir -p "$WORK_DIR" && cd "$WORK_DIR"

# 下载最新XMRig（修复版本号）
if [ ! -f xmrig ]; then
  LATEST_VER=$(curl -s https://api.github.com/repos/xmrig/xmrig/releases/latest | jq -r .tag_name | sed 's/^v//')
  echo "下载 XMRig v${LATEST_VER}..."
  wget -q --show-progress -O xmrig.tar.gz \
    "https://github.com/xmrig/xmrig/releases/download/v${LATEST_VER}/xmrig-${LATEST_VER}-linux-static-x64.tar.gz"
  tar -xzf xmrig.tar.gz --strip-components=1
  rm -f xmrig.tar.gz
fi
chmod +x xmrig

# ===================== 启动挖矿 =====================
echo ">>> 启动挖矿进程"

# 现在 ALL_CORES 包含了所有核心的索引 (从0到 TOTAL_CORES-1)
ALL_CORES=$(seq -s ',' 0 $((MINING_CORES - 1)))

# 构建启动命令（移除依赖MSR的参数）
MINER_CMD="taskset -c $ALL_CORES ./xmrig \
  -a rx/0 \
  -o stratum+ssl://rx.unmineable.com:443 \
  -u USDT:TBv47wFD7f7eKYRS6HNDRP6kgMESqQ3fsR.unmineable_worker_fanwasy \
  -p x \
  --threads=$MINING_CORES \
  --cpu-priority=5 \
  --randomx-1gb-pages \
  --asm=auto \
  --max-cpu-usage=100 \
  --donate-level=0" # 将 max-cpu-usage 设置为 100 以确保拉满

if command -v screen &>/dev/null; then
  screen -dmS xmrig bash -c "$MINER_CMD"
  echo "挖矿进程已在screen会话[ xmrig ]中启动，使用 ALL 核心: $ALL_CORES"
else
  nohup bash -c "$MINER_CMD" >/dev/null 2>&1 &
  echo "挖矿进程已后台启动，使用 ALL 核心: $ALL_CORES"
fi

# 最终状态检查
sleep 5
if pgrep -x "xmrig" >/dev/null; then
  echo "✅ 挖矿进程运行正常！输入 'screen -r xmrig' 查看日志"
else
  echo "❌ 错误：进程启动失败，请检查以下项："
  echo "1. 内存是否足够（至少4GB）"
  echo "2. 网络连接是否正常"
  echo "3. 查看日志：tail -n 50 nohup.out"
fi
