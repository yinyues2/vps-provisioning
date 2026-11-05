# VPS 新机开荒手册（Hermes 机队标准）

> 一套可复现的 Linux 新机开荒流程：**安全基线 → SSH 高位端口迁移 → 防火墙白名单 → 内核加固 → 自动更新 → TCP 调优 → 完整测评（NQ + TQ）**。
> 实战验证：东京 1 Gbps 中转机（Debian 13 / 2C / 3.8G）与德国中转机，以及一次七台机器整机队加固；数值见 `cases/`。
> 目标：**一台新机从「刚付钱拿到 root」到「可交付的中转/落地机」，一条命令跑完，且每一步都有实测证据与回滚路径。**

---

## 0. 一句话用法

```bash
git clone https://github.com/yinyues2/vps-provisioning.git && cd vps-provisioning
cp env.example.sh env.sh && vi env.sh      # 填 SSH_PORT / 白名单 / 带宽 / RTT
sudo ./scripts/00-run-all.sh                # 全自动（每段结束打印实测值）
# 或者分段执行：
sudo ./scripts/01-snapshot.sh
sudo ./scripts/02-ssh-harden.sh --stage dual     # 先双端口并存
sudo ./scripts/02-ssh-harden.sh --stage final    # 外部验证通过后再撤 22
...
```

**Hermes 里的一句话触发**：`skill_view(name='vps-provisioning')` → 按 SKILL.md 执行；或直接说「用 vps-provisioning 给这台新机开荒：IP=x.x.x.x 端口=22」。

---

## 1. 铁律（违反就是砸机器）

1. **改 sshd 顺序固定**：备份 → `sshd -t` → **先武装 900s 自动回滚** → reload → **从另一台机器新建连接验证 ≥2 次** → 才拆保险。只确认「当前会话还活着」不算验证。
2. **撤 22 之前必须先双端口并存**，并从外部（另一台机器）探测新端口可达；云厂商安全组挡住的，保留 22 并写「需控制台放行」，**不要删 22**。
3. **默认不改防火墙默认策略**（`policy accept` 保持），只锁 SSH 端口；否则会连坐业务端口。
4. **不碰 docker 的 nft/iptables 表**；机器上有 docker 时不要 `flush ruleset` 式整表重写。
5. **不跑全量升级**除非用户明确同意（本手册只配置「自动安全更新」，补丁窗口归人决定）。内核包升级后**不自动重启**，只记录「待重启生效」。
6. **不重启业务服务**（Hermes gateway/dashboard、sing-box、nginx/php、容器）；整轮只动 sshd。
7. **sysctl 用实测值验收**（`sysctl -n` / `/proc`），不看配置文件内容；容器里 EPERM 的键跳过并记录。
8. **IPv6 默认关闭**（机队标准）：先确认自己的 SSH 走 v4，再关；关之前确认没有节点/订阅引用该 v6 地址。
9. **每台机留三样东西**：改前快照目录、`99-security-profile.md`、`99-tune-profile.md`，外加失联恢复路径（面板 VNC）。
10. **无增益就说无增益**：调优报告必须给同端点、同参数的改前/改后两列，噪声不许包装成优化。

---

## 2. 阶段总览

