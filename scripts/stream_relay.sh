#!/bin/bash
# ============================================================
# 樹莓派4 RTMP 推流 - 串流中繼腳本
# 從網路孔接收影像來源，透過 FFmpeg 推送 RTMP 串流
# ============================================================
# 使用方式：
#   ./scripts/stream_relay.sh                # 使用 config.env 設定
#   ./scripts/stream_relay.sh --source rtsp://192.168.1.100:554/stream
#   ./scripts/stream_relay.sh --help
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config/config.env"

# 顏色輸出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR]${NC} $1"; }
log_debug() { [ "${DEBUG:-false}" == "true" ] && echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG]${NC} $1" || true; }

# ============================================================
# 載入設定檔
# ============================================================
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        log_info "已載入設定檔：$CONFIG_FILE"
    else
        log_error "找不到設定檔：$CONFIG_FILE"
        exit 1
    fi

    # 套用預設值
    NETWORK_INTERFACE="${NETWORK_INTERFACE:-eth0}"
    INPUT_SOURCE="${INPUT_SOURCE:-}"
    RTMP_OUTPUT="${RTMP_OUTPUT:-rtmp://localhost/live/stream}"
    VIDEO_CODEC="${VIDEO_CODEC:-h264_v4l2m2m}"
    VIDEO_BITRATE="${VIDEO_BITRATE:-2500k}"
    VIDEO_MAXRATE="${VIDEO_MAXRATE:-3000k}"
    VIDEO_BUFSIZE="${VIDEO_BUFSIZE:-5000k}"
    VIDEO_FPS="${VIDEO_FPS:-30}"
    VIDEO_SCALE="${VIDEO_SCALE:-}"
    AUDIO_CODEC="${AUDIO_CODEC:-aac}"
    AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"
    AUDIO_SAMPLERATE="${AUDIO_SAMPLERATE:-44100}"
    RECONNECT_DELAY="${RECONNECT_DELAY:-5}"
    MAX_RECONNECT="${MAX_RECONNECT:-0}"
    CONNECTION_TIMEOUT="${CONNECTION_TIMEOUT:-10}"
    RTSP_TRANSPORT="${RTSP_TRANSPORT:-tcp}"
    LOG_LEVEL="${LOG_LEVEL:-warning}"
    LOG_FILE="${LOG_FILE:-/var/log/rtmp-stream/stream.log}"
    MULTI_OUTPUT="${MULTI_OUTPUT:-false}"
    FFMPEG_THREADS="${FFMPEG_THREADS:-0}"
    PROBESIZE="${PROBESIZE:-32768}"
    ANALYZEDURATION="${ANALYZEDURATION:-0}"
}

# ============================================================
# 解析命令列參數
# ============================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --source|-s)
                INPUT_SOURCE="$2"
                shift 2
                ;;
            --output|-o)
                RTMP_OUTPUT="$2"
                shift 2
                ;;
            --codec|-c)
                VIDEO_CODEC="$2"
                shift 2
                ;;
            --bitrate|-b)
                VIDEO_BITRATE="$2"
                shift 2
                ;;
            --scale)
                VIDEO_SCALE="$2"
                shift 2
                ;;
            --debug)
                DEBUG=true
                LOG_LEVEL=debug
                shift
                ;;
            --help|-h)
                print_help
                exit 0
                ;;
            *)
                log_warn "未知參數：$1"
                shift
                ;;
        esac
    done
}

print_help() {
    cat << EOF
使用方式：$0 [選項]

選項：
  --source, -s <url>    輸入來源 URL（覆蓋 config.env）
  --output, -o <url>    RTMP 輸出目標（覆蓋 config.env）
  --codec, -c <codec>   視訊編碼器 (h264_v4l2m2m/libx264/copy)
  --bitrate, -b <rate>  視訊位元率 (e.g., 2500k)
  --scale <WxH>         縮放解析度 (e.g., 1280x720)
  --debug               啟用除錯模式
  --help, -h            顯示此說明

範例：
  $0
  $0 --source rtsp://192.168.1.100:554/stream
  $0 --source rtsp://192.168.1.100:554/stream --output rtmp://youtube.com/live/KEY
  $0 --codec libx264 --bitrate 3000k --scale 1280x720

支援的輸入格式：
  rtsp://  - RTSP 串流（IP 攝影機最常用）
  rtmp://  - RTMP 串流輸入
  http://  - HTTP/HLS 串流
  udp://   - UDP 串流（IPTV 等）
  tcp://   - TCP 串流

設定檔：$CONFIG_FILE
EOF
}

