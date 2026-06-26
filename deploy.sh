#!/bin/bash
# =============================================================================
# TPROXY NAT 透明网关 — 一键部署脚本
# =============================================================================
# 用法:
#   部署:   sudo bash deploy.sh
#   卸载:   sudo bash deploy.sh --uninstall
#
# 前置条件:
#   1. cp .env.example .env 并编辑变量
#   2. 代理程序已监听在 $TPROXY_PORT
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# =========================================================================
# 检查 root
# =========================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 此脚本需要 root 权限运行"
    echo "请使用: sudo bash deploy.sh"
    exit 1
fi

# =========================================================================
# 卸载模式
# =========================================================================
if [ "$1" = "--uninstall" ] || [ "$1" = "-u" ]; then
    echo "============================================"
    echo " TPROXY NAT 网关 — 卸载"
    echo "============================================"

    # 加载 .env 以获取变量 (用于清理)
    if [ -f "$SCRIPT_DIR/.env" ]; then
        source "$SCRIPT_DIR/.env"
    fi
    MARK=${TPROXY_MARK:-1}
    TABLE=${RT_TABLE:-100}

    echo ""
    echo ">>> 清除 nftables 规则"
    nft flush ruleset 2>/dev/null && echo "    ✓ nftables 规则已清除" || echo "    ⚠ nftables 无规则或未加载"

    echo ""
    echo ">>> 清除策略路由"
    ip -4 rule del fwmark "$MARK" table "$TABLE" 2>/dev/null && echo "    ✓ fwmark $MARK 规则已删除" || echo "    ⚠ 无 fwmark $MARK 规则"
    ip -4 route del local 0.0.0.0/0 dev lo table "$TABLE" 2>/dev/null && echo "    ✓ table $TABLE 路由已删除" || echo "    ⚠ table $TABLE 无路由"

    echo ""
    echo ">>> 恢复内核参数"
    sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 && echo "    ✓ ip_forward = 0" || true

    echo ""
    echo ">>> 禁用 systemd 服务"
    systemctl disable --now tproxy-route 2>/dev/null && echo "    ✓ tproxy-route 已禁用" || echo "    ⚠ tproxy-route 未启用"
    systemctl disable --now nftables 2>/dev/null && echo "    ✓ nftables 已禁用" || echo "    ⚠ nftables 未启用"

    echo ""
    echo "============================================"
    echo " 卸载完成"
    echo "============================================"
    exit 0
fi

# =========================================================================
# 部署模式
# =========================================================================

# 检查 .env 文件
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "============================================"
    echo " 错误: 未找到 .env 配置文件"
    echo "============================================"
    echo ""
    echo "请先创建并编辑 .env 文件:"
    echo "  cp .env.example .env"
    echo "  nano .env"
    echo ""
    echo "然后重新运行:"
    echo "  sudo bash deploy.sh"
    echo ""
    exit 1
fi

# 加载配置 (set -a 使变量自动 export，供 envsubst 使用)
set -a
source "$SCRIPT_DIR/.env"
set +a

# 验证必要变量
REQUIRED_VARS="LAN_IFACE WAN_IFACE LAN_SUBNET TPROXY_PORT TPROXY_MARK RT_TABLE"
for var in $REQUIRED_VARS; do
    if [ -z "${!var}" ]; then
        echo "错误: .env 中缺少变量 $var"
        exit 1
    fi
done

echo "============================================"
echo " TPROXY NAT 网关 — 一键部署"
echo "============================================"
echo " LAN_IFACE    = $LAN_IFACE"
echo " WAN_IFACE    = $WAN_IFACE"
echo " LAN_SUBNET   = $LAN_SUBNET"
echo " TPROXY_PORT  = $TPROXY_PORT"
echo " TPROXY_MARK  = $TPROXY_MARK"
echo " RT_TABLE     = $RT_TABLE"
echo "============================================"

