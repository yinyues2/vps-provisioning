#!/bin/bash
# 09-tcp-tuning.sh — 按 BDP 推导的 TCP/系统调优（中转/落地机通用）
# 用法：sudo ./09-tcp-tuning.sh            # 应用
#      sudo ./09-tcp-tuning.sh revert     # 临时回退到原厂参数（做 A/B 用）
set -uo pipefail
. "$(dirname "$0")/lib.sh"
[ "$(id -u)" -eq 0 ] || die "需要 root"

BW="${BW_MBPS:-1000}"; RTT="${RTT_MAX_MS:-226}"
# BDP(MB) = BW(Mbps) * RTT(ms) / 8 / 1000
BDP_MB=$(( BW * RTT / 8000 ))
[ "$BDP_MB" -lt 4 ] && BDP_MB=4
BUF=$(( BDP_MB * 1024 * 1024 ))
[ "$BUF" -lt 8388608 ] && BUF=8388608
[ "$BUF" -gt 67108864 ] && BUF=67108864
TMEM=$(( BUF / 4096 / 4 ))

if [ "${1:-apply}" = "revert" ]; then
  log "临时回退到镜像原厂参数（仅用于同端点 A/B 对比）"
  sysctl -qw net.core.rmem_max=16777216 net.core.wmem_max=16777216 \
             net.core.somaxconn=4096 net.ipv4.tcp_max_syn_backlog=256 \
             net.core.netdev_max_backlog=1000 net.ipv4.tcp_fastopen=1 \
             net.ipv4.tcp_slow_start_after_idle=1
  echo 4096 212992 16777216 > /proc/sys/net/ipv4/tcp_rmem
  echo 4096 212992 16777216 > /proc/sys/net/ipv4/tcp_wmem
  ip route change default via "$GATEWAY" dev "$IFACE" onlink
  ok "已回退：$(sysvals net.core.rmem_max net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_slow_start_after_idle)"
  exit 0
fi

log "BDP 推导：${BW}Mbps × ${RTT}ms = ${BDP_MB}MB → 缓冲上限 $((BUF/1024/1024))MB"

# 关键：文件名必须 zz-*，镜像的 /etc/sysctl.d/local.conf 字典序在 99-* 之后，会覆盖同名项且不报错
F=/etc/sysctl.d/zz-hermes-tcp-tuning.conf
cat > "$F" <<EOF
# Hermes TCP 调优 $(date +%F)（BDP=${BDP_MB}MB，缓冲=$((BUF/1024/1024))MB）
# 文件名必须 zz-*：local.conf 在字典序上排在 99-* 之后，会把 99- 文件里的同名项盖回去且不报错
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

net.core.rmem_max = $BUF
net.core.wmem_max = $BUF
net.ipv4.tcp_rmem = 4096 262144 $BUF
net.ipv4.tcp_wmem = 4096 262144 $BUF
net.ipv4.tcp_mem = $((TMEM)) $((TMEM*2)) $((TMEM*4))

net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 16384
net.core.netdev_budget = 600
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_mtu_probing = 1

fs.file-max = 2097152
fs.nr_open = 1048576
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.vfs_cache_pressure = 50
EOF
echo "net.ipv4.tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf
modprobe tcp_bbr 2>/dev/null || true
sysctl --system >/dev/null 2>&1 || true

log "initcwnd 32（带 120s 自动回滚）"
guard 120 route-rollback "ip route change default via $GATEWAY dev $IFACE onlink"
ip route change default via "$GATEWAY" dev "$IFACE" onlink initcwnd 32 initrwnd 32
ok "$(ip route show default)"

log "写持久化 oneshot（qdisc/initcwnd/io/THP）"
cat > /usr/local/sbin/hermes-tune-persist.sh <<'EOS'
#!/bin/bash
# 开机重放：root qdisc fq / initcwnd / io scheduler / read_ahead / nr_requests / THP madvise
IF=$(ip route show default | awk '{print $5; exit}')
GW=$(ip route show default | awk '{print $3; exit}')
for _ in $(seq 1 10); do [ -n "$IF" ] && [ -n "$GW" ] && break; sleep 2; IF=$(ip route show default|awk '{print $5;exit}'); GW=$(ip route show default|awk '{print $3;exit}'); done
tc qdisc replace dev "$IF" root fq 2>/dev/null
ip route change default via "$GW" dev "$IF" onlink initcwnd 32 initrwnd 32 2>/dev/null
for d in /sys/block/vd*/queue /sys/block/sd*/queue; do
  [ -w "$d/scheduler" ] && echo none > "$d/scheduler" 2>/dev/null
  [ -w "$d/read_ahead_kb" ] && echo 256 > "$d/read_ahead_kb" 2>/dev/null
  [ -w "$d/nr_requests" ] && echo 1024 > "$d/nr_requests" 2>/dev/null
done
# THP 不会自动持久，必须在这里重放
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
exit 0
EOS
chmod 755 /usr/local/sbin/hermes-tune-persist.sh
cat > /etc/systemd/system/hermes-tune-persist.service <<'EOS'
[Unit]
Description=Hermes TCP tuning persistence (qdisc/initcwnd/io/THP)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/hermes-tune-persist.sh

[Install]
WantedBy=multi-user.target
EOS
systemctl daemon-reload
systemctl enable --now hermes-tune-persist.service >/dev/null
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled

log "实测核对"
ok "cc/qdisc: $(sysvals net.ipv4.tcp_congestion_control net.core.default_qdisc)"
ok "缓冲: $(sysvals net.core.rmem_max net.core.wmem_max)"
ok "rmem/wmem: $(sysvals net.ipv4.tcp_rmem net.ipv4.tcp_wmem)"
ok "队列: $(sysvals net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog net.ipv4.tcp_fastopen net.ipv4.tcp_slow_start_after_idle)"
ok "qdisc: $(tc qdisc show dev "$IFACE" | head -1 | cut -c1-60)"
ok "route: $(ip route show default | grep -o 'initcwnd [0-9]*' || echo 'no initcwnd')"
ok "THP: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
warn "A/B：先跑基线 → sudo $0 revert → 同端点再测 → 重新 sudo $0 恢复"
warn "确认网络正常后拆 initcwnd 保险：systemctl stop route-rollback.timer（漏拆会静默回滚）"
