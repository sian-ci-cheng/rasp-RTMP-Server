#!/bin/bash
# ============================================================
# 樹莓派4 RTMP 推流伺服器 - 安裝腳本
# Raspberry Pi 4 RTMP Streaming Server - Setup Script
# ============================================================
# 使用方式：sudo ./scripts/setup.sh
# ============================================================

set -e

# 顏色輸出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $1"; }

# ============================================================
# 前置檢查
# ============================================================
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "請以 root 身份執行：sudo $0"
        exit 1
    fi
}

check_raspberry_pi() {
    if ! grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
        log_warn "未偵測到樹莓派硬體，將跳過硬體加速設定"
        IS_RPI=false
    else
        PI_MODEL=$(cat /proc/device-tree/model)
        log_info "偵測到：$PI_MODEL"
        IS_RPI=true
    fi
}

check_network_interface() {
    log_step "檢查網路孔（乙太網路）介面..."
    if ip link show eth0 &>/dev/null; then
        ETH_STATUS=$(ip link show eth0 | grep -oP '(?<=state )\w+')
        log_info "eth0 狀態：$ETH_STATUS"
        if [ "$ETH_STATUS" == "UP" ]; then
            ETH_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet )\S+' | cut -d/ -f1)
            log_info "eth0 IP 位址：$ETH_IP"
        fi
    else
        log_warn "未找到 eth0 介面，可能使用不同名稱（如 enp2s0）"
        log_info "可用網路介面："
        ip link show | grep -E "^[0-9]+: " | awk '{print "  " $2}' | tr -d ':'
    fi
}

# ============================================================
# 安裝相依套件
# ============================================================
install_dependencies() {
    log_step "更新套件清單..."
    apt-get update -qq

    log_step "安裝基礎套件..."
    apt-get install -y \
        curl \
        wget \
        git \
        build-essential \
        pkg-config \
        python3 \
        python3-pip \
        python3-venv

    log_step "安裝 FFmpeg（含硬體加速支援）..."
    apt-get install -y \
        ffmpeg \
        libavcodec-dev \
        libavformat-dev \
        libavutil-dev \
        libswscale-dev

    # 確認 FFmpeg 版本
    FFMPEG_VERSION=$(ffmpeg -version 2>&1 | head -n1 | awk '{print $3}')
    log_info "FFmpeg 版本：$FFMPEG_VERSION"

    log_step "安裝 nginx + RTMP 模組..."
    apt-get install -y \
        nginx \
        libnginx-mod-rtmp

    # 確認 nginx 版本
    NGINX_VERSION=$(nginx -v 2>&1 | awk '{print $3}')
    log_info "nginx 版本：$NGINX_VERSION"

    log_step "安裝 Python 相依套件..."
    pip3 install -q \
        psutil \
        requests \
        colorlog

    log_info "相依套件安裝完成 ✓"
}

# ============================================================
# 樹莓派硬體加速設定
# ============================================================
setup_rpi_hardware() {
    if [ "$IS_RPI" != "true" ]; then
        return
    fi

    log_step "設定樹莓派硬體加速..."

    # 啟用 V4L2 硬體加速（H.264）
    if ! grep -q "bcm2835-v4l2" /etc/modules 2>/dev/null; then
        echo "bcm2835-v4l2" >> /etc/modules
        log_info "已啟用 bcm2835-v4l2 模組"
    fi

    # 載入 V4L2 M2M 模組
    modprobe bcm2835-v4l2 2>/dev/null || true
    modprobe v4l2-mem2mem 2>/dev/null || true

    # 確認硬體編碼器
    if v4l2-ctl --list-devices 2>/dev/null | grep -q "bcm2835"; then
        log_info "V4L2 硬體加速：已啟用 ✓"
    else
        log_warn "V4L2 硬體加速未就緒，將使用軟體編碼"
    fi

    # 設定 GPU 記憶體（確保有足夠 GPU 記憶體用於硬體加速）
    if ! grep -q "^gpu_mem=" /boot/config.txt 2>/dev/null && \
       ! grep -q "^gpu_mem=" /boot/firmware/config.txt 2>/dev/null; then
        BOOT_CONFIG="/boot/firmware/config.txt"
        [ -f "/boot/config.txt" ] && BOOT_CONFIG="/boot/config.txt"
        echo "gpu_mem=128" >> "$BOOT_CONFIG"
        log_info "已設定 GPU 記憶體為 128MB（需重開機生效）"
    fi
}

