#!/bin/bash
# 02-ssh-harden.sh — SSH 加固 + 高位端口迁移（两阶段）
#   --stage dual   22 与新端口并存（先跑这个）
#   --stage final  撤掉 22，只留新端口（外部验证通过后再跑）
#   --stage check  只打印当前有效配置（只读，非 root 也能跑 sshd -T 的部分）
#
# 关键点（两次实测踩过）：
#   1) sshd 对同一指令取「首个出现的值」；主配置顶部有 Include sshd_config.d/*.conf 时，
#      字典序早于我们文件的供应商 drop-in（00-jcloud.conf / 50-cloud-init.conf / 01-…）
#      会静默压过我们的 00-hermes-hardening.conf —— 只写自己的文件不够，必须就地改写它们的值。
#   2) 只 `sshd -T | grep` 打印不算验收；值不对必须回滚并 die，否则会留下「以为加固了」的机器。
#   3) 只装包/只改配置不 reload，跑着的老进程仍是旧策略 —— 一律 reload 后用 sshd -T 复核。
set -uo pipefail
. "$(dirname "$0")/lib.sh"
[ "$(id -u)" -eq 0 ] || die "需要 root"

STAGE=dual
while [ $# -gt 0 ]; do
  case "$1" in
    --stage)   STAGE="${2:-dual}"; shift 2 ;;
    --stage=*) STAGE="${1#*=}"; shift ;;
    dual|final|check) STAGE="$1"; shift ;;
    *) die "未知参数：$1（用法：--stage dual|final|check）" ;;
  esac
done

CONF=/etc/ssh/sshd_config.d/00-hermes-hardening.conf
MAIN=/etc/ssh/sshd_config
DDIR=/etc/ssh/sshd_config.d
BACKUP="/root/sshd.bak-$STAMP"

# ---- 统一改写主配置与所有 drop-in 里的认证相关指令 ----
sanitize_sshd_values() {
  local files=("$MAIN") f
  for f in "$DDIR"/*.conf; do [ -f "$f" ] && files+=("$f"); done
  for f in "${files[@]}"; do
    grep -qE '^[[:space:]]*(PasswordAuthentication|PermitRootLogin|KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]]' "$f" || continue
    sed -i -E \
      -e 's/^[[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication no/' \
      -e 's/^[[:space:]]*PermitRootLogin[[:space:]].*/PermitRootLogin prohibit-password/' \
      -e 's/^[[:space:]]*KbdInteractiveAuthentication[[:space:]].*/KbdInteractiveAuthentication no/' \
      -e 's/^[[:space:]]*ChallengeResponseAuthentication[[:space:]].*/ChallengeResponseAuthentication no/' \
      "$f"
    ok "已改写 $f"
  done
}

# ---- 硬断言：生效值必须真的落地（不靠 grep 配置文件）----
assert_effective() {
  local pw root kbd
  pw=$(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')
  kbd=$(sshd -T 2>/dev/null | awk '/^kbdinteractiveauthentication/{print $2}')
  root=$(sshd -T 2>/dev/null | awk '/^permitrootlogin/{print $2}')
  printf '  实测：passwordauthentication=%s kbdinteractive=%s permitrootlogin=%s\n' "${pw:-?}" "${kbd:-?}" "${root:-?}"
  [ "$pw" = "no" ] || { warn "passwordauthentication 生效值不是 no（谁来压过了加固文件？）"; return 1; }
  [ "$kbd" = "no" ] || { warn "kbdinteractiveauthentication 生效值不是 no"; return 1; }
  case "$root" in without-password|prohibit-password) ;; *) warn "permitrootlogin 生效值异常：$root"; return 1 ;; esac
  return 0
}

# ---- 生效值不对：还原 /etc/ssh 并 reload，然后退出 ----
restore_and_die() {
  warn "$1 —— 还原 /etc/ssh 备份并 reload"
  cp -a "$BACKUP/sshd_config" "$MAIN" 2>/dev/null
  [ -d "$BACKUP/sshd_config.d" ] && { rm -rf "$DDIR"; cp -a "$BACKUP/sshd_config.d" "$DDIR"; }
  sshd -t && systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
  die "已回滚（备份 $BACKUP）"
}

