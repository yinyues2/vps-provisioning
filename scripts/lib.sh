#!/bin/bash
# 公共库：加载配置 + 通用函数。所有脚本 `source` 本文件。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/.." && pwd)"

if [ -f "$ROOT_DIR/env.sh" ]; then
  # shellcheck disable=SC1091
  . "$ROOT_DIR/env.sh"
elif [ -f "$ROOT_DIR/env.example.sh" ]; then
  echo "[!] 未找到 env.sh，临时使用 env.example.sh（请先 cp env.example.sh env.sh 并填写）"
  # shellcheck disable=SC1091
  . "$ROOT_DIR/env.example.sh"
else
  echo "[X] 缺少 env.sh"; exit 1
fi

STAMP="${STAMP:-$(date +%Y%m%d)}"
SNAP_DIR="${SNAP_DIR:-/root/pre-harden-$STAMP}"
IFACE="${IFACE:-$(ip route show default | awk '{print $5; exit}')}"
GATEWAY="${GATEWAY:-$(ip route show default | awk '{print $3; exit}')}"

log()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*"; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "需要 root 执行"; }

# 武装一个定时回滚：guard <秒> <unit名> <命令>
guard() {
  local secs="$1" unit="$2" cmd="$3"
  systemctl reset-failed "$unit" 2>/dev/null || true
  systemd-run --on-active="$secs" --unit="$unit" /bin/sh -c "$cmd" >/dev/null 2>&1 \
    && ok "已武装 ${secs}s 回滚：$unit" || warn "回滚武装失败（继续，但请手动留后路）"
}
unguard() {
  local unit="$1"
  systemctl stop "$unit.timer" 2>/dev/null || true
  systemctl reset-failed "$unit" 2>/dev/null || true
  ok "已拆除回滚 $unit（剩余 rollback timer: $(systemctl list-timers --all 2>/dev/null | grep -c rollback)）"
}

# 打印 sysctl 实测值（空格分隔）
sysvals() { sysctl -n "$@" 2>/dev/null | tr '\n' ' '; echo; }
