#!/bin/bash
# 00-run-all.sh — 串行跑完开荒流程（需要人工卡点的地方会停下来提示）
#   --yes       跳过开头的确认
#   --to N      只跑到第 N 步（1..9）
set -uo pipefail
. "$(dirname "$0")/lib.sh"
[ "$(id -u)" -eq 0 ] || die "需要 root"

TO="${2:-99}"
[ "${1:-}" = "--to" ] && TO="${2:-99}"
[ "${1:-}" = "--yes" ] || {
  cat <<EOF

  即将对这台机器执行开荒：
    SSH 端口      : $SSH_PORT
    白名单 v4     : $SSH_ALLOW_V4
    白名单 v6     : $SSH_ALLOW_V6
    网卡 / 网关   : ${IFACE:-自动} / ${GATEWAY:-自动}
    BDP 参数      : ${BW_MBPS} Mbps × ${RTT_MAX_MS} ms
    关闭 IPv6     : ${DISABLE_IPV6}
    快照目录      : $SNAP_DIR

  流程：快照 → SSH(双口) → nft → sysctl → fail2ban → 自动更新 → 审计 → 关 v6 → TCP 调优
  之后需要你手动做：从另一台机器验证新端口 → 撤 22 → 三向验证白名单 → 重启复核 → NQ/TQ

EOF
  read -r -p "  继续？[y/N] " a; [ "$a" = "y" ] || exit 1
}

step=0
run() { step=$((step+1)); [ "$step" -le "$TO" ] || return 0; log "步骤 $step：$1"; shift; "$@" || warn "步骤 $step 返回非 0，继续（请检查上面输出）"; }

run "快照"                 bash "$HERE/01-snapshot.sh"
run "SSH 加固(双端口)"      bash "$HERE/02-ssh-harden.sh" --stage dual
run "防火墙白名单"          bash "$HERE/03-nft-ssh-whitelist.sh" apply
run "内核加固"              bash "$HERE/04-sysctl-harden.sh"
run "fail2ban"             bash "$HERE/05-fail2ban.sh"
run "自动更新 + journald"   bash "$HERE/06-auto-update-journald.sh"
run "权限审计"              bash "$HERE/07-audit.sh"
[ "$DISABLE_IPV6" = "1" ] && run "关闭 IPv6" bash "$HERE/08-disable-ipv6.sh"
run "TCP 调优"              bash "$HERE/09-tcp-tuning.sh"

cat <<EOF

  ---------------- 人工卡点（必须做，别跳） ----------------
  1) 从另一台白名单机器验证新端口（连续 2 次）：
       ssh -p $SSH_PORT root@<本机公网IP> 'hostname'
  2) 通过后撤 22：  bash $HERE/02-ssh-harden.sh --stage final
  3) 白名单三向验证 + IPv6 差分验证（见 README 3.3）
  4) 全部通过后拆保险：
       systemctl stop sec-rollback.timer fw-rollback.timer route-rollback.timer v6-rollback.timer
  5) 重启复核：     reboot  然后  bash $HERE/10-verify.sh
  6) 完整测评：     bash $HERE/11-bench-nq.sh ; bash $HERE/12-bench-tq.sh
  7) 落档：把 templates/ 下两份档案填好放 /root/

EOF
