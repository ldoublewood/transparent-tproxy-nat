#!/bin/bash
# =============================================================================
# ipt2socks 多实例管理器
# =============================================================================
# 根据 JSON 配置文件启动/停止/监控一批 ipt2socks 进程。
#
# 用法:
#   sudo bash ipt2socks-manager.sh start      启动所有实例
#   sudo bash ipt2socks-manager.sh stop       停止所有实例
#   sudo bash ipt2socks-manager.sh restart    重启所有实例
#   sudo bash ipt2socks-manager.sh status     查看实例状态
#   sudo bash ipt2socks-manager.sh run        前台模式 (供 systemd)
#
# 配置文件:
#   默认读取脚本同目录下的 ipt2socks.json
#   可通过 IPT2SOCKS_CONFIG 环境变量覆盖路径
#   JSON 格式见 ipt2socks.json.example
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${IPT2SOCKS_CONFIG:-$SCRIPT_DIR/ipt2socks.json}"
PID_DIR="/run/ipt2socks"

# =========================================================================
# 工具函数
# =========================================================================

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
err()  { echo "[$(date '+%H:%M:%S')] [ERROR] $*" >&2; }

# 解析 JSON 配置，每行输出一个实例的 key=value 对（实例间用 "---" 分隔）
parse_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        err "配置文件不存在: $CONFIG_FILE"
        err "请先创建: cp ipt2socks.json.example ipt2socks.json"
        exit 1
    fi

    python3 -c "
import json, sys

with open('$CONFIG_FILE') as f:
    config = json.load(f)

instances = config.get('instances', [])
if not instances:
    print('WARN: 配置文件中没有实例定义', file=sys.stderr)
    sys.exit(0)

for i, inst in enumerate(instances):
    name    = inst.get('name', 'instance-{}'.format(i))
    host    = inst.get('socks5_host', '')
    port    = inst.get('socks5_port', 1080)
    user    = inst.get('username', '')
    passwd  = inst.get('password', '')
    tproxy  = inst.get('tproxy_port', 60080)
    verbose = inst.get('verbose', False)

    if not host:
        print('WARN: 实例 {} 缺少 socks5_host，已跳过'.format(name), file=sys.stderr)
        continue

    print('NAME={}'.format(name))
    print('HOST={}'.format(host))
    print('PORT={}'.format(port))
    print('USER={}'.format(user))
    print('PASS={}'.format(passwd))
    print('TPROXY={}'.format(tproxy))
    print('VERBOSE={}'.format(str(verbose).lower()))
    print('---')
"
}

# 构建 ipt2socks 命令行
build_cmdline() {
    local name="$1" host="$2" port="$3" user="$4" pass="$5" tproxy="$6" verbose="$7"
    local cmd="ipt2socks -s $host -p $port -b 0.0.0.0 -l $tproxy"

    if [ -n "$user" ]; then
        cmd="$cmd -a $user -k $pass"
    fi
    if [ "$verbose" = "true" ]; then
        cmd="$cmd -v"
    fi

    echo "$cmd"
}

# =========================================================================
# start — 启动所有实例
# =========================================================================
cmd_start() {
    if [ "$(id -u)" -ne 0 ]; then
        err "启动 ipt2socks 需要 root 权限 (TPROXY 需要 CAP_NET_ADMIN)"
        exit 1
    fi

    if ! command -v ipt2socks &>/dev/null; then
        err "未找到 ipt2socks，请确认已安装并在 PATH 中"
        exit 1
    fi

    log "读取配置: $CONFIG_FILE"

    # 创建 PID 目录
    mkdir -p "$PID_DIR"

    local total=0 success=0
    local current_name="" current_host="" current_port="" current_user=""
    local current_pass="" current_tproxy="" current_verbose=""

    while IFS='=' read -r key value; do
        case "$key" in
            NAME)    current_name="$value" ;;
            HOST)    current_host="$value" ;;
            PORT)    current_port="$value" ;;
            USER)    current_user="$value" ;;
            PASS)    current_pass="$value" ;;
            TPROXY)  current_tproxy="$value" ;;
            VERBOSE) current_verbose="$value" ;;
            ---)
                total=$((total + 1))
                local pidfile="$PID_DIR/${current_name}.pid"

                # 检查是否已在运行
                if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
                    log "[$current_name] 已在运行 (PID: $(cat "$pidfile"))"
                    success=$((success + 1))
                    continue
                fi

                # 清理残留 PID 文件
                rm -f "$pidfile"

                local cmdline
                cmdline=$(build_cmdline "$current_name" "$current_host" "$current_port" \
                    "$current_user" "$current_pass" "$current_tproxy" "$current_verbose")

                log "[$current_name] 启动: $cmdline"

                # 启动进程
                $cmdline &
                local pid=$!

                # 短暂等待确认进程存活
                sleep 0.5
                if kill -0 "$pid" 2>/dev/null; then
                    echo "$pid" > "$pidfile"
                    log "[$current_name] 已启动 (PID: $pid, tproxy: ${current_tproxy})"
                    success=$((success + 1))
                else
                    err "[$current_name] 启动失败，请检查 ipt2socks 输出"
                fi
                ;;
        esac
    done < <(parse_config)

    echo ""
    log "启动完成: $success / $total 个实例"
}

