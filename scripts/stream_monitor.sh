#!/bin/bash
# ============================================================
# 串流狀態監控腳本
# 即時顯示 RTMP 推流的狀態與統計資訊
# ============================================================
# 使用方式：./scripts/stream_monitor.sh [interval_seconds]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config/config.env"

# 顏色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 更新間隔（秒）
INTERVAL="${1:-3}"

# 載入設定
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

RTMP_STAT_PORT="${HTTP_STAT_PORT:-8080}"
RTMP_PORT="${RTMP_PORT:-1935}"

# 清除畫面並繪製監控介面
draw_monitor() {
    clear

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo -e "${BOLD}${BLUE}"
    echo "  ┌─────────────────────────────────────────────────────┐"
    echo "  │       樹莓派4 RTMP 推流監控                         │"
    echo "  │       Raspberry Pi 4 RTMP Stream Monitor            │"
    echo "  └─────────────────────────────────────────────────────┘"
    echo -e "${NC}"
    echo -e "  更新時間：${timestamp}  (每 ${INTERVAL} 秒更新)"
    echo ""

    # --------------------------------------------------------
    # 網路孔狀態
    # --------------------------------------------------------
    echo -e "  ${BOLD}📡 網路孔狀態（eth0）${NC}"
    echo -e "  ─────────────────────────────────────────"

    if ip link show eth0 &>/dev/null; then
        local eth_state
        eth_state=$(ip link show eth0 | grep -oP '(?<=state )\w+')
        local eth_ip
        eth_ip=$(ip -4 addr show eth0 | grep -oP '(?<=inet )\S+' | cut -d/ -f1 || echo "未取得")
        local eth_speed=""

        # 嘗試取得連線速度
        if command -v ethtool &>/dev/null; then
            eth_speed=$(ethtool eth0 2>/dev/null | grep "Speed:" | awk '{print $2}' || echo "N/A")
        fi

        if [ "$eth_state" == "UP" ]; then
            echo -e "  狀態：${GREEN}● UP${NC}  │  IP：${eth_ip}  │  速度：${eth_speed:-N/A}"
        else
            echo -e "  狀態：${RED}● $eth_state${NC}  │  IP：${eth_ip:-N/A}"
        fi

        # 網路流量統計
        if [ -f /sys/class/net/eth0/statistics/rx_bytes ]; then
            local rx_bytes tx_bytes
            rx_bytes=$(cat /sys/class/net/eth0/statistics/rx_bytes)
            tx_bytes=$(cat /sys/class/net/eth0/statistics/tx_bytes)
            local rx_mb tx_mb
            rx_mb=$(echo "scale=1; $rx_bytes / 1048576" | bc 2>/dev/null || echo "N/A")
            tx_mb=$(echo "scale=1; $tx_bytes / 1048576" | bc 2>/dev/null || echo "N/A")
            echo -e "  接收：${rx_mb} MB  │  傳送：${tx_mb} MB"
        fi
    else
        echo -e "  ${RED}未找到 eth0 介面${NC}"
    fi

    echo ""

    # --------------------------------------------------------
    # 系統資源
    # --------------------------------------------------------
    echo -e "  ${BOLD}💻 系統資源${NC}"
    echo -e "  ─────────────────────────────────────────"

    # CPU 使用率
    local cpu_usage
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 2>/dev/null || echo "N/A")
    echo -e "  CPU：${cpu_usage}%"

    # CPU 溫度（樹莓派特有）
    if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        local cpu_temp
        cpu_temp=$(cat /sys/class/thermal/thermal_zone0/temp)
        cpu_temp=$(echo "scale=1; $cpu_temp / 1000" | bc)
        local temp_color=$GREEN
        [ "$(echo "$cpu_temp > 70" | bc)" -eq 1 ] && temp_color=$YELLOW
        [ "$(echo "$cpu_temp > 80" | bc)" -eq 1 ] && temp_color=$RED
        echo -e "  溫度：${temp_color}${cpu_temp}°C${NC}"
    fi

    # 記憶體使用
    local mem_info
    mem_info=$(free -h | awk '/^Mem:/ {printf "%s / %s (已用 %s)", $3, $2, $3}')
    echo -e "  記憶體：${mem_info}"

    echo ""

    # --------------------------------------------------------
    # nginx RTMP 伺服器狀態
    # --------------------------------------------------------
    echo -e "  ${BOLD}🎬 nginx RTMP 伺服器${NC}"
    echo -e "  ─────────────────────────────────────────"

    if systemctl is-active --quiet nginx 2>/dev/null; then
        echo -e "  nginx：${GREEN}● 運行中${NC}"

        # 嘗試從統計頁面取得串流資訊
        local stat_url="http://localhost:${RTMP_STAT_PORT}/stat"
        if command -v curl &>/dev/null; then
            local stat_raw
            stat_raw=$(curl -s --connect-timeout 2 "$stat_url" 2>/dev/null || echo "")

            if [ -n "$stat_raw" ]; then
                # 解析活躍串流數
                local stream_count
                stream_count=$(echo "$stat_raw" | grep -c "<name>" 2>/dev/null || echo "0")
                echo -e "  活躍串流：${stream_count} 個"

                # 解析連線數
                local client_count
                client_count=$(echo "$stat_raw" | grep -c "<client>" 2>/dev/null || echo "0")
                echo -e "  連線客戶端：${client_count} 個"
            else
                echo -e "  統計頁面：http://localhost:${RTMP_STAT_PORT}/stat"
            fi
        fi
    else
        echo -e "  nginx：${RED}● 未運行${NC}"
        echo -e "  啟動：sudo systemctl start nginx"
    fi

    echo ""

    # --------------------------------------------------------
    # FFmpeg 推流狀態
    # --------------------------------------------------------
    echo -e "  ${BOLD}📤 FFmpeg 推流進程${NC}"
    echo -e "  ─────────────────────────────────────────"

    local ffmpeg_pids
    ffmpeg_pids=$(pgrep -f "ffmpeg.*rtmp" 2>/dev/null || echo "")

    if [ -n "$ffmpeg_pids" ]; then
        echo -e "  狀態：${GREEN}● 推流中${NC}"
        while IFS= read -r pid; do
            if [ -n "$pid" ]; then
                local proc_cpu proc_mem
                proc_cpu=$(ps -p "$pid" -o %cpu --no-headers 2>/dev/null | xargs || echo "N/A")
                proc_mem=$(ps -p "$pid" -o %mem --no-headers 2>/dev/null | xargs || echo "N/A")
                local cmd_brief
                cmd_brief=$(ps -p "$pid" -o args --no-headers 2>/dev/null | \
                    grep -oP '(?<=-i )\S+' | head -1 || echo "N/A")
                echo -e "  PID ${pid}：CPU ${proc_cpu}%  MEM ${proc_mem}%"
                echo -e "    來源：$cmd_brief"
            fi
        done <<< "$ffmpeg_pids"
    else
        echo -e "  狀態：${RED}● 未推流${NC}"
        echo -e "  啟動：sudo systemctl start stream-relay"
        echo -e "     或：./scripts/stream_relay.sh"
    fi

    echo ""

    # --------------------------------------------------------
    # stream-relay 服務狀態
    # --------------------------------------------------------
    echo -e "  ${BOLD}⚙️  systemd 服務狀態${NC}"
    echo -e "  ─────────────────────────────────────────"

    for svc in nginx stream-relay; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            local uptime_info
            uptime_info=$(systemctl status "$svc" 2>/dev/null | \
                grep "Active:" | sed 's/.*Active: //' | head -1 || echo "")
            echo -e "  ${svc}：${GREEN}● 運行中${NC}  ${uptime_info}"
        elif systemctl list-unit-files "$svc.service" &>/dev/null 2>&1; then
            echo -e "  ${svc}：${RED}● 停止${NC}"
        else
            echo -e "  ${svc}：${YELLOW}● 未安裝${NC}"
        fi
    done

    echo ""

    # --------------------------------------------------------
    # 推流資訊摘要
    # --------------------------------------------------------
    echo -e "  ${BOLD}📋 串流設定摘要${NC}"
    echo -e "  ─────────────────────────────────────────"
    echo -e "  輸入：${INPUT_SOURCE:-未設定}"
    echo -e "  輸出：${RTMP_OUTPUT:-未設定}"
    echo -e "  編碼：${VIDEO_CODEC:-N/A} / ${AUDIO_CODEC:-N/A}"
    echo -e "  位元率：${VIDEO_BITRATE:-N/A} (視訊) / ${AUDIO_BITRATE:-N/A} (音訊)"

    echo ""
    echo -e "  ${CYAN}按 Ctrl+C 退出監控${NC}"
}

# 主監控迴圈
main() {
    while true; do
        draw_monitor
        sleep "$INTERVAL"
    done
}

trap 'echo -e "\n${NC}監控已退出"; exit 0' SIGINT SIGTERM

main
