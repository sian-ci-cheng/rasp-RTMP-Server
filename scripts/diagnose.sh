#!/bin/bash
# ============================================================
# 樹莓派4 RTMP 推流伺服器 - 診斷工具
# Raspberry Pi 4 RTMP Server - Diagnostic Tool
# ============================================================
# 使用方式：
#   ./scripts/diagnose.sh              # 完整診斷
#   ./scripts/diagnose.sh --rtsp       # 僅測試 RTSP 連線
#   ./scripts/diagnose.sh --network    # 僅測試網路狀態
#   ./scripts/diagnose.sh --services   # 僅查看服務狀態
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config/config.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC}    $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC}  $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC}  $1"; }
info() { echo -e "  ${BLUE}[INFO]${NC}  $1"; }
hdr()  { echo -e "\n${CYAN}=== $1 ===${NC}"; }

# 載入設定
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

CAMERA_IP="${CAMERA_IP:-192.168.8.12}"
CAMERA_USER="${CAMERA_USER:-admin}"
CAMERA_PASS="${CAMERA_PASS:-123456}"
NETWORK_INTERFACE="${NETWORK_INTERFACE:-eth0}"
RTMP_PORT="${RTMP_PORT:-1935}"
HTTP_STAT_PORT="${HTTP_STAT_PORT:-8080}"

# ============================================================
# 網路診斷
# ============================================================
check_network() {
    hdr "網路介面狀態"

    if ip link show "$NETWORK_INTERFACE" &>/dev/null; then
        STATE=$(ip link show "$NETWORK_INTERFACE" | grep -oP '(?<=state )\w+')
        IP=$(ip -4 addr show "$NETWORK_INTERFACE" | grep -oP '(?<=inet )\S+' | cut -d/ -f1 || true)
        if [ "$STATE" == "UP" ]; then
            ok "$NETWORK_INTERFACE 狀態：UP，IP：${IP:-未取得}"
        else
            fail "$NETWORK_INTERFACE 狀態：$STATE（請確認網路線已連接）"
        fi
    else
        fail "介面 $NETWORK_INTERFACE 不存在"
        info "可用介面："
        ip link show | grep -E "^[0-9]+: " | awk '{print "    " $2}' | tr -d ':'
    fi

    hdr "攝影機連通性測試"

    # ping 測試
    if ping -c 3 -W 2 "$CAMERA_IP" &>/dev/null; then
        RTT=$(ping -c 3 -W 2 "$CAMERA_IP" 2>/dev/null | tail -1 | awk '{print $4}' | cut -d/ -f2)
        ok "可 ping 到 $CAMERA_IP（延遲：${RTT}ms）"
    else
        fail "無法 ping 到 $CAMERA_IP"
        echo ""
        echo "    排解步驟："
        echo "    1. 確認攝影機電源已開啟"
        echo "    2. 確認網路線或 Wi-Fi 連接正常"
        echo "    3. 確認攝影機 IP 是否正確（用 arp -n 查看 ARP 表）"
        echo "    4. 執行：arp -n | grep -E '192\.168\.[0-9]+\.' 查看所有裝置"
        return
    fi

    # 掃描常見 RTSP 埠
    hdr "RTSP 埠掃描（$CAMERA_IP）"
    for port in 554 8554 80 8080 443; do
        if timeout 2 bash -c ">/dev/tcp/$CAMERA_IP/$port" 2>/dev/null; then
            ok "埠 $port 開放"
        else
            info "埠 $port 關閉 / 逾時"
        fi
    done
}

