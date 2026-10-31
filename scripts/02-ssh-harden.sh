#!/bin/bash
# 02-ssh-harden.sh — SSH 加固 + 高位端口迁移（两阶段）
#   --stage dual   22 与新端口并存（先跑这个）
#   --stage final  撤掉 22，只留新端口（外部验证通过后再跑）
#   --stage check  只打印当前有效配置
set -uo pipefail
. "$(dirname "$0")/lib.sh"
[ "$(id -u)" -eq 0 ] || die "需要 root"

STAGE="${1:---stage}"; STAGE="${2:-dual}"
CONF=/etc/ssh/sshd_config.d/00-hermes-hardening.conf
BACKUP=/root/sshd.bak-$STAMP

case "$STAGE" in
check)
  log "当前有效 sshd 配置"
  sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|permitemptypasswords|maxauthtries|logingracetime|x11forwarding|allowagentforwarding|maxsessions|clientaliveinterval)' || die "sshd -T 失败"
  log "监听端口"; ss -ltn | awk 'NR>1{print $4}' | sort -u
  exit 0;;
dual)
  log "阶段 1/2：双端口并存（22 + $SSH_PORT）"
  mkdir -p "$BACKUP"; cp -a /etc/ssh/. "$BACKUP"/ && ok "已备份 /etc/ssh → $BACKUP"
  cat > "$CONF" <<EOF
# Hermes 安全基线（$(date +%F)）。文件名必须 00- 前缀：OpenSSH 取「首个出现的值」，
# 50-cloud-init.conf 等供应商 drop-in 会压过 99- 前缀的文件。
Port 22
Port $SSH_PORT
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
MaxSessions 10
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding yes
GatewayPorts no
ClientAliveInterval 300
ClientAliveCountMax 2
UseDNS no
EOF
  chmod 600 "$CONF"
  sshd -t || { rm -f "$CONF"; die "sshd -t 失败，已删除 drop-in"; }
  ok "sshd -t 通过"
  guard 900 sec-rollback 'rm -f /etc/ssh/sshd_config.d/00-hermes-hardening.conf; systemctl reload ssh'
  systemctl reload ssh && sleep 2
  log "生效值（实测）"; sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|maxauthtries|x11forwarding|allowagentforwarding)'
  log "监听端口"; ss -ltn | awk 'NR>1{print $4}' | sort -u
  warn "现在必须从另一台机器验证：ssh -p $SSH_PORT root@<本机公网IP> 'hostname'（连续 2 次）"
  warn "验证通过后再执行：$0 --stage final";;
final)
  log "阶段 2/2：撤掉 22，只留 $SSH_PORT"
  [ -f "$CONF" ] || die "找不到 $CONF，先跑 --stage dual"
  ss -ltn | grep -q ":$SSH_PORT" || die "新端口 $SSH_PORT 未在监听，拒绝撤 22"
  sed -i '/^Port 22$/d' "$CONF"
  sshd -t || die "sshd -t 失败（未改动）"
  guard 900 sec-rollback 'rm -f /etc/ssh/sshd_config.d/00-hermes-hardening.conf; systemctl reload ssh'
  systemctl reload ssh && sleep 2
  log "生效端口：$(sshd -T | grep -E '^port' | tr '\n' ' ')"
  ok "监听：$(ss -ltn | awk 'NR>1{print $4}' | sort -u | tr '\n' ' ')"
  warn "外部探测 22 应为 Connection refused；新端口应可登录。确认后再拆保险："
  warn "  systemctl stop sec-rollback.timer";;
*) die "未知 stage: $STAGE（dual|final|check）";;
esac