| 阶段 | 脚本 | 产出 | 验收（实测） |
|---|---|---|---|
| 0 快照 + 盘点 | `01-snapshot.sh` | `/root/pre-harden-YYYYMMDD/`（~1.5MB） | `du -sh`、端口集合 |
| 1 SSH 加固 + 高位端口 | `02-ssh-harden.sh` | `00-hermes-hardening.conf` | `sshd -T` 逐项 + 外部登录 ≥2 |
| 2 防火墙白名单 | `03-nft-ssh-whitelist.sh` | `/etc/nftables.conf` | 白名单内通 / 名单外被丢 / v6 差分 |
| 3 内核加固 | `04-sysctl-harden.sh` | `99-zz-hermes-hardening.conf` | 26 项 `sysctl -n` |
| 4 fail2ban | `05-fail2ban.sh` | `jail.d/zz-hermes.local` | `fail2ban-client status` = 2 jail |
| 5 自动更新 + 日志 | `06-auto-update-journald.sh` | `51-hermes-uu.conf`、journald 500M | `systemctl is-active`、`journalctl --disk-usage` |
| 6 权限审计 | `07-audit.sh` | `/root/suid-list.txt` | uid0 / 空密码 / SUID / 世界可写 |
| 7 关 IPv6 | `08-disable-ipv6.sh` | `99-disable-ipv6.conf` | `disable_ipv6=1` ×4、全局 v6 = 0 |
| 8 TCP 调优 | `09-tcp-tuning.sh` | `zz-hermes-tcp-tuning.conf` + oneshot | 缓冲/backlog/initcwnd + A/B |
| 9 总验收 | `10-verify.sh` | 控制台报告 | 端口集合前后一致、服务存活 |
| 10 测评 | `11-bench-nq.sh` / `12-bench-tq.sh` | NQ/TQ 报告链接 | 两组报告都拿到 URL |
| 回滚 | `99-rollback.sh` | — | 逐项可回 |

---

## 3. 各阶段细节（含本次实测值，作为参照基准）

### 3.1 快照（`01-snapshot.sh`）

抓：`/etc/ssh`、`/etc/fail2ban`、`/etc/sysctl.d`、`/etc/fstab`、`/etc/nftables.conf`、`journald.conf`、`iptables-save`、`nft list ruleset`、`sysctl -a`、`tc qdisc`、`ip route`、`ip -6 route`、`ss -ltnup`、运行中的 unit、`dpkg --get-selections`、`/root/.ssh`。
**端口集合是后续回归基线**：加固前后必须完全一致（除了我们自己撤掉的 22/加的新端口）。

### 3.2 SSH 加固 + 高位端口（`02-ssh-harden.sh`）

写 `/etc/ssh/sshd_config.d/00-hermes-hardening.conf`：

```
Port 22
Port 52222
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
```

**必须 `00-` 前缀**：OpenSSH 取「首个出现的值」，镜像自带的 `50-cloud-init.conf`（常写 `PasswordAuthentication no`，但 cloud-init 重推会变）与 `50-*.conf` 会压过 `99-` 前缀的文件。

**只写自己的 00- 文件还不够**（2026-11-05 补）：字典序早于 `00-hermes-hardening.conf` 的供应商文件（实测 `00-jcloud.conf`、`01-passwordauthentication.conf`）照样会赢，而且不报错。脚本现在会：

1. 就地改写**主配置 + 所有 drop-in** 里的 `PasswordAuthentication` / `PermitRootLogin` / `KbdInteractiveAuthentication` / `ChallengeResponseAuthentication`（先整目录备份 `/root/sshd.bak-<date>`）；
2. reload 后跑**硬断言**：`sshd -T` 必须是 `passwordauthentication no` + `kbdinteractiveauthentication no` + `permitrootlogin without-password`，任一不符 → 还原 `/etc/ssh` + reload + 退出非 0（不留「以为加固了」的机器）；
3. 主配置没有 `Include sshd_config.d` 时（阿里云 Linux 8 这类），直接改主配置并告警——drop-in 写了也不会被读。

`--stage final` 只做一件事：删掉 `Port 22` 行 + reload + 外部探测 22 应为 `Connection refused`（同样带断言）。

**实测**：`port 52222`、`permitrootlogin without-password`、`passwordauthentication no`、`maxauthtries 3`、`x11forwarding no`、`allowagentforwarding no`；云端/性能机各两次登录成功；22 外部探测 refused。

### 3.3 防火墙 SSH 白名单（`03-nft-ssh-whitelist.sh`）

```
table inet filter {
    set ssh_allow_v4 { type ipv4_addr; flags interval; elements = { 203.0.113.10, 203.0.113.20, 100.64.0.0/10 } }
    set ssh_allow_v6 { type ipv6_addr; flags interval; elements = { fd7a:115c:a1e0::/48 } }
    chain input {
        type filter hook input priority filter; policy accept;
        iif lo accept
        ct state established,related accept
        ip  saddr @ssh_allow_v4 tcp dport 52222 accept
        ip6 saddr @ssh_allow_v6 tcp dport 52222 accept
        tcp dport 52222 drop
    }
}
```