# ============================================================
# 系統前置檢查
# ============================================================
pre_checks() {
    # 確認 FFmpeg 已安裝
    if ! command -v ffmpeg &>/dev/null; then
        log_error "未找到 FFmpeg，請先執行：sudo ./scripts/setup.sh"
        exit 1
    fi

    # 確認輸入來源已設定
    if [ -z "$INPUT_SOURCE" ]; then
        log_error "未設定輸入來源！"
        log_error "請在 config/config.env 中設定 INPUT_SOURCE"
        log_error "或使用 --source 參數指定"
        exit 1
    fi

    # 確認網路孔連線狀態
    check_network_interface

    # 確認日誌目錄存在
    LOG_DIR=$(dirname "$LOG_FILE")
    mkdir -p "$LOG_DIR" 2>/dev/null || true

    # 確認錄製目錄
    if [ "${HLS_ENABLED:-false}" == "true" ]; then
        mkdir -p "${HLS_PATH:-/tmp/hls}"
    fi
}

# ============================================================
# 檢查網路孔連線
# ============================================================
check_network_interface() {
    log_info "檢查網路孔介面：$NETWORK_INTERFACE"

    if ! ip link show "$NETWORK_INTERFACE" &>/dev/null; then
        log_warn "介面 $NETWORK_INTERFACE 不存在"
        log_info "可用介面："
        ip link show | grep -E "^[0-9]+: " | awk '{print "  "$2}' | tr -d ':'
        return
    fi

    ETH_STATE=$(ip link show "$NETWORK_INTERFACE" | grep -oP '(?<=state )\w+')
    if [ "$ETH_STATE" != "UP" ]; then
        log_warn "$NETWORK_INTERFACE 介面狀態：$ETH_STATE（非 UP）"
        log_warn "請確認網路線已正確連接"
    else
        ETH_IP=$(ip -4 addr show "$NETWORK_INTERFACE" | grep -oP '(?<=inet )\S+' | cut -d/ -f1 || echo "未取得IP")
        log_info "$NETWORK_INTERFACE 狀態：UP，IP：$ETH_IP ✓"
    fi
}

# ============================================================
# 偵測最佳編碼器
# ============================================================
detect_best_codec() {
    if [ "$VIDEO_CODEC" != "auto" ]; then
        return
    fi

    log_info "自動偵測最佳視訊編碼器..."

    # 優先使用樹莓派 V4L2 硬體加速
    if ffmpeg -encoders 2>/dev/null | grep -q "h264_v4l2m2m"; then
        # 測試是否實際可用
        if ffmpeg -f lavfi -i nullsrc=s=320x240 -vframes 1 \
                  -c:v h264_v4l2m2m -f null - 2>/dev/null; then
            VIDEO_CODEC="h264_v4l2m2m"
            log_info "使用樹莓派硬體加速編碼器：h264_v4l2m2m ✓"
            return
        fi
    fi

    # 退回軟體編碼
    VIDEO_CODEC="libx264"
    log_warn "使用軟體編碼器：libx264（CPU 使用率較高）"
}

