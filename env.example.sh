# 复制成 env.sh 后按机器填写：cp env.example.sh env.sh && chmod 600 env.sh
# 该文件被 scripts/lib.sh 自动 source

# ---- SSH ----
SSH_PORT=52222                                   # 高位随机端口（每台机不同，勿复用别机）
SSH_ALLOW_V4="203.0.113.10 203.0.113.20 100.64.0.0/10"   # 云端 / 性能机 / Tailscale v4
SSH_ALLOW_V6="fd7a:115c:a1e0::/48"               # Tailscale ULA 段（关 IPv6 后形同兜底）

# ---- 网络调优参数（BDP = BW × RTT）----
BW_MBPS=1000                                     # 实测端口带宽（不要照抄商家标称）
RTT_MAX_MS=226                                   # 最长目标路径 RTT（欧洲/美西/家宽取最大）

# ---- 其它 ----
TIMEZONE=Asia/Shanghai
DISABLE_IPV6=1
IFACE=""                                         # 留空=自动探测默认路由网卡
GATEWAY=""                                       # 留空=自动探测默认网关
STAMP=""                                         # 留空=当天日期，用于快照目录名