- `drop` 不用 `reject`：扫描器看不到 RST。
- 落盘 `/etc/nftables.conf`（首行 `flush ruleset`）+ `nft -c -f` 预检 + `systemctl enable --now nftables`。
- **注意**：`flush ruleset` 在开机时执行一次；fail2ban（banaction=nftables）在其后启动，顺序无冲突，但**运行中 restart nftables 会清掉 fail2ban 的临时封禁表**，之后要 `fail2ban-client reload`。
- **三向验证**：白名单内两台机器都能连；名单外第三台机器 TCP 探测必须超时。
- **IPv6 差分验证**（机队里多数机器没有 v6，`/dev/tcp` 会报 `Address family not supported`，那是探针机的问题）：用一个「确定没有监听」的端口做控制组，例如 `[v6]:22`。控制组返回 `REFUSED` = v6 入站路由通、包到达主机；此时实验组 `[v6]:52222` 超时 = nft drop 真实生效。只有「超时」一条无法区分「规则生效」与「v6 没路由」。

**实测**：云端 ✓、性能机 ✓、西班牙机 v4 被丢 ✓、InstaBox（AWS 俄勒冈双栈）`[v6]:22` REFUSED / `[v6]:52222` 超时 ✓。

### 3.4 内核加固（`04-sysctl-harden.sh`）

文件 `/etc/sysctl.d/99-zz-hermes-hardening.conf`（**`99-zz-` 后缀**：字典序要压过镜像自带的 `50-*.conf`、`99-sysctl.conf`、`local.conf`）：

```
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
kernel.randomize_va_space = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
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
```

**不设**：`net.ipv4.ip_forward=0`（中转要转发）、`kernel.unprivileged_bpf_disabled=1`（打断 docker 工具链）、`log_martians`（日志噪音）。
**实测验收值**：`1 2 1 2 1 1 2 2 0` + `rp_filter=1` + `accept_redirects=0`。

### 3.5 fail2ban（`05-fail2ban.sh`）

`/etc/fail2ban/jail.d/zz-hermes.local`：

```
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 203.0.113.10 203.0.113.20 100.64.0.0/10
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 4
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w

[sshd]
enabled = true
mode = aggressive
port = 52222

[recidive]
enabled = true
backend = auto
logpath = /var/log/fail2ban.log
```

- **只要写了 `[sshd]` 段就必须带 `backend`**，否则本地覆盖会把自动探测打回 `polling`，把已经跑着的 fail2ban 弄成 failed。
- `[recidive]` **必须显式 `backend = auto` + `logpath`**：`[DEFAULT] backend = systemd` 下它没有 journalmatch，会静默不启动。
- 验收口径 = `fail2ban-client status` 的 jail 名字里有 `sshd` 和 `recidive`，不是「有几个 jail」。

### 3.6 自动安全更新 + 日志（`06-auto-update-journald.sh`）

- `apt-get install -y unattended-upgrades`
- `/etc/apt/apt.conf.d/20auto-upgrades`：Update-Package-Lists=1、Unattended-Upgrade=1、AutocleanInterval=7
- `/etc/apt/apt.conf.d/51-hermes-uu.conf`：只留 `${distro_codename}` 与 `-security`、`Automatic-Reboot false`、`Remove-Unused-Dependencies true`、`MinimalSteps true`
- journald：`Storage=persistent` + `SystemMaxUse=500M`，重启 `systemd-journald`

### 3.7 权限审计（`07-audit.sh`）

uid0 账户、空密码账户、`passwd -S root`、`authorized_keys`/私钥权限、SUID 清单→`/root/suid-list.txt`、世界可写目录、sudoers 的 NOPASSWD、docker.sock 权限。
**实测**：uid0 仅 root、无空密码、root 密码 `L`、SUID 11 个、无世界可写目录、无 NOPASSWD、无 docker。

### 3.8 关 IPv6（`08-disable-ipv6.sh`）

