#!/bin/bash
# 03-nft-ssh-whitelist.sh — 只锁 SSH 端口的源 IP 白名单（默认策略保持 accept）
# 用法：sudo ./03-nft-ssh-whitelist.sh [apply]
#   不带参数 = 只打印将要写入的配置（dry-run）
set -uo pipefail
. "$(dirname "$0")/lib.sh"
[ "$(id -u)" -eq 0 ] || die "需要 root"

# 把 "1.2.3.4 5.6.7.8 100.64.0.0/10" 变成 nft 元素列表
v4_list() { echo "$SSH_ALLOW_V4" | tr ' ' '\n' | sed '/^$/d' | paste -sd, - | sed 's/,/, /g'; }
v6_list() { echo "$SSH_ALLOW_V6" | tr ' ' '\n' | sed '/^$/d' | paste -sd, - | sed 's/,/, /g'; }

CONF=$(cat <<EOF
#!/usr/sbin/nft -f
# Hermes $(date +%F)：只锁 SSH 端口 $SSH_PORT，默认策略保持 accept（不连坐业务端口）
flush ruleset

table inet filter {
    set ssh_allow_v4 {
        type ipv4_addr
        flags interval
        elements = { $(v4_list) }
    }
    set ssh_allow_v6 {
        type ipv6_addr
        flags interval
        elements = { $(v6_list) }
    }
    chain input {
        type filter hook input priority filter; policy accept;
        iif lo accept
        ct state established,related accept
        ip  saddr @ssh_allow_v4 tcp dport $SSH_PORT accept
        ip6 saddr @ssh_allow_v6 tcp dport $SSH_PORT accept
        tcp dport $SSH_PORT drop
    }
}
EOF
)

if [ "${1:-}" != "apply" ]; then
  log "dry-run：以下内容将写入 /etc/nftables.conf"
  echo "$CONF"
  warn "确认无误后执行：sudo $0 apply"
  exit 0
fi

log "写入 /etc/nftables.conf"
[ -f /etc/nftables.conf ] && cp -a /etc/nftables.conf "/etc/nftables.conf.bak-$STAMP"
printf '%s\n' "$CONF" > /etc/nftables.conf
chmod 640 /etc/nftables.conf
nft -c -f /etc/nftables.conf || die "nft 预检失败（未启用服务）"
ok "nft 预检通过"

guard 600 fw-rollback 'nft flush ruleset'
systemctl enable --now nftables
sleep 1
log "生效规则"; nft list ruleset
ok "nftables：$(systemctl is-enabled nftables)/$(systemctl is-active nftables)"
warn "三向验证：①白名单内第 1 台能连 ②白名单内第 2 台能连 ③名单外第 3 台必须超时（不是 refused）"
warn "IPv6 验证用差分法：探一个无监听端口(如 [v6]:22) 应 REFUSED，探 $SSH_PORT 应超时"
warn "全部通过后拆保险：systemctl stop fw-rollback.timer"