# ============================================================
# 設定 nginx RTMP 伺服器
# ============================================================
setup_nginx() {
    log_step "設定 nginx RTMP 伺服器..."

    # 備份原始設定
    if [ -f /etc/nginx/nginx.conf ]; then
        cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup
        log_info "已備份原始 nginx.conf"
    fi

    # 複製我們的設定
    cp "$PROJECT_DIR/config/nginx.conf" /etc/nginx/nginx.conf

    # 建立必要目錄
    mkdir -p /tmp/hls /tmp/dash
    mkdir -p /var/recordings
    mkdir -p /var/log/nginx

    # 設定目錄權限
    chown -R www-data:www-data /tmp/hls /tmp/dash
    chown -R www-data:www-data /var/recordings
    chmod -R 755 /tmp/hls /tmp/dash /var/recordings

    # 測試設定
    if nginx -t 2>/dev/null; then
        log_info "nginx 設定語法正確 ✓"
    else
        log_error "nginx 設定有誤，請檢查 config/nginx.conf"
        nginx -t
        exit 1
    fi

    # 啟動並設定開機自動啟動
    systemctl enable nginx
    systemctl restart nginx
    log_info "nginx RTMP 伺服器已啟動 ✓"
}

# ============================================================
# 建立日誌目錄
# ============================================================
setup_logging() {
    log_step "設定日誌目錄..."
    mkdir -p /var/log/rtmp-stream
    chown -R "$SUDO_USER:$SUDO_USER" /var/log/rtmp-stream 2>/dev/null || true
    log_info "日誌目錄：/var/log/rtmp-stream"
}

# ============================================================
# 安裝 systemd 服務
# ============================================================
install_services() {
    log_step "安裝 systemd 服務..."

    # 替換服務檔案中的路徑佔位符
    sed "s|PROJECT_DIR|$PROJECT_DIR|g" \
        "$PROJECT_DIR/systemd/stream-relay.service" \
        > /etc/systemd/system/stream-relay.service

    # 重新載入 systemd
    systemctl daemon-reload

    # 啟用服務（但不立即啟動，等用戶設定完成後再啟動）
    systemctl enable stream-relay

    log_info "systemd 服務已安裝 ✓"
    log_warn "請先編輯 config/config.env 設定輸入來源後，再執行："
    log_warn "  sudo systemctl start stream-relay"
}

# ============================================================
# 設定防火牆
# ============================================================
setup_firewall() {
    log_step "設定防火牆規則..."

    if command -v ufw &>/dev/null; then
        # UFW 防火牆
        ufw allow 1935/tcp comment 'RTMP streaming'
        ufw allow 8080/tcp comment 'RTMP stat page'
        ufw allow 80/tcp comment 'HTTP'
        log_info "UFW 防火牆規則已設定 ✓"
    elif command -v iptables &>/dev/null; then
        # iptables
        iptables -I INPUT -p tcp --dport 1935 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null || true
        log_info "iptables 規則已設定 ✓"
    else
        log_warn "未找到防火牆管理工具，請手動開放 1935 和 8080 埠"
    fi
}

# ============================================================
# 設定腳本執行權限
# ============================================================
setup_permissions() {
    log_step "設定腳本執行權限..."
    chmod +x "$PROJECT_DIR/scripts/"*.sh
    log_info "腳本權限設定完成 ✓"
}

# ============================================================
# 顯示安裝結果
# ============================================================
print_summary() {
    echo ""
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}  安裝完成！${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo ""
    echo -e "  ${BLUE}樹莓派 IP：${NC}$(hostname -I | awk '{print $1}')"
    echo -e "  ${BLUE}RTMP 推流位址：${NC}rtmp://$(hostname -I | awk '{print $1}')/live/stream"
    echo -e "  ${BLUE}HLS 播放位址：${NC}http://$(hostname -I | awk '{print $1}'):8080/hls/stream.m3u8"
    echo -e "  ${BLUE}RTMP 統計頁面：${NC}http://$(hostname -I | awk '{print $1}'):8080/stat"
    echo ""
    echo -e "  ${YELLOW}下一步：${NC}"
    echo -e "  1. 編輯設定：nano $PROJECT_DIR/config/config.env"
    echo -e "  2. 設定網路來源 INPUT_SOURCE（IP攝影機位址）"
    echo -e "  3. 設定推流目標 RTMP_OUTPUT"
    echo -e "  4. 啟動串流：sudo systemctl start stream-relay"
    echo ""
    if [ "$IS_RPI" == "true" ]; then
        echo -e "  ${YELLOW}注意：${NC}GPU 記憶體設定需重開機才能生效"
    fi
    echo ""
}

# ============================================================
# 主程式
# ============================================================
main() {
    echo -e "${BLUE}"
    echo "  ╔═══════════════════════════════════════╗"
    echo "  ║   樹莓派4 RTMP 推流伺服器 安裝程式    ║"
    echo "  ║   Raspberry Pi 4 RTMP Server Setup    ║"
    echo "  ╚═══════════════════════════════════════╝"
    echo -e "${NC}"

    check_root
    check_raspberry_pi
    check_network_interface
    install_dependencies
    setup_rpi_hardware
    setup_nginx
    setup_logging
    setup_permissions
    install_services
    setup_firewall
    print_summary
}

main "$@"