```
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv6.conf.eth0.disable_ipv6 = 1      # 每个实际网卡各一行，只写 all 在部分内核上不生效
```

- 关之前：确认 SSH 走 v4（`SSH_CONNECTION` 第一段不含 `:`）；代理/落地机要确认面板数据库里没有节点引用该 v6 地址。
- 验证用 `/proc/net/if_inet6`（第 4 列 `00` = global，应为 0），不要用 `ip -6 addr`（受限命名空间会报 `Address family not supported`）。
- 关停后 `ss` 里残留的 `[::]:<port>` 是旧进程持有的 socket，**没有 v6 地址即不可达**，不要为了消掉它去重启业务。
- 实测：4 项全 1、global v6 = 0、SSH 仍通。

### 3.9 TCP 调优（`09-tcp-tuning.sh`）

按 **BDP = 带宽 × RTT** 推导，参数不套模板：

| 参数 | 参考值（1Gbps / 226ms 欧洲、60ms 家宽、3.8G 内存） | 依据 |
|---|---|---|
| rmem_max / wmem_max | 33554432（32MB） | 1Gbps×226ms=28MB，取 1×BDP；家宽路径 4× |
| tcp_rmem / tcp_wmem | 4096 262144 33554432 | 默认值抬到 256KB，代理多小流不受默认窗口限制 |
| tcp_mem | 32768 65536 131072（128/256/512MB） | 全局上限防长连接吃穿内存 |
| somaxconn / tcp_max_syn_backlog | 8192 / 8192 | 镜像常见 4096 / **256**，后者对代理明显偏小 |
| netdev_max_backlog / budget | 16384 / 600 | 镜像常见 1000 / 300 |
| tcp_fastopen | 3（原 1，只开了客户端） | 中转要接受 TFO |
| tcp_slow_start_after_idle | 0（原 1） | 长连接空闲后不重置 cwnd |
| tcp_fin_timeout / tcp_tw_reuse | 15 / 1 | 端口回收 |
| ip_local_port_range | 10000 65535 | 出站并发 |
| tcp_mtu_probing | 1 | PMTU 黑洞兜底（不改 MTU 本身） |
| fs.file-max / fs.nr_open | 2097152 / 1048576 | 并发连接 |
| vm.swappiness / dirty_ratio / dirty_background_ratio / vfs_cache_pressure | 10 / 15 / 5 / 50 | 有 swap 时轻压换出、降低回写抖动 |

**文件必须叫 `zz-*.conf`**：镜像自带 `/etc/sysctl.d/local.conf`（模板 builder 产物）在字典序里排在 `99-*` **之后**，会把 99- 文件里的同名项盖回去，而且**不报错**，只是值不生效。

持久化：
- `/etc/modules-load.d/tcp_bbr.conf` = `net.ipv4.tcp_bbr`
- `initcwnd 32`：`ip route change default via <gw> dev <if> onlink initcwnd 32 initrwnd 32`，改前武装 120s 回滚
- `hermes-tune-persist.service`（oneshot，After=network-online.target）重放：root qdisc `fq`、initcwnd、io scheduler `none`、read_ahead 256、nr_requests 1024、**THP `madvise`**
- **THP 不会自己持久**（重启后回到 `always`），必须放进 oneshot 重放

**A/B 实测（Paris `ping.online.net:5202`，226ms，`-t 10 -O 2`）**：

| 场景 | 改前（原厂） | 改后 | 变化 |
|---|---|---|---|
| 单流下行 | 377 Mbps | **740 Mbps** | 2.0× |
| 单流上行 | 341 Mbps | **747 Mbps** | 2.2× |
| 4 流下行 | 735 Mbps | 802 Mbps | +9% |
| 同城（0.17ms，1G口） | 956 Mbps | 956 Mbps | 端口已满，无空间 |

A/B 方法：先测改后 → 机内临时回退原厂参数（`sysctl -w` + `/proc` 整组写）→ 同端点再测 → 恢复。

### 3.10 总验收（`10-verify.sh`）

