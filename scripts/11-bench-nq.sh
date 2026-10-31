#!/bin/bash
# 11-bench-nq.sh — NodeQuality 修补版「深度全量 v/y/y/y」
# 来源：https://github.com/yinyues2/NodeQuality 分支 hermes-fixed（上游 LloydAsp/NodeQuality，基线 a92fca6）
# 修补内容：run_ip_quality() 若存在 $HERMES_IPQ（默认 /root/ipq-hermes.sh）就用修补版 IPQuality；
#          修补版修 AmazonPV（浏览器头+重试）、Reddit（先测首页）、Netflix（剔除 DNS 应答数启发式误判）
set -uo pipefail
. "$(dirname "$0")/lib.sh"
[ "$(id -u)" -eq 0 ] || die "需要 root"

BENCH="${1:-/root/bench-nq}"
mkdir -p "$BENCH" && cd "$BENCH" || die "无法进入 $BENCH"

log "下载 NQ 修补版脚本"
curl -fsSL --retry 3 https://raw.githubusercontent.com/yinyues2/NodeQuality/hermes-fixed/extras/run_nq_full.sh -o /root/run_nq_full.sh \
  || die "run_nq_full.sh 下载失败（检查 GitHub 可达性）"
chmod +x /root/run_nq_full.sh

log "后台启动（深度全量，约 20–40 分钟；用 systemd-run 免断线）"
systemctl reset-failed nq-bench 2>/dev/null || true
systemd-run --unit=nq-bench --collect --setenv=TERM=xterm-256color bash /root/run_nq_full.sh "$BENCH" >/dev/null 2>&1
sleep 20
ok "状态: $(systemctl is-active nq-bench)"
log "进度"; cat "$BENCH/status.log" 2>/dev/null || true
cat <<EOF

  跟踪：  journalctl -u nq-bench -f
  状态：  cat $BENCH/status.log
  完成标志：$BENCH/.done 出现，日志里有 nodequality.com/r/xxxx 与 Report.Check.Place/*.svg
  取结果：grep -aoE 'https://nodequality\\.com/r/[A-Za-z0-9_-]+' $BENCH/nq.log | tail -1
EOF