case "$STAGE" in
check)
  log "当前有效 sshd 配置"
  sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|permitemptypasswords|maxauthtries|logingracetime|x11forwarding|allowagentforwarding|maxsessions|clientaliveinterval)' || die "sshd -T 失败"
  log "监听端口"; ss -ltn | awk 'NR>1{print $4}' | sort -u
  log "drop-in（字典序前的会赢）"; ls -1 "$DDIR"/*.conf 2>/dev/null | while read -r f; do printf '  %s: ' "$(basename "$f")"; grep -hE '^[[:space:]]*(PasswordAuthentication|PermitRootLogin)' "$f" | tr '\n' ' '; echo; done
  exit 0 ;;

dual)
  log "阶段 1/2：双端口并存（22 + $SSH_PORT）"
  mkdir -p "$BACKUP"; cp -a /etc/ssh/. "$BACKUP"/ && ok "已备份 /etc/ssh → $BACKUP"

  # 供应商 drop-in 与主配置一起改写（否则字典序靠前的文件会赢）
  sanitize_sshd_values

  if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d' "$MAIN"; then
    cat > "$CONF" <<EOF
# Hermes 安全基线（$(date +%F)）。文件名必须 00- 前缀：OpenSSH 取「首个出现的值」，
# 且供应商 drop-in 的值已被本脚本就地改写，双保险。
# 注意：只要出现任一 Port 行，22 就不再是隐含端口 —— 双端口阶段显式写两条。
Port 22
Port $SSH_PORT
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
MaxSessions 10
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding yes
GatewayPorts no
ClientAliveInterval 300
ClientAliveCountMax 2
UseDNS no
EOF
    chmod 600 "$CONF"
    ok "已写 $CONF"
  else
    warn "主配置没有 Include sshd_config.d → drop-in 不会被读，已直接改写主配置（高危端口未迁移）"
  fi

  sshd -t || { warn "sshd -t 失败，还原"; restore_and_die "配置校验失败"; }
  ok "sshd -t 通过"
  guard 900 sec-rollback "cp -a $BACKUP/sshd_config $MAIN; rm -rf $DDIR; cp -a $BACKUP/sshd_config.d $DDIR; sshd -t && systemctl reload ssh"
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
  sleep 2

  log "生效值（实测）"; sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|maxauthtries|x11forwarding|allowagentforwarding)' || true
  log "监听端口"; ss -ltn | awk 'NR>1{print $4}' | sort -u
  assert_effective || restore_and_die "加固未生效"
  ok "断言通过：密码登录已关闭、root 仅密钥"
  warn "现在必须从另一台机器验证：ssh -p $SSH_PORT root@<本机公网IP> 'hostname'（连续 2 次）"
  warn "验证通过后再执行：$0 --stage final" ;;

final)
  log "阶段 2/2：撤掉 22，只留 $SSH_PORT"
  [ -f "$CONF" ] || die "找不到 $CONF，先跑 --stage dual"
  ss -ltn | grep -q ":$SSH_PORT" || die "新端口 $SSH_PORT 未在监听，拒绝撤 22"
  mkdir -p "$BACKUP"; cp -a /etc/ssh/. "$BACKUP"/ 2>/dev/null
  sed -i '/^Port 22$/d' "$CONF"
  sshd -t || die "sshd -t 失败（未改动）"
  guard 900 sec-rollback "cp -a $BACKUP/sshd_config $MAIN; rm -rf $DDIR; cp -a $BACKUP/sshd_config.d $DDIR; sshd -t && systemctl reload ssh"
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
  sleep 2
  log "生效端口：$(sshd -T | grep -E '^port' | tr '\n' ' ')"
  ok "监听：$(ss -ltn | awk 'NR>1{print $4}' | sort -u | tr '\n' ' ')"
  assert_effective || restore_and_die "撤 22 后生效值异常"
  warn "外部探测 22 应为 Connection refused；新端口应可登录。确认后再拆保险："
  warn "  systemctl stop sec-rollback.timer" ;;

*) die "未知 stage: $STAGE（dual|final|check）" ;;
esac