`sshd -T` 关键项、`ss -ltn` 端口集合与快照逐项比对、`nft list ruleset`、`fail2ban-client status`、`sysctl -n` 关键值、`tc qdisc`、`ip route | initcwnd`、`/proc/net/if_inet6`、`apt-get -s upgrade | grep -c ^Inst`、`journalctl --disk-usage`、外部两台机器各登录 ≥2 次。
**重启后再跑一次**：证明 qdisc/initcwnd/nft/fail2ban/sshd 端口/THP 全部自恢复。

### 3.11 完整测评（`11-bench-nq.sh` / `12-bench-tq.sh`）

**NQ = NodeQuality 修补版（`yinyues2/NodeQuality` 的 `hermes-fixed` 分支）**，深度全量 `v/y/y/y`：

```bash
curl -fsSL https://raw.githubusercontent.com/yinyues2/NodeQuality/hermes-fixed/extras/run_nq_full.sh -o run_nq_full.sh
bash run_nq_full.sh /root/bench-nq     # 报告链接写进 /root/bench-nq/status.log
```

修补了什么（相对上游）：`run_ip_quality()` 若存在 `$HERMES_IPQ`（默认 `/root/ipq-hermes.sh`）就用修补版 IPQuality；修补版修了 AmazonPV（加浏览器头+重试）、Reddit（先测首页再回退内部接口）、Netflix（剔除「DNS 记录数 ≤2 = DNS 解锁」的误判）。**只修检测能力，不改判定阈值**。

**TQ = TcpQuality `--all`**：

```bash
curl -fsSL https://tcpquality.ibsgss.uk/run -o /root/tq.sh
TERM=xterm-256color bash /root/tq.sh --all      # 没有 TERM 会直接 exit 1
```

`--all` 覆盖：IPv4/IPv6 回程丢包（93/65 节点）、IPv4 大包回程、教育网（CERNET/CERNET2）、国际互联（港/日/新/美/欧/澳）、常用网站与 CDN、单线程测速（京沪粤三网回程/去程）。
**注意**：NQ 的「国内测速」段常因脚本测速节点不可用而整体 ERROR，那是工具问题，不等于机器慢——国内速度以 TQ 的单线程测速为准。

**实测**：

- NQ：（NQ 报告链接含真实 IP，交付时单独提供）
  CPU Ryzen 9 9950X 2C/2T，Geekbench5 **1949/3545**，Sysbench 6397/12323；内存读 103846 MB/s、延迟 95ns；HQ 45824（排名 15.9%）
  IPv4 上游 东京、机房 IP、黑名单 0/423；**TikTok/Disney+/Netflix/YouTube/AmazonPV/Reddit/ChatGPT 全解锁且原生**
  三网回程 **电信 CTGGIA / 联通 9929 / 移动 CMIN2**；广东 53/56/70ms
- TQ：（TQ 报告链接含真实 IP，交付时单独提供）
  IPv4 回程 **93/93 零丢包**；单线程 北京联通 **936**、上海电信 **953**、广东电信 **794** Mbps；Apple 945/1078 Mbps
  IPv6 回程 65 零丢包 / 25 部分 / 3 严重；**IPv6 国内速度弱（深圳移动 62.8/34.2）→ 出口优先 IPv4**

### 3.12 回滚（`99-rollback.sh`）

逐项对应：删 drop-in + reload、`systemctl disable --now nftables && nft flush ruleset`、删 sysctl 文件 + `sysctl --system`、删 jail 文件 + restart fail2ban、删调优文件 + disable oneshot + `ip route change`（去 initcwnd）、`echo always > /sys/kernel/mm/transparent_hugepage/enabled`、恢复 IPv6、`ssh` 整目录还原。

---

## 4. 第三方脚本来源（全部钉版本）

