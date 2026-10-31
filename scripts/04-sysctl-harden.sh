#!/bin/bash
# 04-sysctl-harden.sh — 内核/网络加固（99-zz- 字典序最后，压得住供应商文件）
set -uo pipefail
. "$(dirname "$0")/lib.sh"
[ "$(id -u)" -eq 0 ] || die "需要 root"

F=/etc/sysctl.d/99-zz-hermes-hardening.conf
log "写入 $F"
cat > "$F" <<'EOF'
# Hermes 安全基线（内核 + 网络）
# 注意：文件名必须是 99-zz-*（字典序最后），否则会被 50-*.conf / 99-sysctl.conf / local.conf 覆盖
# ---- 内核 ----
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
kernel.randomize_va_space = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
# ---- 网络 ----
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
# 不设 ip_forward=0（中转要转发）、不设 unprivileged_bpf_disabled（会打断 docker）、不开 log_martians（日志噪音）
EOF
chmod 644 "$F"

sysctl --system >/dev/null 2>&1 || warn "sysctl --system 有报错（容器里 EPERM 属正常），继续逐项核对"
log "实测值（应为 1 2 1 2 1 1 2 2 0）"
sysvals kernel.dmesg_restrict kernel.kptr_restrict kernel.yama.ptrace_scope kernel.randomize_va_space \
        fs.protected_hardlinks fs.protected_symlinks fs.protected_fifos fs.protected_regular fs.suid_dumpable
log "网络（应为 1 1 0 0 0 0 0）"
sysvals net.ipv4.tcp_rfc1337 net.ipv4.conf.all.rp_filter net.ipv4.conf.all.accept_redirects \
        net.ipv4.conf.all.send_redirects net.ipv4.conf.all.accept_source_route \
        net.ipv4.conf.all.secure_redirects net.ipv6.conf.all.accept_redirects
warn "若某项不是期望值：用 sysctl --system 的输出查是哪个文件最后加载覆盖了它（常见 local.conf / 99-sysctl.conf）"
