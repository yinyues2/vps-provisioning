#!/bin/bash
# 07-audit.sh — 账号/密钥/权限审计（只读 + 收紧明显过宽的密钥文件权限）
set -uo pipefail
. "$(dirname "$0")/lib.sh"
[ "$(id -u)" -eq 0 ] || die "需要 root"

log "uid0 账户"; awk -F: '$3==0{print $1}' /etc/passwd
log "空密码账户"; awk -F: '$2==""{print $1}' /etc/shadow
log "root 密码状态（L=锁定）"; passwd -S root 2>/dev/null

log "收紧密钥文件权限"
find /root /home -maxdepth 3 -name authorized_keys -exec chmod 600 {} \; 2>/dev/null || true
find /root /home -maxdepth 3 -name "id_*" ! -name "*.pub" -exec chmod 600 {} \; 2>/dev/null || true
chmod 700 /root/.ssh 2>/dev/null || true
ls -ld /root/.ssh; ls -l /root/.ssh/authorized_keys 2>/dev/null
ls -l /etc/ssh/sshd_config.d/

log "SUID 清单"
find / -xdev -perm -4000 -type f 2>/dev/null > /root/suid-list.txt
ok "$(wc -l < /root/suid-list.txt) 个 → /root/suid-list.txt"

log "世界可写目录（排除 tmp/proc/sys/dev/run/lock，空=正常）"
find / -xdev -type d -perm -0002 ! -path "/tmp*" ! -path "/var/tmp*" ! -path "/proc*" \
  ! -path "/sys*" ! -path "/dev*" ! -path "/run*" ! -path "/var/lock*" 2>/dev/null | head -10

log "sudoers NOPASSWD"
grep -rn "NOPASSWD" /etc/sudoers /etc/sudoers.d/ 2>/dev/null || echo "无 NOPASSWD"

log "docker.sock（应为 srw-rw---- root docker）"
ls -l /var/run/docker.sock 2>/dev/null || echo "no docker.sock"

log "世界可读的敏感文件（.env / *.key / *.pem）"
grep -rIl --include=".env*" --include="*.key" --include="*.pem" /root /etc 2>/dev/null | while read -r f; do
  m=$(stat -c '%a' "$f"); echo "$m $f"
done | head -20
warn "上面若有 4/6/7 开头（组或其他可读）的，手动 chmod 600（属主不变）"