# ============================================================
# RTSP 連線診斷
# ============================================================
check_rtsp() {
    hdr "RTSP 串流測試"

    if ! command -v ffprobe &>/dev/null; then
        warn "未安裝 FFmpeg/ffprobe，略過 RTSP 測試"
        return
    fi

    # 待測試的 RTSP URL 路徑清單（SangLuWoo / Heisha / HiSilicon 常見路徑）
    declare -a RTSP_PATHS=(
        "h264/ch1/main/av_stream"
        "h264/ch1/sub/av_stream"
        "stream1"
        "stream0"
        "live/ch0"
        "live/main"
        "cam/realmonitor?channel=1&subtype=0"
        "Streaming/Channels/101"
        "video1"
        "ch01.264"
        "1"
        "0"
    )

    declare -a RTSP_PORTS=(554 8554)

    echo ""
    info "攝影機：$CAMERA_IP，帳號：$CAMERA_USER"
    echo ""

    FOUND=false
    for port in "${RTSP_PORTS[@]}"; do
        # 先確認埠是否開放
        if ! timeout 2 bash -c ">/dev/tcp/$CAMERA_IP/$port" 2>/dev/null; then
            info "跳過埠 $port（未開放）"
            continue
        fi
        info "測試埠 $port..."
        for path in "${RTSP_PATHS[@]}"; do
            url="rtsp://${CAMERA_USER}:${CAMERA_PASS}@${CAMERA_IP}:${port}/${path}"
            result=$(timeout 8 ffprobe -v quiet -rtsp_transport tcp \
                     -show_entries stream=codec_type,codec_name,width,height,r_frame_rate \
                     -of default=noprint_wrappers=1 "$url" 2>/dev/null)
            if [ -n "$result" ]; then
                ok "找到串流！"
                echo ""
                echo "    URL：$url"
                echo ""
                echo "    串流資訊："
                echo "$result" | sed 's/^/      /'
                echo ""
                info "請將以下設定更新到 config/config.env："
                echo ""
                echo "    INPUT_SOURCE=$url"
                echo ""
                FOUND=true
                break 2
            fi
        done
    done

    if ! $FOUND; then
        fail "未找到可用的 RTSP 串流"
        echo ""
        echo "    可能原因："
        echo "    1. 攝影機 RTSP 服務未啟用（請登入攝影機網頁界面啟用）"
        echo "    2. 帳號密碼錯誤（目前：${CAMERA_USER}/${CAMERA_PASS}）"
        echo "    3. RTSP 路徑不在已知列表中（請查閱攝影機手冊）"
        echo "    4. 攝影機防火牆封鎖 RTSP 埠"
        echo ""
        echo "    手動測試（替換 YOUR_PATH）："
        echo "    ffprobe -v quiet -rtsp_transport tcp \\"
        echo "      rtsp://${CAMERA_USER}:${CAMERA_PASS}@${CAMERA_IP}:554/YOUR_PATH"
    fi
}

# ============================================================
# nginx / RTMP 服務診斷
# ============================================================
check_services() {
    hdr "nginx RTMP 服務狀態"

    if systemctl is-active nginx &>/dev/null; then
        ok "nginx 正在運行"
    else
        fail "nginx 未運行"
        echo "    執行：sudo systemctl start nginx"
    fi

    # 檢查 RTMP 埠
    if ss -tlnp 2>/dev/null | grep -q ":$RTMP_PORT"; then
        ok "RTMP 埠 $RTMP_PORT 監聽中"
    else
        fail "RTMP 埠 $RTMP_PORT 未開放"
    fi

    # 檢查 HTTP 統計埠
    if ss -tlnp 2>/dev/null | grep -q ":$HTTP_STAT_PORT"; then
        ok "HTTP 統計埠 $HTTP_STAT_PORT 監聽中"
    else
        fail "HTTP 統計埠 $HTTP_STAT_PORT 未開放"
    fi

    hdr "stream-relay 服務狀態"

    if systemctl is-active stream-relay &>/dev/null; then
        ok "stream-relay 正在運行"
        # 顯示最近 5 行日誌
        info "最近日誌（最後 5 行）："
        journalctl -u stream-relay -n 5 --no-pager 2>/dev/null | sed 's/^/    /' || true
    else
        RELAY_STATUS=$(systemctl is-active stream-relay 2>/dev/null || echo "unknown")
        if [ "$RELAY_STATUS" == "inactive" ]; then
            warn "stream-relay 未啟動（inactive）"
            echo "    執行：sudo systemctl start stream-relay"
        else
            fail "stream-relay 狀態：$RELAY_STATUS"
            echo "    查看日誌：journalctl -u stream-relay -n 20"
        fi
    fi

    hdr "FFmpeg 進程"

    if pgrep -x ffmpeg &>/dev/null; then
        ok "FFmpeg 正在運行"
        ps aux | grep "[f]fmpeg" | awk '{print "    PID:"$2" CPU:"$3"% MEM:"$4"%"}'
    else
        info "FFmpeg 目前未運行"
    fi
}

# ============================================================
# 防火牆診斷
# ============================================================
check_firewall() {
    hdr "防火牆設定"

    if command -v ufw &>/dev/null; then
        UFW_STATUS=$(ufw status 2>/dev/null | head -1)
        info "UFW 狀態：$UFW_STATUS"

        if ufw status 2>/dev/null | grep -q "^Status: active"; then
            for port in 1935 8080; do
                if ufw status 2>/dev/null | grep -qE "^${port}|^${port}/tcp"; then
                    ok "UFW 已允許 $port/tcp"
                else
                    fail "UFW 未允許 $port/tcp"
                    echo "    執行：sudo ufw allow $port/tcp"
                fi
            done
        else
            info "UFW 未啟用，無需設定"
        fi
    elif command -v iptables &>/dev/null; then
        for port in 1935 8080; do
            if iptables -L INPUT 2>/dev/null | grep -q "dpt:$port"; then
                ok "iptables 已允許埠 $port"
            else
                warn "iptables 未明確允許埠 $port"
                echo "    執行：sudo iptables -I INPUT -p tcp --dport $port -j ACCEPT"
            fi
        done
    fi
}

