# <host> 安全档案 — <日期>

机器：**<公网IP>**（hostname `<host>`，<服务商/机房>）／<OS>／内核 <uname -r>／<虚拟化>／<CPU>／<内存>／<磁盘>／<端口带宽>
角色：<中转 / 落地 / Web>，对外只暴露 SSH **<端口>**。

## 一、SSH

| 项 | 改前 | 改后 |
|---|---|---|
| 端口 | 22 | **<端口>**（22 已撤） |
| PermitRootLogin | | prohibit-password |
| PasswordAuthentication | | no |
| MaxAuthTries / LoginGraceTime | | 3 / 30 |
| X11Forwarding / AllowAgentForwarding | | no / no |
| root 密码 | | 锁定（`passwd -S root` = L） |

配置落点 `/etc/ssh/sshd_config.d/00-hermes-hardening.conf`（必须 `00-` 前缀）；改前备份 `/root/pre-harden-<日期>/etc/ssh/`。
迁移过程：双端口并存 → 外部验证 ×2 → 撤 22 → 外部探测 22 = refused。

## 二、nftables SSH 白名单

（贴 `/etc/nftables.conf` 全文 + 四项实测结果：白名单内 ×2 通 / 名单外被丢 / IPv6 差分）

## 三、fail2ban

（贴 `jail.d/zz-hermes.local` 全文 + `fail2ban-client status` 输出：sshd + recidive）

## 四、补丁与自动更新

待装补丁 <N> 个；unattended-upgrades 仅 security 源、不自动重启。

## 五、内核加固

（列出 sysctl 文件路径 + 实测值）

## 六、日志与审计

journald persistent + 500M；uid0；空密码；SUID 数量；世界可写目录；sudoers NOPASSWD；docker.sock。

## 七、失联恢复

面板 VNC → `nft flush ruleset`（默认策略 accept）；临时放行 `nft add rule inet filter input ip saddr <新IP> tcp dport <端口> accept`；`passwd root` 恢复密码（公钥不受影响）。

## 八、回滚

```bash
rm -f /etc/ssh/sshd_config.d/00-hermes-hardening.conf && systemctl reload ssh
systemctl disable --now nftables && nft flush ruleset
rm -f /etc/sysctl.d/99-zz-hermes-hardening.conf && sysctl --system
rm -f /etc/fail2ban/jail.d/zz-hermes.local && systemctl restart fail2ban
```
