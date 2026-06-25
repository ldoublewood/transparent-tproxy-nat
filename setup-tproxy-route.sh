#!/bin/bash
# =============================================================================
# TPROXY 策略路由设置脚本
# =============================================================================
# 此脚本配置内核策略路由，使被 nftables 标记的包路由到本地 TPROXY。
# 配合 nftables-tproxy.conf 使用，在加载 nftables 规则之前执行。
#
# 用法 (root):  bash setup-tproxy-route.sh [fwmark] [route_table] [iface]
#         默认:  fwmark=1, route_table=100, iface=wlo1
#
# 持久化:       见下方注释，或使用 tproxy-route.service
# =============================================================================

set -e

MARK=${1:-1}          # fwmark 编号，需与 nftables 中 TPROXY_MARK 一致
TABLE=${2:-100}       # 路由表编号
LAN_IFACE=${3:-wlo1}  # 局域网网卡名称

echo "==> 配置 TPROXY 策略路由 (fwmark=$MARK, table=$TABLE, iface=$LAN_IFACE)"

# ---- 1. 清理旧规则 (确保脚本可重复执行) ----
ip -4 rule  del fwmark "$MARK" table "$TABLE" 2>/dev/null || true
ip -4 route del local 0.0.0.0/0 dev lo table "$TABLE" 2>/dev/null || true

# ---- 2. 添加策略路由: 带 fwmark 的包查询 table $TABLE ----
ip -4 rule add fwmark "$MARK" table "$TABLE"
echo "  ✓ ip rule:  fwmark $MARK → lookup table $TABLE"

# ---- 3. table $TABLE 中将所有地址路由到本地 lo 接口 ----
#     这使得被标记的包被内核当作"本地投递"处理，从而被 TPROXY 捕获
ip -4 route add local 0.0.0.0/0 dev lo table "$TABLE"
echo "  ✓ ip route: 0.0.0.0/0 dev lo scope local (table $TABLE)"

# ---- 4. 开启 IP 转发 (本机作为 LAN 客户端的网关时需要) ----
sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo "  ✓ net.ipv4.ip_forward = 1"

# ---- 5. 反向路径过滤 (TPROXY 回包必须关闭 rp_filter) ----
#     TPROXY 回复包的源地址是客户端原始请求的目标地址（非本机地址），
#     如果 rp_filter 开启，内核会丢弃这些"源地址不在入接口子网"的包
sysctl -w net.ipv4.conf."$LAN_IFACE".rp_filter=0 >/dev/null 2>/dev/null || true
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
echo "  ✓ rp_filter = 0 (all + $LAN_IFACE)"

# ---- 6. 接受发往本地网段地址的入站包 (可选) ----
sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>/dev/null || true
sysctl -w net.ipv4.conf."$LAN_IFACE".route_localnet=1 >/dev/null 2>/dev/null || true
echo "  ✓ route_localnet = 1"

# ---- 7. 接受源地址非本接口子网的入站包 (TPROXY 需要) ----
sysctl -w net.ipv4.conf."$LAN_IFACE".accept_local=1 >/dev/null 2>/dev/null || true
echo "  ✓ accept_local ($LAN_IFACE) = 1"

echo ""
echo "==> 策略路由配置完成。当前状态:"
echo "---- ip rule | grep fwmark ----"
ip -4 rule show | grep "fwmark $MARK" || echo "  (无 fwmark $MARK 规则)"
echo "---- ip route show table $TABLE ----"
ip -4 route show table "$TABLE" || echo "  (表 $TABLE 为空)"

echo ""
echo "==> 下一步: 加载 nftables 规则"
echo "    sudo nft -f nftables-tproxy.conf"
echo ""
echo "==> 持久化 (Ubuntu 22.04)"
echo "    # nftables 规则"
echo "    sudo cp nftables-tproxy.conf /etc/nftables.conf"
echo "    sudo systemctl enable --now nftables"
echo ""
echo "    # 策略路由 (systemd)"
echo "    sudo cp tproxy-route.service /etc/systemd/system/"
echo "    sudo systemctl daemon-reload"
echo "    sudo systemctl enable --now tproxy-route"
