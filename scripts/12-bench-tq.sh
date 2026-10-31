#!/bin/bash
# 12-bench-tq.sh — TcpQuality --all
# 来源：https://github.com/ibsgss/TcpQuality ；runner https://tcpquality.ibsgss.uk/run（rootfs v1.00045）
# 关键坑：没有 TERM 变量时脚本会直接 exit 1（"TERM environment variable not set."），必须 TERM=xterm-256color
set -uo pipefail
. "$(dirname "$0")/lib.sh"
[ "$(id -u)" -eq 0 ] || die "需要 root"

log "下载 TQ runner"
curl -fsSL --retry 3 https://tcpquality.ibsgss.uk/run -o /root/tq.sh || die "下载失败"
chmod +x /root/tq.sh

log "后台启动（约 20–30 分钟；systemd-run + TERM）"
systemctl reset-failed tq-bench 2>/dev/null || true
systemd-run --unit=tq-bench --collect --setenv=TERM=xterm-256color bash /root/tq.sh --all >/dev/null 2>&1
sleep 25
ok "状态: $(systemctl is-active tq-bench)"
journalctl -u tq-bench -n 8 --no-pager 2>/dev/null | tail -8
cat <<'EOF'

  跟踪：  journalctl -u tq-bench -f
  完成：  journalctl -u tq-bench --no-pager -o cat | grep -o 'https://tcpquality.ibsgss.uk/r/[A-Za-z0-9_-]*'
  纯文本落档：
    journalctl -u tq-bench --no-pager -o cat | tr -d '\r' \
      | grep -vE 'blob data|\] [0-9]+/[0-9]+ \(|^#+$|^-+$|^ *$' > /root/tq-plain.txt
EOF
