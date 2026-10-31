# <host> 调优档案 — <日期>

角色：<中转/落地>；机器：<虚拟化>／<OS>／内核 <ver>／<CPU>／<内存>／<磁盘>／**<带宽> 端口（实测 <数字>）**／<v4/v6>

## 一、改前基线（镜像模板已带的）

`cc=`、活动 qdisc=、rmem_max/wmem_max=、tcp_rmem/wmem=、somaxconn=、tcp_max_syn_backlog=、netdev_max_backlog=、tcp_fastopen=、tcp_slow_start_after_idle=、tcp_mtu_probing=、initcwnd=、THP=、read_ahead=、swap=

## 二、改了什么（依据）

BDP 计算：`<带宽> × <RTT> = <BDP> MB`，缓冲取 <N×>。

| 参数 | 改前 | 改后 | 依据 |
|---|---|---|---|
| rmem_max / wmem_max | | | |
| tcp_rmem / tcp_wmem | | | |
| tcp_mem | | | |
| somaxconn / syn_backlog | | | |
| netdev_max_backlog / budget | | | |
| tcp_fastopen | | | |
| tcp_slow_start_after_idle | | | |
| initcwnd | | | |
| THP / read_ahead | | | |

持久化：`/etc/sysctl.d/zz-hermes-tcp-tuning.conf`、`/etc/modules-load.d/tcp_bbr.conf`、`hermes-tune-persist.service`（重放 qdisc/initcwnd/io/THP）。

## 三、A/B 实测（同端点、同参数、「改前」两列）

| 场景 | 改前 | 改后 | 变化 |
|---|---|---|---|
| 单流下行 | | | |
| 单流上行 | | | |
| 4 流下行 | | | |
| 4 流上行 | | | |
| 同城（短路径） | | | |

重启后复测：<数字>；自恢复项：qdisc / initcwnd / nft / fail2ban / sshd 端口 / THP。

## 四、没做 / 做不了（诚实记录）

1. TCP 整形：`tc -s qdisc` 无丢包证据 → 不做。
2. MTU：无 PMTU 证据 → 保持 1500 + `tcp_mtu_probing=1`。
3. CPU 节能：KVM 无 cpufreq → 客户机侧不可调。
4. 其它：

## 五、回滚

见仓库 `scripts/99-rollback.sh`；改前快照 `/root/pre-harden-<日期>/root/`（sysctl-all、tc-qdisc、ip-route）。
