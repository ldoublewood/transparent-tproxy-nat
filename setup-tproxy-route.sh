#!/bin/bash
# =============================================================================
# TPROXY 策略路由 + 内核参数 设置脚本
# =============================================================================
# 配合 nftables-tproxy.conf 使用。此脚本必须在加载 nftables 规则之前运行。
#
# 用法 (root):
#   bash setup-tproxy-route.sh [fwmark] [rt_table] [iface] [lan_subnet]
#   默认: fwmark=1  rt_table=100  iface=wlo1  lan_subnet=192.168.1.0/24
#
# =============================================================================

set -e

MARK=${1:-1}                # 防火墙标记 (与 nftables 中 TPROXY_MARK 一致)
TABLE=${2:-100}             # 策略路由表编号
LAN_IFACE=${3:-wlo1}        # 局域网网卡名称
LAN_SUBNET=${4:-192.168.2.0/24}  # 局域网子网

echo "============================================"
echo " TPROXY NAT 网关 — 策略路由 & 内核参数"
echo "============================================"
echo " fwmark      = $MARK"
echo " route table = $TABLE"
echo " LAN iface   = $LAN_IFACE"
echo " LAN subnet  = $LAN_SUBNET"
echo "============================================"

# =========================================================================
# 一、策略路由 (TPROXY 必需)
# =========================================================================
# 原理: 被 nftables 打上 fwmark 的包，在路由决策时不查 main 表而查 table $TABLE。
#       table $TABLE 将全部地址路由到本地 lo，从而使包被内核视为"本地投递"，
#       随后被 TPROXY 捕获。
# =========================================================================

# 1.1 清理旧规则 (幂等 —— 可重复执行)
echo ""
echo ">>> 配置策略路由"
ip -4 rule  del fwmark "$MARK" table "$TABLE" 2>/dev/null || true
ip -4 route del local 0.0.0.0/0 dev lo table "$TABLE" 2>/dev/null || true

# 1.2 策略路由: fwmark $MARK → 查 table $TABLE
ip -4 rule add fwmark "$MARK" table "$TABLE"
echo "    ✓ ip rule:  fwmark $MARK → lookup table $TABLE"

# 1.3 table $TABLE: 全部 IPv4 地址走本地 lo
ip -4 route add local 0.0.0.0/0 dev lo table "$TABLE"
echo "    ✓ ip route: 0.0.0.0/0 dev lo (table $TABLE)"

# =========================================================================
# 二、内核参数 (NAT 网关 + TPROXY 必需)
# =========================================================================
echo ""
echo ">>> 配置内核参数"

# 2.1 IP 转发 (网关基本要求)
sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo "    ✓ net.ipv4.ip_forward = 1"

# 2.2 反向路径过滤 — 必须关闭
#     TPROXY 回复包源地址是被欺骗的外部地址（非本机地址），
#     若 rp_filter 开启，内核会因源地址不属于入接口子网而丢弃回包。
sysctl -w net.ipv4.conf.all.rp_filter=0   >/dev/null
sysctl -w net.ipv4.conf."$LAN_IFACE".rp_filter=0 >/dev/null 2>/dev/null || true
sysctl -w net.ipv4.conf.lo.rp_filter=0    >/dev/null 2>/dev/null || true
echo "    ✓ rp_filter = 0 (all / $LAN_IFACE / lo)"

# 2.3 允许路由到 127.0.0.0/8 (某些代理场景需要)
sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>/dev/null || true
echo "    ✓ route_localnet = 1"

# 2.4 接受源地址非本接口子网的包 (TPROXY 欺骗包回程需要)
sysctl -w net.ipv4.conf."$LAN_IFACE".accept_local=1 >/dev/null 2>/dev/null || true
sysctl -w net.ipv4.conf.all.accept_local=1 >/dev/null 2>/dev/null || true
echo "    ✓ accept_local = 1"

# 2.5 允许从 lo 接口转发 (TPROXY 回复包经 lo→wlo1)
sysctl -w net.ipv4.conf.lo.forwarding=1 >/dev/null 2>/dev/null || true
echo "    ✓ lo.forwarding = 1"

# 2.6 允许 wlo1 的 hairpin 转发 (入=出=同一接口)
sysctl -w net.ipv4.conf."$LAN_IFACE".forwarding=1 >/dev/null 2>/dev/null || true
echo "    ✓ $LAN_IFACE.forwarding = 1"

# 2.7 ARP 代理 — 可选
#     如果 LAN 客户端在同一个广播域但本机不是默认网关，
#     开启 proxy_arp 可让本机代答 ARP 请求，从而截获流量。
#     一般不需要（客户端直接设本机为网关即可），按需取消注释。
# sysctl -w net.ipv4.conf."$LAN_IFACE".proxy_arp=1 >/dev/null

# =========================================================================
# 三、验证当前状态
# =========================================================================
echo ""
echo "============================================"
echo " 验证策略路由"
echo "============================================"
echo ""
echo "--- ip rule (fwmark $MARK) ---"
ip -4 rule show | grep "fwmark $MARK" || echo "  ⚠ 未找到规则"
echo ""
echo "--- ip route show table $TABLE ---"
ip -4 route show table "$TABLE" || echo "  ⚠ 表为空"
echo ""
echo "--- net.ipv4.ip_forward ---"
sysctl net.ipv4.ip_forward
echo ""
echo "--- rp_filter ---"
sysctl net.ipv4.conf.all.rp_filter
sysctl net.ipv4.conf."$LAN_IFACE".rp_filter 2>/dev/null || true
echo ""

echo "============================================"
echo " 策略路由 & 内核参数 配置完成"
echo "============================================"
echo ""
echo " 下一步: 加载 nftables 规则"
echo "   sudo nft -f nftables-tproxy.conf"
echo ""
echo " 持久化部署:"
echo "   # nftables"
echo "   sudo cp nftables-tproxy.conf /etc/nftables.conf"
echo "   sudo systemctl enable --now nftables"
echo ""
echo "   # 策略路由 (systemd)"
echo "   sudo cp tproxy-route.service /etc/systemd/system/"
echo "   sudo mkdir -p /usr/local/bin"
echo "   sudo cp setup-tproxy-route.sh /usr/local/bin/"
echo "   sudo chmod +x /usr/local/bin/setup-tproxy-route.sh"
echo "   sudo systemctl daemon-reload"
echo "   sudo systemctl enable --now tproxy-route"
