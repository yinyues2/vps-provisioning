#!/bin/bash
# 06-auto-update-journald.sh — 只自动装安全更新（不自动重启）+ journald 持久化限额
set -uo pipefail
. "$(dirname "$0")/lib.sh"
[ "$(id -u)" -eq 0 ] || die "需要 root"
export DEBIAN_FRONTEND=noninteractive

log "安装 unattended-upgrades"
apt-get update -qq
apt-get install -y -qq unattended-upgrades >/dev/null 2>&1 || apt-get install -y unattended-upgrades

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat > /etc/apt/apt.conf.d/51-hermes-uu.conf <<'EOF'
// Hermes：只自动装安全更新，不自动重启（重启由人工决定）
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}";
        "${distro_id}:${distro_codename}-security";
        "${distro_id}ESMApps:${distro_codename}-apps-security";
        "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::MinimalSteps "true";
EOF

systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
ok "uu：$(systemctl is-enabled unattended-upgrades)/$(systemctl is-active unattended-upgrades)"
log "dry-run（无输出=当前无需升级）"; unattended-upgrade --dry-run 2>&1 | tail -3

log "journald 持久化 + 500M 上限"
J=/etc/systemd/journald.conf
sed -i 's/^#\?Storage=.*/Storage=persistent/' "$J"
if grep -q '^SystemMaxUse=' "$J"; then sed -i 's/^SystemMaxUse=.*/SystemMaxUse=500M/' "$J"; else echo "SystemMaxUse=500M" >> "$J"; fi
systemctl restart systemd-journald && sleep 1
grep -E '^(Storage|SystemMaxUse)' "$J"
ok "$(journalctl --disk-usage)"
log "待装补丁数（0=已最新）"; apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true
warn "本流程不做全量升级；如需打补丁请单独决定窗口（内核升级后需重启才生效）"
