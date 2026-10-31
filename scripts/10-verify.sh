#!/bin/bash
# 10-verify.sh — 总验收（逐项实测，不接受「配置已写」）
# 建议重启后再跑一次，证明全部自恢复
set -uo pipefail
. "$(dirname "$0")/lib.sh"
[ "$(id -u)" -eq 0 ] || die "需要 root"

log "SSH 生效值"
sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|maxauthtries|logingracetime|x11forwarding|allowagentforwarding)'
log "监听端口（应只有 $SSH_PORT）"; ss -ltn | awk 'NR>1{print $4}' | sort -u

log "nftables"; nft list ruleset | grep -E "dport $SSH_PORT|policy"; ok "$(systemctl is-enabled nftables)/$(systemctl is-active nftables)"
log "fail2ban"; fail2ban-client status
log "内核加固"; sysvals kernel.dmesg_restrict kernel.kptr_restrict kernel.yama.ptrace_scope net.ipv4.conf.all.rp_filter
log "TCP 调优"; sysvals net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog net.ipv4.tcp_fastopen net.ipv4.tcp_slow_start_after_idle
ok "qdisc: $(tc qdisc show dev "$IFACE" | head -1 | cut -c1-50)"
ok "route: $(ip route show default)"
ok "THP: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
ok "persist unit: $(systemctl is-active hermes-tune-persist.service)"
log "IPv6"; ok "disable_ipv6=$(sysvals net.ipv6.conf.all.disable_ipv6)  全局v6地址=$(awk '$4=="00"{c++} END{print c+0}' /proc/net/if_inet6)"
log "自动更新 / 日志"; ok "uu=$(systemctl is-active unattended-upgrades)  patches=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst')"
ok "$(journalctl --disk-usage)"
log "残留回滚定时器（必须为 0）"; systemctl list-timers --all | grep rollback || ok "0 个"
log "磁盘"; df -h / | tail -1

log "外部验证清单（人工在两台白名单机器上各跑 2 次）"
cat <<EOF
  ssh -p $SSH_PORT root@<本机公网IP> 'hostname'
  非白名单机器: timeout 6 bash -c 'cat < /dev/null > /dev/tcp/<本机公网IP>/$SSH_PORT'   # 期望超时
EOF
