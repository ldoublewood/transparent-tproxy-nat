# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

A nftables-based transparent proxy NAT gateway. It uses TPROXY to intercept TCP/UDP traffic from LAN clients and redirect it to a local proxy (ipt2socks, Xray, Clash, etc.), while also providing full NAT gateway forwarding + MASQUERADE for other traffic (ICMP, etc.).

## Key architectural concepts

**Two-path data flow:**

1. **TCP/UDP traffic → TPROXY → local proxy:** Packets entering the LAN interface are intercepted in the `prerouting mangle` chain via `tproxy ip to :<PORT>`, marked with a fwmark, then delivered to the local socket stack via policy routing (`fwmark 1 → table 100 → route 0.0.0.0/0 dev lo`). The proxy receives them with `SO_ORIGINAL_DST` preserving the real destination, processes them, and makes new outbound connections.

2. **Everything else → plain forwarding + MASQUERADE:** Non-TPROXY traffic (ICMP, etc.) passes through the `forward` chain and gets SNAT'd on the WAN interface via `masquerade` in the `postrouting` chain.

**Five nftables chains in a single `inet nat_gateway` table:**

| Chain | Hook / Priority | Role |
|---|---|---|
| `tproxy_prerouting` | prerouting / mangle | Intercept TCP/UDP → TPROXY; skip LAN/local/multicast traffic |
| `input` | input / filter | Drop by default; allow SSH, ICMP, DHCP, and TPROXY-marked packets |
| `forward` | forward / filter | Allow LAN→WAN forwarding, and TPROXY spoofed reply path (lo→LAN) |
| `output` | output / filter | Accept all (host is trusted) |
| `postrouting` | postrouting / srcnat | MASQUERADE on WAN interface for forwarded traffic |

**Critical kernel parameters** (set by `setup-tproxy-route.sh`):
- `ip_forward=1` — required for gateway operation
- `rp_filter=0` — **must** be off; TPROXY reply packets have spoofed source addresses that would be dropped
- `accept_local=1` — allows receiving packets with source addresses not in the interface's subnet
- `route_localnet=1` — allows routing to 127.0.0.0/8
- `lo.forwarding=1` and `<LAN_IFACE>.forwarding=1` — hairpin forwarding

## Common commands

**One-click deploy (preferred):**
```bash
cp .env.example .env && nano .env     # Edit config once
sudo bash deploy.sh                   # Does everything below
sudo bash deploy.sh --uninstall       # Tear down completely
```

**Deploy step-by-step (must run as root):**
```bash
# 1. Generate configs from templates (if not using deploy.sh)
envsubst < nftables-tproxy.conf.template > nftables-tproxy.conf
envsubst < tproxy-route.service.template > tproxy-route.service

# 2. Policy routing + kernel params (must run BEFORE nftables)
sudo bash setup-tproxy-route.sh

# 3. Load nftables rules
sudo nft -f nftables-tproxy.conf

# 4. Persist for reboots (or set INSTALL_SERVICES=yes in .env and re-run deploy.sh)
sudo cp nftables-tproxy.conf /etc/nftables.conf && sudo systemctl enable --now nftables
sudo cp setup-tproxy-route.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/setup-tproxy-route.sh
sudo cp tproxy-route.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now tproxy-route
```

**Verification / debugging:**
```bash
sudo nft list ruleset                    # View all rules and counters
sudo nft list chain inet nat_gateway tproxy_prerouting  # Check TPROXY rule hit counts
sudo nft list chain inet nat_gateway input | grep mark  # Confirm TPROXY-marked packets accepted
sudo nft list chain inet nat_gateway forward | grep counter  # Check for drops
sudo journalctl -k -f | grep nft         # Live nftables log monitor
sudo tcpdump -i <LAN_IFACE> -n 'not host <gateway-ip>'  # Client traffic on LAN
sudo tcpdump -i <WAN_IFACE> -n           # Outbound WAN traffic
ip -4 rule show | grep fwmark            # Verify policy routing
ip route show table 100                  # Verify fwmark routing table
sysctl net.ipv4.ip_forward               # Must be 1
sysctl net.ipv4.conf.all.rp_filter       # Must be 0
ss -tlnp | grep 17893                    # Proxy must listen on 0.0.0.0:17893
```

**Cleanup:**
```bash
sudo bash deploy.sh --uninstall          # One-step cleanup (preferred)

# Manual cleanup:
sudo nft flush ruleset                    # Remove all nftables rules
ip -4 rule del fwmark 1 table 100         # Remove policy routing rule
ip -4 route del local 0.0.0.0/0 dev lo table 100  # Remove route table entry
```

## Critical pitfalls

1. **Proxy MUST listen on `0.0.0.0`, NOT `127.0.0.1`.** TPROXY delivers packets with their original destination address (e.g., `1.2.3.4:443`). A socket bound to `127.0.0.1` won't match these packets, and the kernel will RST the connection.

2. **`rp_filter` MUST be `0`.** TPROXY reply packets have the external server's IP as the source (spoofed). With reverse-path filtering enabled, the kernel drops them because the source IP isn't reachable via the LAN interface.

3. **`setup-tproxy-route.sh` MUST run BEFORE nftables rules are loaded.** The policy routing table must exist before the first TPROXY-marked packet arrives; otherwise those packets fall through to normal routing and bypass the proxy.

4. **Single-interface (hairpin) mode:** When both `LAN_IFACE` and `WAN_IFACE` are set to the same interface, `lo.forwarding` and `<iface>.forwarding` must both be on, and the forward chain must accept `iif "lo" oif $LAN_IFACE` for TPROXY spoofed replies to reach clients.

## Configuration and file roles

All configurable variables live in a single `.env` file (copy from `.env.example`). The `deploy.sh` script reads `.env` and generates working configs from templates via `envsubst`.

| File | Role |
|---|---|
| `.env.example` | Configuration template — committed; users copy to `.env` |
| `.env` | Local config (gitignored) — single source of truth for all variables |
| `deploy.sh` | One-click deploy/uninstall — generates files, sets up routing, loads nftables |
| `nftables-tproxy.conf.template` | nftables rules template with `${VAR}` placeholders |
| `tproxy-route.service.template` | systemd service template with `${VAR}` placeholders |
| `nftables-tproxy.conf` | Generated nftables ruleset (gitignored, produced by `deploy.sh`) |
| `tproxy-route.service` | Generated systemd oneshot service (gitignored, produced by `deploy.sh`) |
| `setup-tproxy-route.sh` | Policy routing + kernel parameters script; reads `.env` for defaults, CLI args override
