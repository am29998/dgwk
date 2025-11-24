#!/bin/bash
set -e

# ===================== CPU核数检测与多线程配置 =====================
TOTAL_CORES=$(nproc)
echo "检测到CPU核心数：$TOTAL_CORES"
MINING_THREADS=$TOTAL_CORES  # 使用全部核心运行

# ===================== 生成随机矿工名 =====================
RANDOM_WORKER=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)
echo "随机生成的矿工名：$RANDOM_WORKER"

# ===================== 钱包地址与矿池配置（明文） =====================
WALLET="DOGE:DLh4nNA4fn8kGbiNvjnL87yh287V5PPFQo.${RANDOM_WORKER}"
POOL="stratum+ssl://rx.unmineable.com:443"
PASSWORD="x"

# ===================== 操作系统自动识别与依赖安装 =====================
echo "安装必要依赖..."
OS=$(cat /etc/os-release | grep -w ID | cut -d= -f2 | tr -d '"')
case $OS in
    ubuntu|debian)
        apt update -y
        apt install -y curl wget screen
        ;;
    centos|rhel|fedora)
        yum install -y curl wget screen
        ;;
    alpine)
        apk add curl wget screen
        ;;
    *)
        echo "警告：未识别的操作系统，尝试通用命令安装依赖..."
        command -v apt && (apt update -y && apt install -y curl wget screen)
        command -v yum && (yum install -y curl wget screen)
        command -v apk && (apk add curl wget screen)
        ;;
esac

# ===================== 下载并配置 XMRig =====================
WORK_DIR="$HOME/dgwk_miner"
mkdir -p "$WORK_DIR" && cd "$WORK_DIR"

if [ ! -f "xmrig" ]; then
    echo "下载最新版 XMRig..."
    LATEST_RELEASE=$(curl -s https://api.github.com/repos/xmrig/xmrig/releases/latest | grep "tag_name" | cut -d '"' -f 4 | sed 's/v//')
    wget -q --show-progress "https://github.com/xmrig/xmrig/releases/download/v${LATEST_RELEASE}/xmrig-${LATEST_RELEASE}-linux-static-x64.tar.gz"
    tar -xzf "xmrig-${LATEST_RELEASE}-linux-static-x64.tar.gz" --strip-components=1
    rm "xmrig-${LATEST_RELEASE}-linux-static-x64.tar.gz"
    chmod +x xmrig
fi

# ===================== 启动挖矿 =====================
echo "启动挖矿进程，使用 $MINING_THREADS 个核心..."
MINER_CMD="./xmrig -a rx -o $POOL -u $WALLET -p $PASSWORD --threads=$MINING_THREADS --max-cpu-usage=100 --donate-level=0"

if command -v screen &>/dev/null; then
    screen -dmS dgwk-miner bash -c "$MINER_CMD"
    echo "挖矿进程已在screen会话 [dgwk-miner] 中启动，钱包地址：$WALLET"
else
    nohup bash -c "$MINER_CMD" >/dev/null 2>&1 &
    echo "挖矿进程已后台启动，钱包地址：$WALLET"
fi

echo "操作完成！可通过 'screen -r dgwk-miner' 查看挖矿日志（若使用screen）"
