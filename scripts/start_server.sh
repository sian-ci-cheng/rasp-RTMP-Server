#!/bin/bash
# ============================================================
# 快速啟動腳本
# 一鍵啟動 RTMP 伺服器與串流中繼服務
# ============================================================
# 使用方式：sudo ./scripts/start_server.sh [start|stop|restart|status]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config/config.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 載入設定
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

show_status() {
    echo ""
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}  RTMP 服務狀態${NC}"
    echo -e "${BLUE}======================================${NC}"

    for svc in nginx stream-relay; do
        printf "  %-20s " "$svc"
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "${GREEN}● 運行中${NC}"
        else
            echo -e "${RED}● 停止${NC}"
        fi
    done

    # 顯示 FFmpeg 進程
    local ffmpeg_count
    ffmpeg_count=$(pgrep -c ffmpeg 2>/dev/null || echo 0)
    printf "  %-20s " "FFmpeg 進程"
    if [ "$ffmpeg_count" -gt 0 ]; then
        echo -e "${GREEN}● $ffmpeg_count 個進程${NC}"
    else
        echo -e "${RED}● 無進程${NC}"
    fi

    echo ""
    local host_ip
    host_ip=$(hostname -I | awk '{print $1}')
    echo -e "  RTMP 推流地址：${BLUE}rtmp://${host_ip}/live/stream${NC}"
    echo -e "  HLS 播放地址： ${BLUE}http://${host_ip}:${HTTP_STAT_PORT:-8080}/hls/stream.m3u8${NC}"
    echo -e "  統計頁面：     ${BLUE}http://${host_ip}:${HTTP_STAT_PORT:-8080}/stat${NC}"
    echo ""
}

start_services() {
    log_info "啟動 RTMP 服務..."

    # 啟動 nginx RTMP 伺服器
    if systemctl start nginx; then
        log_info "nginx 已啟動 ✓"
    else
        log_error "nginx 啟動失敗，請檢查：journalctl -xe -u nginx"
    fi

    # 啟動串流中繼
    if systemctl start stream-relay 2>/dev/null; then
        log_info "stream-relay 已啟動 ✓"
    else
        log_warn "stream-relay 服務未安裝，請先執行：sudo ./scripts/setup.sh"
        log_info "或直接執行：./scripts/stream_relay.sh"
    fi

    sleep 1
    show_status
}

stop_services() {
    log_info "停止 RTMP 服務..."

    systemctl stop stream-relay 2>/dev/null || true
    systemctl stop nginx 2>/dev/null || true

    # 停止所有 FFmpeg 推流進程
    pkill -f "ffmpeg.*rtmp" 2>/dev/null || true

    log_info "所有服務已停止"
}

restart_services() {
    stop_services
    sleep 2
    start_services
}

# 主邏輯
case "${1:-start}" in
    start)
        start_services
        ;;
    stop)
        stop_services
        ;;
    restart)
        restart_services
        ;;
    status)
        show_status
        ;;
    monitor)
        exec "$SCRIPT_DIR/stream_monitor.sh"
        ;;
    *)
        echo "使用方式：$0 [start|stop|restart|status|monitor]"
        exit 1
        ;;
esac
