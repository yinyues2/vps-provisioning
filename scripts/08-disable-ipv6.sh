#!/bin/bash
# 08-disable-ipv6.sh — 全机禁用 IPv6（机队默认；v4 单栈）
# 安全闸门：确认 SSH 走 v4；代理/落地机先确认没有节点引用该 v6 地址
set -uo pipefail
. "$(dirname "$0")/lib.sh"
[ "$(id -u)" -eq 0 ] || die "需要 root"

log "关前状态"
echo "  全局 v6 地址数: $(awk '$4=="00"{c++} END{print c+0}' /proc/net/if_inet6)"
echo "  disable_ipv6: $(sysvals net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6)"
echo "  当前 SSH 来源: ${SSH_CONNECTION:-未知}"
case "${SSH_CONNECTION:-}" in
  *:*:*) warn "当前会话似乎走 IPv6，关停会断线！先改用 IPv4 再执行" ;;
esac

F=/etc/sysctl.d/99-disable-ipv6.conf
{
  echo "# Hermes $(date +%F)：全机禁用 IPv6（v4 单栈）"
  echo "# 只写 all 在部分内核/已存在接口上不生效，必须同时写 default/lo 与每个实际网卡"
  echo "net.ipv6.conf.all.disable_ipv6 = 1"
  echo "net.ipv6.conf.default.disable_ipv6 = 1"
  echo "net.ipv6.conf.lo.disable_ipv6 = 1"
  for i in /sys/class/net/*; do
    n=$(basename "$i")
    [ "$n" = "lo" ] && continue
    echo "net.ipv6.conf.$n.disable_ipv6 = 1"
  done
} > "$F"
log "写入 $F"; cat "$F"

# 注意：关 IPv6 不会把你锁在外面（SSH 走 v4），所以【不要】为它武装定时回滚——
# 曾经的坑：武装了 300s 回滚，验证完忘了拆，到点自动把 /etc/sysctl.d/99-disable-ipv6.conf 删掉并重新打开 IPv6，
# 看起来就像「配置没生效/被还原」。确实需要兜底时才加 --guard。
if [ "${1:-}" = "--guard" ]; then
  guard 600 v6-rollback 'rm -f /etc/sysctl.d/99-disable-ipv6.conf; sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 net.ipv6.conf.lo.disable_ipv6=0'
else
  warn "未武装回滚（IPv6 关停不影响 v4 SSH；需要兜底请加 --guard 并在验证后 systemctl stop v6-rollback.timer）"
fi
sysctl --system >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1 net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1
for i in /sys/class/net/*; do
  n=$(basename "$i"); [ "$n" = "lo" ] && continue
  sysctl -w "net.ipv6.conf.$n.disable_ipv6=1" >/dev/null 2>&1 || true
done
sleep 1

log "关后校验"
ok "disable_ipv6 = $(sysvals net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6)"
ok "全局 v6 地址数 = $(awk '$4=="00"{c++} END{print c+0}' /proc/net/if_inet6)（应为 0）"
ok "监听端口: $(ss -ltn | awk 'NR>1{print $4}' | sort -u | tr '\n' ' ')"
warn "ss 里残留的 [::]:<port> 是旧进程持有的 socket，没有 v6 地址即不可达，不要为消掉它重启业务"
warn "验证 IPv4 SSH 仍可登录；若用了 --guard，务必 systemctl stop v6-rollback.timer（否则到点会静默重开 IPv6）"
