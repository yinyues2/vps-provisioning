---
name: vps-provisioning
description: "Use when provisioning/hardening a new VPS."
version: 1.0.0
author: Hermes Agent (yinyues2)
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [vps, provisioning, hardening, sshd, nftables, fail2ban, tcp-tuning, benchmark, nodequality, tcpquality]
    related_skills: [vps-security-baseline, vps-tcp-tuning, proxy-route-verification, deployment-artifact-verification]
---

# 新机开荒（一条命令 / 可复现 / 带实测验收）

## 何时用

- 用户说「新买了台服务器 / 新机开荒 / 帮我做安全设置和调优 / 跑一遍 NQ 和 TQ」。
- 需要给一台已有机器补齐机队标准基线（只跑对应分脚本）。
- 与 `vps-security-baseline`（判据与机队差异）、`vps-tcp-tuning`（TCP 方法论原文）配合：本技能是**可执行的那一份**。

## 权威仓库（脚本与全文在这里）

```
https://github.com/yinyues2/vps-provisioning
```

机上一键：

```bash
git clone https://github.com/yinyues2/vps-provisioning.git /root/vps-provisioning
cd /root/vps-provisioning && cp env.example.sh env.sh && vi env.sh
sudo ./scripts/00-run-all.sh            # 1 快照 2 SSH双口 3 nft 4 sysctl 5 f2b 6 uu 7 审计 8 关v6 9 TCP
```

之后必须手动：**外部验证新端口 ≥2 次 → `02 --stage final` 撤 22 → 白名单三向验证 → 拆回滚保险 → 重启复核 → NQ/TQ**。

## 流程（脚本 → 产出 → 验收口径）

| 步 | 脚本 | 验收（实测，不看配置文件） |
|---|---|---|
| 1 | `01-snapshot.sh` | `/root/pre-harden-YYYYMMDD/` ~1.5MB；记下端口集合作回归基线 |
| 2 | `02-ssh-harden.sh --stage dual` | `sshd -T` 逐项 + 外部登录 ≥2；drop-in 必须 `00-` 前缀 |
| 3 | `03-nft-ssh-whitelist.sh apply` | 白名单内通 / 名单外超时 / v6 差分（控制组 `[v6]:22` REFUSED） |
| 4 | `04-sysctl-harden.sh` | 26 项 `sysctl -n` = `1 2 1 2 1 1 2 2 0` … |
| 5 | `05-fail2ban.sh` | `fail2ban-client status` 名字里有 sshd + recidive |
| 6 | `06-auto-update-journald.sh` | uu active、`journalctl --disk-usage`、待装补丁数 |
| 7 | `07-audit.sh` | uid0 / 空密码 / SUID 清单 / 世界可写 |
| 8 | `08-disable-ipv6.sh` | 4 项 disable_ipv6=1、`/proc/net/if_inet6` 全局=0 |
| 9 | `09-tcp-tuning.sh` | 缓冲/BDP、backlog、initcwnd 32、qdisc fq、THP madvise |
| 10 | `10-verify.sh` | 重启后再跑一遍，全部自恢复 |
| 11 | `11-bench-nq.sh` | NQ 修补版 `v/y/y/y` → `nodequality.com/r/...` |
| 12 | `12-bench-tq.sh` | TQ `--all` → `tcpquality.ibsgss.uk/r/...` |

## 铁律（细节全文见仓库 README）

1. 改 sshd：备份 → `sshd -t` → 武装 900s 回滚 → reload → **外部验证 ≥2 次** → 拆保险。
2. 撤 22 前必须双端口并存 + 外部探测新端口可达；安全组挡住的保留 22 只报告。
3. 防火墙只锁 SSH 端口，**默认策略保持 accept**；有 docker 时不许整表 `flush` 重写。
4. 不跑全量升级（只配自动安全更新）；不自动重启内核升级。
5. sysctl 一律用实测值验收；容器 EPERM 的键跳过记录。
6. IPv6 默认关闭；关前确认 SSH 走 v4、无节点引用该 v6。
7. 无增益就说无增益：调优必须给同端点同参数的改前/改后两列。

## 两个必记前缀坑

- SSH drop-in **必须 `00-`**：`50-cloud-init.conf` 会压过 `99-`（OpenSSH 取首个值）。
- sysctl 调优文件 **必须 `zz-`**：镜像的 `/etc/sysctl.d/local.conf` 字典序在 `99-*` 之后，会把 99- 文件的同名项盖回去且**不报错**。

## 其它实测坑

`[recidive]` 必须写 `backend=auto` + `logpath`；`[sshd]` 段必须带 `backend`；THP 不会自动持久（要进 oneshot 重放）；TQ 无 `TERM` 直接 exit 1；公共 iperf3 端点常 busy（换端口但 A/B 必须同端点）；`ip route change` 的定时回滚漏取消会静默回滚 initcwnd；NQ 的「国内测速」ERROR 是脚本节点问题，不等于机器慢。

## 交付物

`/root/99-security-profile.md`、`/root/99-tune-profile.md`（模板在仓库 `templates/`）、`/root/suid-list.txt`、`/root/pre-harden-*/`、NQ/TQ 报告链接、云端 `<host>-YYYYMMDD/SUMMARY.md`。

## 案例

`cases/example-tokyo-relay/`：东京 1 Gbps 中转机**脱敏**示例（单流下行 377→740、上行 341→747 Mbps；NQ 全解锁原生 JP、三网 CTGGIA/9929/CMIN2；TQ IPv4 回程 93/93 零丢包）。真实 IP / 主机名 / 报告链接均已替换为文档示例地址。
