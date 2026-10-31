#!/bin/bash
# 05-fail2ban.sh — sshd aggressive + recidive（journald-only 主机的正确写法）
set -uo pipefail
. "$(dirname "$0")/lib.sh"
[ "$(id -u)" -eq 0 ] || die "需要 root"

MEM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
[ "$MEM_MB" -lt 512 ] && { warn "<512MB 内存，按铁律不装 fail2ban（Python 运行时易 OOM）"; exit 0; }

command -v fail2ban-client >/dev/null || { log "安装 fail2ban"; DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban || die "安装失败"; }

J=/etc/fail2ban/jail.d/zz-hermes.local
log "写入 $J"
cat > "$J" <<EOF
# Hermes $(date +%F)
# 只要写了 [sshd] 段就必须带 backend，否则本地覆盖会把自动探测打回 polling，把跑着的 fail2ban 弄成 failed
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 $SSH_ALLOW_V4
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 4
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w

[sshd]
enabled = true
mode = aggressive
port = $SSH_PORT

[recidive]
enabled = true
# recidive 没有 journalmatch，在 [DEFAULT] backend=systemd 下会静默不启动，必须显式这两行
backend = auto
logpath = /var/log/fail2ban.log
EOF
chmod 644 "$J"

fail2ban-client -t || die "fail2ban 配置测试失败"
systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban
sleep 2

log "jail 列表（必须同时看到 sshd 与 recidive）"
fail2ban-client status
log "sshd jail 详情"; fail2ban-client status sshd 2>/dev/null | head -12
warn "若 recidive 不在列表：确认 backend=auto + logpath 两行都在，再 fail2ban-client reload"