# =========================================================================
# stop — 停止所有实例
# =========================================================================
cmd_stop() {
    if [ "$(id -u)" -ne 0 ]; then
        err "停止 ipt2socks 需要 root 权限"
        exit 1
    fi

    if [ ! -d "$PID_DIR" ]; then
        log "PID 目录不存在，没有正在运行的实例"
        return
    fi

    local stopped=0
    for pidfile in "$PID_DIR"/*.pid; do
        [ -f "$pidfile" ] || continue
        local name
        name=$(basename "$pidfile" .pid)
        local pid
        pid=$(cat "$pidfile" 2>/dev/null) || continue

        if kill -0 "$pid" 2>/dev/null; then
            log "[$name] 发送 SIGTERM → PID $pid"
            kill "$pid" 2>/dev/null || true

            # 等待最多 5 秒
            for i in $(seq 1 10); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.5
            done

            # 仍未退出则强制 kill
            if kill -0 "$pid" 2>/dev/null; then
                log "[$name] 未响应 SIGTERM，发送 SIGKILL"
                kill -9 "$pid" 2>/dev/null || true
            fi
            stopped=$((stopped + 1))
        else
            log "[$name] PID $pid 已不存在，清理残留"
        fi
        rm -f "$pidfile"
    done

    log "已停止 $stopped 个实例"
}

# =========================================================================
# restart — 重启所有实例
# =========================================================================
cmd_restart() {
    cmd_stop
    sleep 1
    cmd_start
}

# =========================================================================
# status — 查看实例状态
# =========================================================================
cmd_status() {
    echo "============================================"
    echo " ipt2socks 实例状态"
    echo "============================================"

    if [ ! -d "$PID_DIR" ] || ! ls "$PID_DIR"/*.pid &>/dev/null; then
        echo ""
        echo "  没有正在运行的实例 (PID 目录为空)"
        echo ""
        echo "  配置文件: $CONFIG_FILE"
        if [ -f "$CONFIG_FILE" ]; then
            echo "  已配置实例:"
            python3 -c "
import json
with open('$CONFIG_FILE') as f:
    config = json.load(f)
for i in config.get('instances', []):
    print('    - {} → {}:{} (tproxy:{})'.format(
        i.get('name','?'), i.get('socks5_host','?'),
        i.get('socks5_port','?'), i.get('tproxy_port','?')))
"
        fi
        exit 0
    fi

    printf "  %-16s %-8s %-22s %-8s %s\n" "NAME" "PID" "SOCKS5" "TPROXY" "STATUS"
    printf "  %-16s %-8s %-22s %-8s %s\n" "────" "────" "──────" "──────" "──────"

    for pidfile in "$PID_DIR"/*.pid; do
        [ -f "$pidfile" ] || continue
        local name
        name=$(basename "$pidfile" .pid)
        local pid
        pid=$(cat "$pidfile" 2>/dev/null) || continue

        # 从 JSON 配置中查找对应信息
        local info
        info=$(python3 -c "
import json
with open('$CONFIG_FILE') as f:
    config = json.load(f)
for i in config.get('instances', []):
    if i.get('name') == '$name':
        print('{}:{} {}'.format(i.get('socks5_host','?'), i.get('socks5_port','?'), i.get('tproxy_port','?')))
        break
" 2>/dev/null)
        local host_port="${info% *}"
        local tproxy_port="${info##* }"

        if kill -0 "$pid" 2>/dev/null; then
            printf "  %-16s %-8s %-22s %-8s %s\n" "$name" "$pid" "$host_port" "$tproxy_port" "● RUNNING"
        else
            printf "  %-16s %-8s %-22s %-8s %s\n" "$name" "$pid" "$host_port" "$tproxy_port" "✗ DEAD"
        fi
    done

    echo ""
}

# =========================================================================
# 前台运行模式 (供 systemd 使用)
# =========================================================================
cmd_run() {
    cmd_start

    # 等待所有子进程，同时响应信号
    trap 'echo ""; log "收到退出信号，正在停止所有实例..."; cmd_stop; exit 0' SIGTERM SIGINT

    log "所有实例已启动，等待进程退出... (PID: $$)"
    while true; do
        wait -n 2>/dev/null || true

        # 检查是否还有子进程存活
        local alive=0
        for pidfile in "$PID_DIR"/*.pid; do
            [ -f "$pidfile" ] || continue
            local pid
            pid=$(cat "$pidfile" 2>/dev/null) || continue
            if kill -0 "$pid" 2>/dev/null; then
                alive=$((alive + 1))
            fi
        done

        if [ "$alive" -eq 0 ]; then
            log "所有子进程已退出"
            exit 1
        fi
    done
}

# =========================================================================
# 入口
# =========================================================================
case "${1:-}" in
    start)   cmd_start   ;;
    stop)    cmd_stop    ;;
    restart) cmd_restart ;;
    status)  cmd_status  ;;
    run)     cmd_run     ;;   # systemd 前台模式
    *)
        echo "用法: $0 {start|stop|restart|status|run}"
        echo ""
        echo "  start    — 启动所有 ipt2socks 实例"
        echo "  stop     — 停止所有 ipt2socks 实例"
        echo "  restart  — 重启所有实例"
        echo "  status   — 查看实例运行状态"
        echo "  run      — 前台运行模式 (供 systemd 使用)"
        echo ""
        echo "配置文件: $CONFIG_FILE"
        exit 1
        ;;
esac
