#!/bin/bash
# 01-snapshot.sh — 开荒前快照（只读）。所有"改前"证据都从这里取。
set -uo pipefail
. "$(dirname "$0")/lib.sh"
need_root

log "生成快照到 $SNAP_DIR"
mkdir -p "$SNAP_DIR"/{etc,root}
cp -a /etc/ssh "$SNAP_DIR/etc/ssh"
cp -a /etc/fail2ban "$SNAP_DIR/etc/fail2ban" 2>/dev/null
cp -a /etc/sysctl.d "$SNAP_DIR/etc/sysctl.d" 2>/dev/null
cp -a /etc/sysctl.conf "$SNAP_DIR/etc/" 2>/dev/null
cp -a /etc/fstab "$SNAP_DIR/etc/fstab"
cp -a /etc/nftables.conf "$SNAP_DIR/etc/" 2>/dev/null
cp -a /etc/systemd/journald.conf "$SNAP_DIR/etc/" 2>/dev/null
iptables-save > "$SNAP_DIR/root/iptables-save.txt" 2>/dev/null
(nft list ruleset > "$SNAP_DIR/root/nft-ruleset.txt" 2>/dev/null) || echo "nft-not-installed" > "$SNAP_DIR/root/nft-ruleset.txt"
sysctl -a > "$SNAP_DIR/root/sysctl-all.txt" 2>/dev/null
tc qdisc show > "$SNAP_DIR/root/tc-qdisc.txt" 2>/dev/null
tc -s qdisc show > "$SNAP_DIR/root/tc-qdisc-stats.txt" 2>/dev/null
ip route show > "$SNAP_DIR/root/ip-route.txt"
ip -6 route show > "$SNAP_DIR/root/ip6-route.txt"
ip -o addr show > "$SNAP_DIR/root/ip-addr.txt"
ss -ltnup > "$SNAP_DIR/root/ss-ltnup.txt" 2>/dev/null
systemctl list-units --state=running > "$SNAP_DIR/root/units-running.txt" 2>/dev/null
dpkg --get-selections > "$SNAP_DIR/root/dpkg-selections.txt" 2>/dev/null || rpm -qa | sort > "$SNAP_DIR/root/pkg-list.txt"
sshd -T > "$SNAP_DIR/root/sshd-effective.txt" 2>/dev/null || warn "sshd -T 需要 root（已是 root）"
cp -a /root/.ssh "$SNAP_DIR/root/ssh-home" 2>/dev/null
chmod -R go-rwx "$SNAP_DIR"

ok "快照大小：$(du -sh "$SNAP_DIR" | cut -f1)"
ok "当前监听端口：$(ss -ltn | awk 'NR>1{print $4}' | sort -u | tr '\n' ' ')"
ok "当前全局 IPv6 地址数：$(awk '$4=="00"{c++} END{print c+0}' /proc/net/if_inet6)"
ok "当前 sshd 端口：$(sshd -T 2>/dev/null | grep -E '^port' | tr '\n' ' ')"
warn "以上端口集合是后续验收的回归基线，加固后必须一致（除本流程主动撤掉/新增的 22 与新端口）"
