#!/usr/bin/env bash
set -euo pipefail

SSHD_CONFIG="/etc/ssh/sshd_config"
DROPIN_DIR="/etc/ssh/sshd_config.d"
DROPIN_FILE="${DROPIN_DIR}/99-root-pass-verify.conf"
SSH_PORT="${SSH_PORT:-22}"

log() { echo -e "[*] $*"; }
ok()  { echo -e "[+] $*"; }
warn(){ echo -e "[!] $*"; }
err() { echo -e "[-] $*" >&2; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "请用 root 执行，或 sudo 运行：sudo bash $0"
    exit 1
  fi
}

ts_now() { date +%F_%H%M%S; }

backup_file() {
  local f="$1"
  if [ -f "$f" ]; then
    cp -a "$f" "${f}.bak.$(ts_now)"
    ok "已备份：${f}.bak.$(ts_now)"
  fi
}

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf"; return; fi
  if command -v yum >/dev/null 2>&1; then echo "yum"; return; fi
  echo "unknown"
}

install_pkg_if_missing() {
  local bin="$1" pkg="$2"
  if command -v "$bin" >/dev/null 2>&1; then
    return 0
  fi
  local pm
  pm="$(detect_pkg_mgr)"
  case "$pm" in
    apt)
      log "安装依赖：$pkg（apt）..."
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
      ;;
    dnf)
      log "安装依赖：$pkg（dnf）..."
      dnf install -y "$pkg"
      ;;
    yum)
      log "安装依赖：$pkg（yum）..."
      yum install -y "$pkg"
      ;;
    *)
      err "缺少命令 $bin 且无法识别包管理器，无法自动安装 $pkg"
      exit 1
      ;;
  esac
}

set_sshd_kv_in_main() {
  local key="$1" val="$2"
  if grep -qiE "^[#[:space:]]*${key}[[:space:]]+" "$SSHD_CONFIG"; then
    sed -ri "s|^[#[:space:]]*(${key})[[:space:]]+.*|\1 ${val}|I" "$SSHD_CONFIG"
  else
    echo "${key} ${val}" >> "$SSHD_CONFIG"
  fi
}

write_dropin() {
  mkdir -p "$DROPIN_DIR"
  backup_file "$DROPIN_FILE"
  {
    echo "# Managed by aws_root_pass_verify.sh"
    echo "PermitRootLogin yes"
    echo "PasswordAuthentication yes"
    echo "Port ${SSH_PORT}"
    echo "PermitEmptyPasswords no"
    echo "ChallengeResponseAuthentication no"
    echo "KbdInteractiveAuthentication no"
  } > "$DROPIN_FILE"
  ok "已写入 drop-in：$DROPIN_FILE"
}

validate_sshd() {
  if command -v sshd >/dev/null 2>&1; then
    sshd -t
    ok "sshd 配置校验通过（sshd -t）"
  else
    warn "未找到 sshd 命令，跳过 sshd -t 校验"
  fi
}

restart_ssh() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files | grep -q '^ssh\.service'; then
      systemctl restart ssh
      ok "已重启：ssh.service"
      return 0
    fi
    if systemctl list-unit-files | grep -q '^sshd\.service'; then
      systemctl restart sshd
      ok "已重启：sshd.service"
      return 0
    fi
  fi

  if command -v service >/dev/null 2>&1; then
    service ssh restart && ok "已重启：service ssh" && return 0
    service sshd restart && ok "已重启：service sshd" && return 0
  fi

  err "无法自动重启 SSH，请手动执行：systemctl restart ssh 或 systemctl restart sshd"
  exit 1
}

listen_check() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -qE "LISTEN.*:${SSH_PORT}\b"
    return $?
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | grep -qE ":${SSH_PORT}\b"
    return $?
  fi
  return 0
}

# 真实验证：用密码 ssh 到本机 127.0.0.1
verify_root_password_login() {
  install_pkg_if_missing ssh ssh-client >/dev/null 2>&1 || true
  install_pkg_if_missing sshpass sshpass

  local pw
  echo
  echo "=== 现在请输入【刚设置的 root 密码】用于“真实登录验证”（输入不回显）==="
  read -r -s pw
  echo

  # 为了避免 sshpass 在 ps 泄露密码：用环境变量 + -e
  export SSHPASS="$pw"

  # 连接本机进行验证（不依赖 AWS 安全组）
  # BatchMode=no 允许密码；StrictHostKeyChecking=no 避免首次确认卡住
  set +e
  sshpass -e ssh \
    -p "$SSH_PORT" \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o ChallengeResponseAuthentication=no \
    -o PasswordAuthentication=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=8 \
    root@127.0.0.1 "echo __ROOT_PASSWORD_LOGIN_OK__" \
    >/tmp/root_login_verify.out 2>/tmp/root_login_verify.err
  local rc=$?
  set -e

  unset SSHPASS

  if [ $rc -eq 0 ] && grep -q "__ROOT_PASSWORD_LOGIN_OK__" /tmp/root_login_verify.out; then
    ok "验证成功 ✅：root + 密码 SSH 登录可用（已实际登录本机 127.0.0.1:${SSH_PORT}）"
    return 0
  fi

  err "验证失败 ❌：root + 密码 SSH 登录不可用（无法用密码实际登录本机 127.0.0.1:${SSH_PORT}）"
  echo "------ 诊断信息（stderr 摘要）------"
  tail -n 40 /tmp/root_login_verify.err || true
  echo "-----------------------------------"
  return 1
}

show_effective_config() {
  echo
  echo "====== 生效配置（sshd -T 摘要）======"
  if command -v sshd >/dev/null 2>&1; then
    sshd -T 2>/dev/null | egrep -i '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication)\b' || true
  else
    echo "(未找到 sshd -T，跳过)"
  fi
  echo "===================================="
}

main() {
  require_root

  if [ ! -f "$SSHD_CONFIG" ]; then
    err "找不到 $SSHD_CONFIG"
    exit 1
  fi

  if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    err "SSH_PORT 不合法：$SSH_PORT"
    exit 1
  fi

  log "备份 sshd 主配置..."
  backup_file "$SSHD_CONFIG"

  log "设置 root 密码（交互输入，不回显）..."
  passwd root
  ok "root 密码已设置"

  log "写入主配置关键项（兼容旧系统）..."
  set_sshd_kv_in_main "PermitRootLogin" "yes"
  set_sshd_kv_in_main "PasswordAuthentication" "yes"

  log "写入 drop-in 防止被覆盖..."
  write_dropin

  log "校验 sshd 配置..."
  validate_sshd

  log "重启 SSH..."
  restart_ssh

  if listen_check; then
    ok "端口监听检测：${SSH_PORT} 处于 LISTEN（如未检测到可能缺 ss/netstat）"
  else
    warn "端口监听检测：未看到 ${SSH_PORT} 在监听（这可能导致登录失败）"
  fi

  show_effective_config

  log "开始“真实登录验证”：root + 密码 SSH -> 127.0.0.1:${SSH_PORT}"
  if verify_root_password_login; then
    echo
    echo "======== 最终结果：PASS（可 root+密码 登录）========"
    exit 0
  else
    echo
    echo "======== 最终结果：FAIL（不可 root+密码 登录）========"
    echo "常见原因："
    echo "1) sshd_config.d 里还有别的文件覆盖了 PasswordAuthentication/PermitRootLogin"
    echo "2) PAM/策略限制（如某些镜像额外安全策略）"
    echo "3) SSH 实际监听端口不是 ${SSH_PORT}"
    exit 1
  fi
}

main "$@"
