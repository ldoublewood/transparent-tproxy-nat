# transparent-tproxy-nat

nftables 实现的 NAT 透明网关，将局域网内其他设备的 TCP/UDP 流量通过 TPROXY 透明重定向到本地代理端口，同时提供完整的 NAT 网关功能（转发 + MASQUERADE）。

## 适用场景

一台 Ubuntu 22.04 机器，有两张网卡：
- **LAN 口**（如 `wlo1`）— 局域网设备通过 WiFi AP 接入
- **WAN 口**（如 `enx00e04c6515ff`）— 连接互联网

局域网内的手机 / 平板 / PC 将默认网关指向本机 LAN IP，所有流量透明经过本机的代理程序（如 ipt2socks、Xray、Clash）访问互联网。

```
手机(192.168.2.x) ──WiFi──→ wlo1(192.168.2.200) 本机 enx00e04c6515ff(192.168.1.217) ──→ ISP ──→ 互联网
                              ↑                         ↑
                            LAN 口                    WAN 口
```

## 文件说明

| 文件 | 用途 |
|------|------|
| `.env.example` | **配置模板** — 所有变量集中在此，复制为 `.env` 后编辑 |
| `deploy.sh` | **一键部署脚本** — 生成配置、配置路由、加载规则、安装服务 |
| `nftables-tproxy.conf.template` | nftables 规则模板（变量占位） |
| `tproxy-route.service.template` | systemd 服务模板（变量占位） |
| `setup-tproxy-route.sh` | 策略路由 + 内核参数 配置脚本 |
| `nftables-tproxy.conf` | nftables 规则（由 `deploy.sh` 自动生成） |
| `tproxy-route.service` | systemd 服务（由 `deploy.sh` 自动生成） |

## 快速开始

### 1. 准备代理程序

确保 TPROXY 代理已运行并监听在 `0.0.0.0:17893`：

```bash
# 以 ipt2socks 为例
ipt2socks -s <SOCKS5服务器IP> -p <SOCKS5端口> -l 17893 -b 0.0.0.0 -v

# 验证
ss -tlnp | grep 17893   # 应显示 0.0.0.0:17893，而非 127.0.0.1
```

> **⚠️ 关键：** 代理必须监听 `0.0.0.0`（或 `*:17893`），**不能**是 `127.0.0.1`。TPROXY 投递的包目标地址是客户端原始请求的外部 IP，监听 `127.0.0.1` 会导致 socket 查找失败。

### 2. 配置变量（唯一入口）

```bash
cp .env.example .env
nano .env    # 编辑网卡名、子网等变量
```

`.env` 中包含了所有需要配置的变量（网卡名、子网、端口等），不再需要分别编辑各个文件。

### 3. 一键部署

```bash
sudo bash deploy.sh
```

此命令自动完成：
- 从模板生成 `nftables-tproxy.conf` 和 `tproxy-route.service`
- 配置策略路由和内核参数
- 加载 nftables 规则
- （可选）安装 systemd 开机自启服务（需在 `.env` 中设置 `INSTALL_SERVICES=yes`）

> 如需卸载：`sudo bash deploy.sh --uninstall`

### 4. 配置客户端

在手机 / 平板上设置：
- **默认网关**：本机 LAN 口 IP（如 `192.168.2.200`）
- **DNS**：自动（UDP DNS 经 TPROXY 代理解析）

### 5. 验证

在手机浏览器打开任意网页，同时在服务端检查：

```bash
# 看代理是否有连接
ss -tnp | grep 17893

# 看转发是否有丢包
sudo nft list chain inet nat_gateway forward | grep counter

# 抓手机流量
sudo tcpdump -i wlo1 -n 'host 192.168.2.64'
```

## 数据流

### TCP/UDP — 走 TPROXY 代理

```
手机 → wlo1 → prerouting(TPROXY :17893, mark=1)
              → 策略路由(table 100 → lo)
              → INPUT(meta mark 1 accept)
              → 代理程序处理 → SOCKS5 出站 → WAN → 互联网
```

### ICMP — 纯转发 + MASQUERADE

```
手机 → wlo1 → forward(wlo1→WAN口) → postrouting(MASQUERADE) → 互联网
```

## 持久化

**推荐方式：** 在 `.env` 中设置 `INSTALL_SERVICES=yes`，然后运行 `sudo bash deploy.sh`，脚本会自动安装所有 systemd 服务。

**手动方式：**
```bash
# nftables 规则（开机自启）
sudo cp nftables-tproxy.conf /etc/nftables.conf
sudo systemctl enable nftables

# 策略路由（开机自启）
sudo cp setup-tproxy-route.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/setup-tproxy-route.sh
sudo cp tproxy-route.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable tproxy-route
```

## 调试

```bash
# 查看规则和计数器
sudo nft list ruleset

# 实时监控 nftables 日志
sudo journalctl -k -f | grep nft

# 抓包定位断点
sudo tcpdump -i wlo1 -n 'not host 192.168.2.200'   # LAN 口入站
sudo tcpdump -i enx00e04c6515ff -n                   # WAN 口出站

# 检查策略路由
ip -4 rule show | grep fwmark
ip route show table 100

# 检查内核参数
sysctl net.ipv4.ip_forward
sysctl net.ipv4.conf.all.rp_filter
```

## 常见问题

### 手机无法上网

逐层排查：

| 检查项 | 命令 |
|--------|------|
| 代理是否监听 `0.0.0.0:17893` | `ss -tlnp \| grep 17893` |
| nftables 规则是否加载 | `sudo nft list ruleset` |
| 策略路由是否就绪 | `ip -4 rule show \| grep fwmark` |
| IP 转发是否开启 | `sysctl net.ipv4.ip_forward` |
| TPROXY 规则是否命中 | `sudo nft list chain inet nat_gateway tproxy_prerouting` 看 counter |
| INPUT 链是否放行 TPROXY 包 | `sudo nft list chain inet nat_gateway input \| grep mark` |
| forward 链是否有 drop | `sudo nft list chain inet nat_gateway forward \| grep counter` |
| 手机流量是否到达 wlo1 | `sudo tcpdump -i wlo1 -n 'host <手机IP>'` |
| WAN 口出站是否正常 | `sudo tcpdump -i enx00e04c6515ff -n 'host 8.8.8.8'` |

### TPROXY 包被 INPUT drop

症状：`input` 链 drop 计数器持续增长。

原因：TPROXY 截获的包经策略路由投递到本地后必经 INPUT 链，需显式放行。

修复：确保 INPUT 链中有 `meta mark 0x1 accept` 规则。

### `rp_filter` 导致回包丢失

TPROXY 回复包的源地址是欺骗的外部 IP，如果 `rp_filter` 开启，内核会丢弃它们。

确认已关闭：`sysctl net.ipv4.conf.all.rp_filter` 和 `sysctl net.ipv4.conf.wlo1.rp_filter` 均为 `0`。

## License

MIT
