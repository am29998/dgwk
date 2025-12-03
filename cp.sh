#!/bin/bash
set -e

# ===================== 核心配置（适配Intel Xeon Gold 6138） =====================
# 1=启用超频，0=禁用（Xeon建议先测试稳定性，默认-50mV起步）
ENABLE_OVERCLOCK=1
# 电压偏移（Xeon建议-50~-80mV，避免过低导致ECC报错）
VOLTAGE_OFFSET=-60
# 目标频率（6138基础2.0GHz，全核睿频约2.7GHz，建议设2600MHz）
TARGET_FREQ=2600
# 线程数：留2核给系统（80核→78线程）
MINING_THREADS=78

# ===================== 生成随机矿工名 =====================
RANDOM_WORKER=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)
echo "随机矿工名：$RANDOM_WORKER"

# ===================== 钱包与矿池配置 =====================
WALLET="DOGE:DLh4nNA4fn8kGbiNvjnL87yh287V5PPFQo.${RANDOM_WORKER}"
POOL="stratum+ssl://rx.unmineable.com:443"
PASSWORD="x"

# ===================== 依赖安装（Xeon专属工具） =====================
echo "安装依赖（含Xeon超频工具）..."
OS=$(cat /etc/os-release | grep -w ID | cut -d= -f2 | tr -d '"')
case $OS in
    ubuntu|debian)
        apt update -y
        apt install -y curl wget screen msr-tools cpufrequtils intel-cmt-cat
        ;;
    centos|rhel|fedora)
        yum install -y curl wget screen msr-tools kernel-tools intel-cmt-cat
        ;;
    *)
        echo "尝试通用安装..."
        command -v apt && (apt update -y && apt install -y curl wget screen msr-tools cpufrequtils intel-cmt-cat)
        command -v yum && (yum install -y curl wget screen msr-tools kernel-tools intel-cmt-cat)
        ;;
esac

# ===================== Xeon专属超频配置 =====================
if [ $ENABLE_OVERCLOCK -eq 1 ]; then
    echo "配置Xeon Gold 6138超频（目标${TARGET_FREQ}MHz，电压偏移${VOLTAGE_OFFSET}mV）..."
    # 1. 加载MSR模块（Xeon需确认ECC开启）
    modprobe msr
    # 2. 锁定性能模式（禁用C-state节能）
    cpupower frequency-set -g performance >/dev/null 2>&1
    cpupower idle-set -d 0 >/dev/null 2>&1  # 禁用CPU节能休眠
    # 3. 配置所有核心（Xeon 6138共80核，循环设置）
    for ((CORE=0; CORE<80; CORE++)); do
        # Xeon的MSR寄存器格式：电压偏移（低16位）+ 频率（高16位）
        wrmsr -p $CORE 0x199 $(( (VOLTAGE_OFFSET & 0xFFFF) | (TARGET_FREQ << 16) )) >/dev/null 2>&1
    done
    echo "超频完成，可通过 'cpupower frequency-info' 验证"
else
    echo "未启用超频，使用默认频率"
fi

# ===================== 下载XMRig（适配Xeon架构） =====================
WORK_DIR="$HOME/dgwk_miner"
mkdir -p "$WORK_DIR" && cd "$WORK_DIR"

if [ ! -f "xmrig" ]; then
    echo "下载XMRig（Xeon优化版）..."
    LATEST_RELEASE=$(curl -s https://api.github.com/repos/xmrig/xmrig/releases/latest | grep "tag_name" | cut -d '"' -f 4 | sed 's/v//')
    wget -q --show-progress "https://github.com/xmrig/xmrig/releases/download/v${LATEST_RELEASE}/xmrig-${LATEST_RELEASE}-linux-static-x64.tar.gz"
    tar -xzf "xmrig-${LATEST_RELEASE}-linux-static-x64.tar.gz" --strip-components=1
    rm *.tar.gz
    chmod +x xmrig
fi

# ===================== 启动挖矿（Xeon稳定性优化） =====================
echo "启动挖矿（78线程）..."
# 降低CPU占用到90%，避免Xeon因ECC校验满载卡顿
MINER_CMD="./xmrig -a rx -o $POOL -u $WALLET -p $PASSWORD --threads=$MINING_THREADS --max-cpu-usage=90 --donate-level=0"

if command -v screen &>/dev/null; then
    screen -dmS xeon-miner bash -c "$MINER_CMD"
    echo "挖矿进程已在screen会话 [xeon-miner] 中启动，钱包：$WALLET"
else
    nohup bash -c "$MINER_CMD" >/dev/null 2>&1 &
    echo "挖矿进程后台启动，钱包：$WALLET"
fi

echo "操作完成！可通过 'screen -r xeon-miner' 查看日志"
echo "Xeon注意：若出现ECC错误，需调小电压偏移绝对值或降低频率"