# ============================================================
# 建構 FFmpeg 命令
# ============================================================
build_ffmpeg_cmd() {
    local input_source="$1"

    # 基礎命令
    local cmd="ffmpeg -hide_banner"

    # 全域選項
    cmd+=" -loglevel $LOG_LEVEL"
    cmd+=" -threads $FFMPEG_THREADS"

    # --------------------------------------------------------
    # 輸入選項（依來源類型設定）
    # --------------------------------------------------------
    local input_proto="${input_source%%://*}"

    case "$input_proto" in
        rtsp)
            # RTSP 輸入（IP 攝影機）
            # use_wallclock_as_timestamps 修正 Non-monotonous DTS 問題
            cmd+=" -use_wallclock_as_timestamps 1"
            cmd+=" -rtsp_transport $RTSP_TRANSPORT"
            cmd+=" -stimeout $((CONNECTION_TIMEOUT * 1000000))"
            cmd+=" -i \"$input_source\""
            log_debug "使用 RTSP 輸入，傳輸協定：$RTSP_TRANSPORT"
            ;;
        rtmp)
            # RTMP 輸入
            cmd+=" -timeout $((CONNECTION_TIMEOUT * 1000000))"
            cmd+=" -i \"$input_source\""
            log_debug "使用 RTMP 輸入"
            ;;
        http|https)
            # HTTP/HLS 輸入
            cmd+=" -reconnect 1"
            cmd+=" -reconnect_at_eof 1"
            cmd+=" -reconnect_streamed 1"
            cmd+=" -reconnect_delay_max 30"
            cmd+=" -i \"$input_source\""
            log_debug "使用 HTTP/HLS 輸入"
            ;;
        udp)
            # UDP 輸入（IPTV 多播等）
            cmd+=" -probesize $PROBESIZE"
            cmd+=" -analyzeduration $ANALYZEDURATION"
            cmd+=" -i \"$input_source\""
            log_debug "使用 UDP 輸入"
            ;;
        tcp)
            # TCP 輸入
            cmd+=" -i \"$input_source\""
            log_debug "使用 TCP 輸入"
            ;;
        *)
            # 其他輸入
            cmd+=" -i \"$input_source\""
            log_warn "未知輸入協定：$input_proto，使用預設輸入選項"
            ;;
    esac

    # --------------------------------------------------------
    # 視訊編碼選項
    # --------------------------------------------------------
    if [ "$VIDEO_CODEC" == "copy" ]; then
        # 直接複製，不轉碼（延遲最低）
        cmd+=" -c:v copy"
        log_debug "視訊：直接複製（不轉碼）"
    else
        cmd+=" -c:v $VIDEO_CODEC"
        cmd+=" -b:v $VIDEO_BITRATE"
        cmd+=" -maxrate $VIDEO_MAXRATE"
        cmd+=" -bufsize $VIDEO_BUFSIZE"
        cmd+=" -r $VIDEO_FPS"

        # 縮放解析度
        if [ -n "$VIDEO_SCALE" ]; then
            cmd+=" -vf scale=$VIDEO_SCALE"
            log_debug "視訊縮放：$VIDEO_SCALE"
        fi

        # libx264 特定設定
        if [ "$VIDEO_CODEC" == "libx264" ]; then
            cmd+=" -preset veryfast"
            cmd+=" -tune zerolatency"
            cmd+=" -profile:v main"
            cmd+=" -level 3.1"
        fi

        # h264_v4l2m2m 特定設定（樹莓派硬體加速）
        if [ "$VIDEO_CODEC" == "h264_v4l2m2m" ]; then
            cmd+=" -num_capture_buffers 64"
        fi

        log_debug "視訊編碼器：$VIDEO_CODEC，位元率：$VIDEO_BITRATE"
    fi

    # --------------------------------------------------------
    # 音訊編碼選項
    # --------------------------------------------------------
    if [ "$AUDIO_CODEC" == "copy" ]; then
        cmd+=" -c:a copy"
        log_debug "音訊：直接複製"
    else
        cmd+=" -c:a $AUDIO_CODEC"
        cmd+=" -b:a $AUDIO_BITRATE"
        cmd+=" -ar $AUDIO_SAMPLERATE"
        log_debug "音訊編碼器：$AUDIO_CODEC，位元率：$AUDIO_BITRATE"
    fi

    # --------------------------------------------------------
    # 輸出格式設定
    # --------------------------------------------------------
    cmd+=" -f flv"
    cmd+=" -flvflags no_duration_filesize"

    # --------------------------------------------------------
    # 多路輸出設定
    # --------------------------------------------------------
    if [ "${MULTI_OUTPUT:-false}" == "true" ] && \
       [ -n "${EXTRA_OUTPUT_1:-}" ] && \
       [ -n "${EXTRA_OUTPUT_2:-}" ]; then
        # 使用 tee muxer 同時推至多個目標
        cmd+=" -map 0:v -map 0:a"
        cmd+=" -f tee"
        local tee_targets="[f=flv]$RTMP_OUTPUT"
        [ -n "${EXTRA_OUTPUT_1:-}" ] && tee_targets+="|[f=flv]$EXTRA_OUTPUT_1"
        [ -n "${EXTRA_OUTPUT_2:-}" ] && tee_targets+="|[f=flv]$EXTRA_OUTPUT_2"
        cmd+=" \"$tee_targets\""
        log_info "多路推流模式：$(echo "$tee_targets" | tr '|' '\n' | wc -l) 個目標"
    else
        cmd+=" \"$RTMP_OUTPUT\""
    fi

    echo "$cmd"
}

