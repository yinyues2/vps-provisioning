#!/bin/bash
# 99-rollback.sh — 逐项回滚（默认只打印，加 --yes 才执行）
set -uo pipefail
. "$(dirname "$0")/lib.sh"
[ "$(id -u)" -eq 0 ] || die "需要 root"

CMDS=$(cat <<EOF
# 1) SSH：删自己的 drop-in（22 会回到镜像默认）
rm -f /etc/ssh/sshd_config.d/00-hermes-hardening.conf && systemctl reload ssh
#    或整目录还原改前快照：
cp -a $SNAP_DIR/etc/ssh/. /etc/ssh/ && systemctl restart ssh
# 2) 防火墙
systemctl disable --now nftables && nft flush ruleset
# 3) 内核加固
rm -f /etc/sysctl.d/99-zz-hermes-hardening.conf && sysctl --system
# 4) fail2ban
rm -f /etc/fail2ban/jail.d/zz-hermes.local && systemctl restart fail2ban
# 5) 自动更新 / 日志
apt-get remove -y unattended-upgrades; rm -f /etc/apt/apt.conf.d/{20auto-upgrades,51-hermes-uu.conf}
sed -i 's/^SystemMaxUse=.*/#SystemMaxUse=/' /etc/systemd/journald.conf && systemctl restart systemd-journald
# 6) IPv6 恢复
rm -f /etc/sysctl.d/99-disable-ipv6.conf && sysctl --system
# 7) TCP 调优
rm -f /etc/sysctl.d/zz-hermes-tcp-tuning.conf /etc/modules-load.d/tcp_bbr.conf && sysctl --system
systemctl disable --now hermes-tune-persist.service
rm -f /etc/systemd/system/hermes-tune-persist.service /usr/local/sbin/hermes-tune-persist.sh && systemctl daemon-reload
ip route change default via $GATEWAY dev $IFACE onlink
echo always > /sys/kernel/mm/transparent_hugepage/enabled
echo 128 > /sys/block/vda/queue/read_ahead_kb 2>/dev/null || true
# 8) 保险：确保没有残留的定时回滚
systemctl stop sec-rollback.timer fw-rollback.timer route-rollback.timer v6-rollback.timer 2>/dev/null
EOF
)

log "回滚命令清单"
printf '%s\n' "$CMDS"

if [ "${1:-}" = "--yes" ]; then
  warn "开始执行回滚（60 秒后生效，可 Ctrl-C 取消）"; sleep 5
  printf '%s\n' "$CMDS" | grep -v '^#' | grep -v '^$' | bash -x
  ok "回滚完成，请立即验证 SSH 能登录"
else
  warn "未执行。确认后：sudo $0 --yes"
fi