# -----------------------------------------------------------------
# 第一步: 从模板生成配置文件
# -----------------------------------------------------------------
echo ""
echo ">>> [1/4] 生成配置文件"

envsubst < "$SCRIPT_DIR/nftables-tproxy.conf.template" > "$SCRIPT_DIR/nftables-tproxy.conf"
echo "    ✓ nftables-tproxy.conf (变量已替换)"

envsubst < "$SCRIPT_DIR/tproxy-route.service.template" > "$SCRIPT_DIR/tproxy-route.service"
echo "    ✓ tproxy-route.service (变量已替换)"

# -----------------------------------------------------------------
# 第二步: 配置策略路由 & 内核参数
# -----------------------------------------------------------------
echo ""
echo ">>> [2/4] 配置策略路由 & 内核参数"
bash "$SCRIPT_DIR/setup-tproxy-route.sh"

# -----------------------------------------------------------------
# 第三步: 加载 nftables 规则
# -----------------------------------------------------------------
echo ""
echo ">>> [3/4] 加载 nftables 规则"
nft -f "$SCRIPT_DIR/nftables-tproxy.conf"
echo "    ✓ nftables 规则已加载"

# -----------------------------------------------------------------
# 第四步: 安装 systemd 服务 (可选)
# -----------------------------------------------------------------
echo ""
echo ">>> [4/4] 安装 systemd 服务"
if [ "${INSTALL_SERVICES:-no}" = "yes" ]; then
    echo "    INSTALL_SERVICES=yes — 安装开机自启服务"

    cp "$SCRIPT_DIR/nftables-tproxy.conf" /etc/nftables.conf
    echo "    ✓ /etc/nftables.conf"

    if command -v systemctl &>/dev/null; then
        systemctl enable --now nftables 2>/dev/null && echo "    ✓ nftables 服务已启用" || echo "    ⚠ nftables 服务启用失败"
    fi

    cp "$SCRIPT_DIR/setup-tproxy-route.sh" /usr/local/bin/
    chmod +x /usr/local/bin/setup-tproxy-route.sh
    echo "    ✓ /usr/local/bin/setup-tproxy-route.sh"

    cp "$SCRIPT_DIR/tproxy-route.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now tproxy-route 2>/dev/null && echo "    ✓ tproxy-route 服务已启用" || echo "    ⚠ tproxy-route 服务启用失败"
else
    echo "    INSTALL_SERVICES=no — 跳过开机自启安装"
    echo "    如需持久化，在 .env 中设置 INSTALL_SERVICES=yes 后重新部署"
    echo ""
    echo "    手动安装命令:"
    echo "      sudo cp $SCRIPT_DIR/nftables-tproxy.conf /etc/nftables.conf"
    echo "      sudo systemctl enable --now nftables"
    echo "      sudo cp $SCRIPT_DIR/setup-tproxy-route.sh /usr/local/bin/"
    echo "      sudo chmod +x /usr/local/bin/setup-tproxy-route.sh"
    echo "      sudo cp $SCRIPT_DIR/tproxy-route.service /etc/systemd/system/"
    echo "      sudo systemctl daemon-reload"
    echo "      sudo systemctl enable --now tproxy-route"
fi

# =========================================================================
# 完成
# =========================================================================
echo ""
echo "============================================"
echo " 部署完成！"
echo "============================================"
echo ""
echo " 验证状态:"
echo "   sudo nft list ruleset              # 查看 nftables 规则"
echo "   ip -4 rule show | grep fwmark       # 查看策略路由"
echo "   sysctl net.ipv4.ip_forward          # 应为 1"
echo "   sysctl net.ipv4.conf.all.rp_filter  # 应为 0"
echo "   ss -tlnp | grep $TPROXY_PORT        # 代理程序应监听 0.0.0.0:$TPROXY_PORT"
echo ""
echo " 卸载: sudo bash deploy.sh --uninstall"