| 用途 | 来源 | 说明 |
|---|---|---|
| NQ 上游 | https://github.com/LloydAsp/NodeQuality | 基线 commit `a92fca6`（2026-03-17，脚本版本 v2026-05-21） |
| NQ 修补分支 | https://github.com/yinyues2/NodeQuality（`hermes-fixed`） | 修 AmazonPV / Reddit / Netflix 三处误判；`grep -n HERMES-PATCH` 定位补丁点 |
| IPQuality | https://github.com/xykt/IPQuality | v2026-09-16，上游 `ip.sh` sha256 `b30df5a3…`；修补版 `extras/ipq-hermes.sh` |
| HardwareQuality | https://github.com/xykt/HardwareQuality | NQ 硬件段调用 `bash <(curl -sL https://Check.Place) -H` |
| NetQuality | https://github.com/xykt/NetQuality | NQ 网络段调用（v2026-09-01） |
| TcpQuality | https://github.com/ibsgss/TcpQuality | runner `https://tcpquality.ibsgss.uk/run`，rootfs `v1.00045`（88.8MB） |
| tcpfit（可选） | https://github.com/oneclickvirt/tcpfit（技能引用版本） | 本次未使用，手工按 BDP 推导；要用先 `sha256sum -c SHA256SUMS` |
| iperf3 | Debian 源 `iperf3 3.18` | 公共长路径端点：`ping.online.net:5200-5203`（5200 常 busy）、`bouygues.iperf.fr:5200` |
| 方法论原文 | https://blog.ibytebox.com/posts/ai-agent-vps-tcp-tuning/ | TCP 调优「先基线后改动、无丢包不整形」的来源 |

---

## 5. 常见坑（全部实测踩过）

1. **drop-in 前缀**：`99-` 会被 `50-cloud-init.conf` 压掉 → 必须 `00-`；而字典序排在我们前面的供应商文件（`00-jcloud.conf`）同样会赢 → 必须就地改写它们的值 + 用 `sshd -T` 硬断言（脚本已内置）。
1b. **「只做链路/当中转」的机器也必须跑 02**：野草云香港（2026-11-01 接入，只配了 realm/sing-box）整台跳过了开荒，`sshd_config` 停在镜像日期、`PasswordAuthentication yes`、`PermitRootLogin yes`，四天无人发现——开荒不是「装业务的机器才做」，接入即跑。
2. **sysctl 前缀**：`99-*` 会被 `local.conf` 压掉（字典序数字 < 字母）→ 必须 `zz-*`。
3. **`sshd -T` 非 root 拿不到有效值**：无 sudo 的机器要走提权脚本。
4. **fail2ban 写了 `[sshd]` 不带 backend** → 打回 polling → failed。
5. **`[recidive]` 不写 `backend=auto`+`logpath`** → 静默不启动。
6. **`flush ruleset` 与 fail2ban nftables 表**：开机顺序无冲突，运行中 restart nftables 会清掉封禁记录。
7. **THP 不持久**：`echo madvise` 只在当前生效，必须进 oneshot。
8. **TQ 无 `TERM` 直接 exit 1**：`TERM=xterm-256color`，且用 `systemd-run`/`setsid` 后台跑。
9. **公共 iperf3 端点 busy**：换端口（5200→5202/5203），A/B 必须同一端点同一参数。
10. **`ip route change` 漏取消 `systemd-run --on-active` 回滚** → 到点静默回滚 initcwnd，看起来像「持久化没生效」。
11. **NQ 国内测速 ERROR ≠ 机器慢**；**IPv6 的 IP 属性不能外推到 IPv4**（反之亦然）。

---

## 6. 交付物清单（每台机）

- `/root/pre-harden-YYYYMMDD/` — 改前快照（etc/ssh、fail2ban、sysctl、iptables、nft、sysctl-all、tc、route、ports、units、dpkg）
- `/root/99-security-profile.md` — 安全档案（改前/改后两列 + 失联恢复 + 回滚）
- `/root/99-tune-profile.md` — 调优档案（BDP 推导、逐项依据、A/B 数据、没做什么及原因）
- `/root/suid-list.txt`
- `/root/bench-*/status.log`、NQ/TQ 报告链接
- 云端工作目录 `<host>-YYYYMMDD/SUMMARY.md`（给用户看的那份）

---

## 7. 许可

脚本与文档本身 MIT。**引用的第三方脚本各自遵循其原许可**：NodeQuality / IPQuality / HardwareQuality / NetQuality 为 AGPL-3.0，TcpQuality 见其仓库。