# ============================================================
# HLS 輸出診斷
# ============================================================
check_hls() {
    hdr "HLS 輸出狀態"

    HLS_DIR="${HLS_PATH:-/tmp/hls}"

    if [ -d "$HLS_DIR" ]; then
        ok "HLS 目錄存在：$HLS_DIR"

        # 檢查 .m3u8 文件
        M3U8_COUNT=$(find "$HLS_DIR" -name "*.m3u8" 2>/dev/null | wc -l)
        TS_COUNT=$(find "$HLS_DIR" -name "*.ts" 2>/dev/null | wc -l)

        if [ "$M3U8_COUNT" -gt 0 ]; then
            ok "找到 $M3U8_COUNT 個 .m3u8 播放清單，$TS_COUNT 個 .ts 片段"
            find "$HLS_DIR" -name "*.m3u8" 2>/dev/null | while read -r f; do
                info "  $(basename "$f")"
            done

            # 顯示 Mac 播放指令
            PI_IP=$(ip -4 addr show "$NETWORK_INTERFACE" 2>/dev/null | grep -oP '(?<=inet )\S+' | cut -d/ -f1 || echo "樹莓派IP")
            STREAM_KEY="${STREAM_KEY:-stream}"
            echo ""
            info "Mac/VLC HLS 播放位址："
            echo "    http://${PI_IP}:${HTTP_STAT_PORT}/hls/${STREAM_KEY}.m3u8"
        else
            warn "HLS 目錄存在但無串流文件（串流可能未啟動）"
        fi

        # 檢查目錄權限
        if [ -w "$HLS_DIR" ]; then
            ok "HLS 目錄可寫入"
        else
            fail "HLS 目錄無寫入權限"
            echo "    執行：sudo chmod 777 $HLS_DIR"
        fi
    else
        warn "HLS 目錄不存在：$HLS_DIR"
        echo "    執行：sudo mkdir -p $HLS_DIR && sudo chmod 777 $HLS_DIR"
    fi
}

# ============================================================
# 系統資源診斷
# ============================================================
check_resources() {
    hdr "系統資源"

    # CPU 溫度（樹莓派）
    if command -v vcgencmd &>/dev/null; then
        TEMP=$(vcgencmd measure_temp 2>/dev/null | cut -d= -f2)
        TEMP_VAL=$(echo "$TEMP" | tr -d "'C")
        if (( $(echo "$TEMP_VAL > 80" | bc -l 2>/dev/null || echo 0) )); then
            fail "CPU 溫度過高：$TEMP（> 80°C，可能降頻）"
        else
            ok "CPU 溫度：$TEMP"
        fi
    fi

    # 記憶體
    MEM_FREE=$(free -m | awk '/Mem:/{print $4}')
    MEM_TOTAL=$(free -m | awk '/Mem:/{print $2}')
    if [ "$MEM_FREE" -lt 200 ]; then
        warn "可用記憶體不足：${MEM_FREE}MB / ${MEM_TOTAL}MB"
    else
        ok "可用記憶體：${MEM_FREE}MB / ${MEM_TOTAL}MB"
    fi

    # 磁碟
    DISK_FREE=$(df -BM / | awk 'NR==2{print $4}' | tr -d 'M')
    if [ "$DISK_FREE" -lt 500 ]; then
        warn "磁碟空間不足：${DISK_FREE}MB"
    else
        ok "磁碟可用空間：${DISK_FREE}MB"
    fi
}

# ============================================================
# 主程式
# ============================================================
MODE="all"
case "${1:-}" in
    --rtsp)    MODE="rtsp" ;;
    --network) MODE="network" ;;
    --services)MODE="services" ;;
    --firewall)MODE="firewall" ;;
    --hls)     MODE="hls" ;;
    --help|-h)
        echo "使用方式：$0 [--rtsp|--network|--services|--firewall|--hls]"
        echo "  無參數：執行完整診斷"
        exit 0 ;;
esac

echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  樹莓派4 RTMP 推流伺服器 - 診斷工具${NC}"
echo -e "${CYAN}============================================${NC}"

case "$MODE" in
    all)
        check_network
        check_services
        check_firewall
        check_hls
        check_resources
        echo ""
        info "如需測試 RTSP 連線（需等待），執行："
        echo "    $0 --rtsp"
        ;;
    rtsp)     check_rtsp ;;
    network)  check_network ;;
    services) check_services ;;
    firewall) check_firewall ;;
    hls)      check_hls ;;
esac

echo ""
