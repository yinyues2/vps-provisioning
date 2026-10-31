# 第三方脚本来源与版本（钉死）

本仓库只做「编排 + 判据 + 回滚」，测评能力全部来自下列上游项目。运行时按 URL 拉取，不内联它们的代码。

| 用途 | 上游 | 本流程使用方式 | 版本/commit 记录 |
|---|---|---|---|
| NodeQuality（NQ） | https://github.com/LloydAsp/NodeQuality | 沙箱内跑硬件+IP+网络+回程，输出 nodequality.com/r/… 报告 | 修补分支基线 commit `a92fca6`（2026-03-17，脚本 v2026-05-21） |
| NQ 修补分支 | https://github.com/yinyues2/NodeQuality （分支 `hermes-fixed`） | `extras/run_nq_full.sh` 一条命令跑 `v/y/y/y`；`HERMES_IPQ` 指定修补版 IPQuality | 补丁点用 `grep -n HERMES-PATCH` 定位 |
| IPQuality | https://github.com/xykt/IPQuality | NQ 的 IP 质量段实际执行；修补版 `extras/ipq-hermes.sh` 修 AmazonPV / Reddit / Netflix 三处误判 | 上游 `ip.sh` v2026-09-16，sha256 `b30df5a3…`，108,641 B；修补版版本串 `v2026-09-16-hermes` |
| HardwareQuality | https://github.com/xykt/HardwareQuality | NQ 硬件段 `bash <(curl -sL https://Check.Place) -H` | 报告内标注 v2026-05-21 |
| NetQuality | https://github.com/xykt/NetQuality | NQ 网络段 | v2026-09-01 |
| TcpQuality（TQ） | https://github.com/ibsgss/TcpQuality | runner `https://tcpquality.ibsgss.uk/run` + `--all` | rootfs `v1.00045`（88.8 MB，amd64） |
| tcpfit（可选） | https://github.com/oneclickvirt/tcpfit | 可用 `tcpfit tune --role proxy --bw <实测> --rtt <RTT>` 交叉验证本仓库的取值 | 本仓库 09 脚本未依赖它，参数按 BDP 手算，便于审计 |
| iperf3 | Debian/Ubuntu 源（3.18） | A/B 吞吐测试 | 公共长路径端点：`ping.online.net:5200-5203`（5200 常 busy）、`bouygues.iperf.fr:5200`、`iperf.he.net:5201` |
| TCP 调优方法论 | https://blog.ibytebox.com/posts/ai-agent-vps-tcp-tuning/ | 「先基线后改动、无丢包不整形、角色决定方向」的来源 | 全文另存于 Hermes 技能 `vps-tcp-tuning/references/article-full.md` |

## 许可

- 本仓库脚本与文档：MIT（见 LICENSE）
- NodeQuality / IPQuality / HardwareQuality / NetQuality：**AGPL-3.0**（本仓库不内联其代码，仅按 URL 调用；如需分发请遵循 AGPL）
- TcpQuality：见其仓库许可