# ============================================================
# 訊號處理
# ============================================================
FFMPEG_PID=""
RUNNING=true

cleanup() {
    RUNNING=false
    if [ -n "$FFMPEG_PID" ] && kill -0 "$FFMPEG_PID" 2>/dev/null; then
        log_info "停止 FFmpeg 進程 (PID: $FFMPEG_PID)..."
        kill -TERM "$FFMPEG_PID" 2>/dev/null || true
        wait "$FFMPEG_PID" 2>/dev/null || true
    fi
    log_info "串流已停止"
}

trap cleanup SIGTERM SIGINT SIGQUIT

# ============================================================
# 主串流迴圈（含自動重連）
# ============================================================
run_stream() {
    local reconnect_count=0
    local last_start_time=0

    log_info "=========================================="
    log_info "開始 RTMP 串流推流"
    log_info "  輸入來源：$INPUT_SOURCE"
    log_info "  推流目標：$RTMP_OUTPUT"
    log_info "  視訊編碼：$VIDEO_CODEC ($VIDEO_BITRATE)"
    log_info "  音訊編碼：$AUDIO_CODEC ($AUDIO_BITRATE)"
    log_info "  網路介面：$NETWORK_INTERFACE"
    log_info "=========================================="

    while $RUNNING; do
        local current_time
        current_time=$(date +%s)

        # 防止過快重連（最少等待 2 秒）
        local time_since_last=$((current_time - last_start_time))
        if [ $last_start_time -ne 0 ] && [ $time_since_last -lt 2 ]; then
            sleep $((2 - time_since_last))
        fi

        # 檢查最大重連次數
        if [ "$MAX_RECONNECT" -gt 0 ] && [ $reconnect_count -ge "$MAX_RECONNECT" ]; then
            log_error "已達最大重連次數 ($MAX_RECONNECT)，停止重連"
            break
        fi

        last_start_time=$(date +%s)
        reconnect_count=$((reconnect_count + 1))

        if [ $reconnect_count -gt 1 ]; then
            log_warn "第 $reconnect_count 次嘗試連線..."
        fi

        # 建構 FFmpeg 命令
        local ffmpeg_cmd
        ffmpeg_cmd=$(build_ffmpeg_cmd "$INPUT_SOURCE")

        log_debug "FFmpeg 指令：$ffmpeg_cmd"

        # 執行 FFmpeg
        if [ "${LOG_LEVEL}" == "debug" ] || [ "${DEBUG:-false}" == "true" ]; then
            eval "$ffmpeg_cmd" &
        else
            eval "$ffmpeg_cmd" >> "$LOG_FILE" 2>&1 &
        fi

        FFMPEG_PID=$!
        log_info "FFmpeg 已啟動 (PID: $FFMPEG_PID)"

        # 等待 FFmpeg 完成
        wait $FFMPEG_PID 2>/dev/null
        EXIT_CODE=$?
        FFMPEG_PID=""

        if ! $RUNNING; then
            break
        fi

        if [ $EXIT_CODE -eq 0 ]; then
            log_info "FFmpeg 正常結束"
            break
        else
            log_warn "FFmpeg 異常結束（退出碼：$EXIT_CODE），${RECONNECT_DELAY}秒後重連..."
            sleep "$RECONNECT_DELAY"
        fi
    done

    log_info "串流中繼結束"
}

# ============================================================
# 主程式
# ============================================================
main() {
    load_config
    parse_args "$@"
    detect_best_codec
    pre_checks
    run_stream
}

main "$@"
