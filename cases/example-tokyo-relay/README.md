# 案例：东京 1Gbps 中转机开荒（脱敏示例）

> 真实 IP / 主机名 / 报告链接已全部替换为文档示例地址（测试网段 198.51.100.0/24、203.0.113.0/24、2001:db8::/32），数值为实跑结果。

机器规格：KVM / Debian 13 / 内核 6.12.x / 2 vCPU（Ryzen 9 9950X）/ 3.8 GiB / 40 GB virtio / 1 Gbps 口
地域：东京（上游 AS-EXAMPLE，回程为三网优化）
角色：**中转机**（主服务器的副机），对外只暴露 SSH `<PORT>`

## 一、安全基线（改前 → 改后）

| 项 | 改前 | 改后 |
|---|---|---|
| SSH 端口 | 22 | **`<PORT>`**（22 已撤，外部探测 refused） |
| PermitRootLogin | yes | prohibit-password |
| PasswordAuthentication | no（cloud-init 推的） | no（写进 `00-` drop-in，双保险） |
| MaxAuthTries / LoginGraceTime | 6 / 120 | **3 / 30** |
| X11 / AgentForwarding | yes / yes | no / no |
| nftables | 无规则 | SSH 源 IP 白名单（v4 白名单 + v6 仅 Tailscale，其余 drop） |
| fail2ban | 1 jail | **2 jail**（sshd aggressive + recidive） |
| 自动安全更新 | 未装 | unattended-upgrades，仅 security 源 |
| journald | 持久化无上限 | 持久化 + 500M |
| 内核加固 | 无 | 26 项 sysctl（实测 `1 2 1 2 1 1 2 2 0`） |
| IPv6 | 公网 v6 在用 | **全机禁用**（4 项 sysctl=1，全局地址 0） |
| 待装补丁 | 0 | 0 |

白名单四向实测：白名单内 2 台机器登录成功；非白名单机器的 v4 TCP 探测超时；IPv6 用差分法（探无监听端口返回 REFUSED、探 SSH 端口超时）确认 drop 生效。

## 二、TCP 调优（A/B 同端点，巴黎 226ms，`-t 10 -O 2`）

| 场景 | 改前（原厂参数） | 改后 | 变化 |
|---|---|---|---|
| 单流下行 | 377 Mbps | **740 Mbps** | 2.0× |
| 单流上行 | 341 Mbps | **747 Mbps** | 2.2× |
| 4 流下行 | 735 Mbps | 802 Mbps | +9% |
| 4 流上行 | — | 1050 Mbps | — |
| 同城（0.17 ms，1 Gbps 口） | 956 Mbps | 956 Mbps | 端口已满，无空间 |

重启后复测：单流下 757 / 上 742 / 4 流下 850 / 4 流上 1040 Mbps；qdisc fq、initcwnd 32、nft 规则、2 jail、SSH 端口、THP madvise 全部自恢复。

改动要点：缓冲 16→32 MB（BDP 推导）、tcp_mem 128/256/512 MB、somaxconn 8192、syn_backlog **256→8192**、netdev_backlog **1000→16384**、fastopen 1→3、slow_start_after_idle 1→0、initcwnd 10→32、tw_reuse/fin_timeout、端口范围、mtu_probing=1、read_ahead 256、THP madvise。

## 三、NQ（NodeQuality 修补版，深度全量 v/y/y/y）

- CPU：Ryzen 9 9950X 2C/2T @4.29 GHz，L3 128 MiB；Sysbench 单核 **6397** / 多核 **12323**；Geekbench5 单核 **1949** / 多核 **3545**
- 内存：读 103846 MB/s、写 41485 MB/s、延迟 **95 ns**；HQ 加权评分 45824（排名 15.9%）
- IPv4：机房 IP、风险低、黑名单库 **0/423**；**TikTok / Disney+ / Netflix / YouTube / AmazonPV / Reddit / ChatGPT 全解锁且原生**
- IPv6（关闭前测得）：原生 IP、风险 0；TikTok 失败、AmazonPV 屏蔽
- 三网 TCP 大包延迟：广东 53 / 56 / 70 ms（电信/联通/移动），北京 53 / 51 / 58，上海 32 / 30 / 35
- 三网回程：电信 CTGGIA / 联通 9929 / 移动 CMIN2（三网全优化）
- 国际互连：东京 1 ms（1168/954 Mbps）、香港 52 ms（1098/874）、洛杉矶 115 ms（982/693）

## 四、TQ（TcpQuality --all）

- **IPv4 回程 93/93 节点零丢包**；IPv6 回程 65 零丢包 / 25 部分丢 / 3 严重丢
- IPv4 三网回程：广东 电信 56 / 联通 58 / 移动 73 ms，全部 0% 重传
- 单线程测速（回程/去程）：北京 电信 933/281、联通 **936/802**、移动 485/342；上海 电信 **953/810**、联通 945/803、移动 567/170；广东 电信 **794/289**、联通 782/73、移动 459/344 Mbps
- 国际：Apple IPv4 945/1078 Mbps、IPv6 923/1335 Mbps；港澳日新美欧澳各节点 0% 重传
- 常用网站 / CDN 全部可达，Google / YouTube / OpenAI / Claude / X 等 1–3 ms（东京 PoP 命中）
- 结论：**出口优先 IPv4**（IPv6 国内速度弱，联通 v6 回程 160–200 ms 且丢包）

## 五、交付物

`/root/pre-harden-YYYYMMDD/`（1.5 MB 改前快照）、`/root/99-security-profile.md`、`/root/99-tune-profile.md`、`/root/suid-list.txt`、NQ/TQ 报告链接（含真实 IP，交付时单独提供）。
