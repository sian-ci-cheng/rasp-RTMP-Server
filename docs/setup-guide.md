# 樹莓派4 RTMP 推流伺服器 - 詳細安裝設定指南

## 目錄

1. [系統需求](#1-系統需求)
2. [硬體連接](#2-硬體連接)
3. [作業系統安裝](#3-作業系統安裝)
4. [軟體安裝](#4-軟體安裝)
5. [設定輸入來源](#5-設定輸入來源)
6. [設定推流目標](#6-設定推流目標)
7. [啟動服務](#7-啟動服務)
8. [驗證串流](#8-驗證串流)
9. [常見問題排解](#9-常見問題排解)
10. [效能調整](#10-效能調整)

---

## 1. 系統需求

### 硬體
| 項目 | 最低需求 | 建議配置 |
|------|---------|---------|
| 樹莓派型號 | Raspberry Pi 4 Model B | Raspberry Pi 4 Model B 4GB+ |
| 記憶體 | 2GB RAM | 4GB RAM |
| 儲存空間 | 16GB microSD | 32GB+ Class 10 / SSD |
| 網路孔 | Gigabit Ethernet | Gigabit Ethernet |
| 電源 | USB-C 3A | 官方電源供應器 5V/3A |

### 軟體
- Raspberry Pi OS (64-bit) Bullseye 或 Bookworm
- FFmpeg 4.0+
- nginx + nginx-rtmp-module

---

## 2. 硬體連接

### 網路孔連接方式

```
情境 A：IP 攝影機 → 交換器 → 樹莓派

  [IP 攝影機]
       │ (RTSP)
       ▼
  [網路交換器]
       │
       ▼
  [樹莓派4 eth0] ──推流──> [RTMP 伺服器/平台]
```

```
情境 B：IP 攝影機 直連 樹莓派（需設定靜態IP）

  [IP 攝影機]
       │ 網路線直連
       ▼
  [樹莓派4 eth0]
```

```
情境 C：IPTV/UDP 多播 → 樹莓派

  [IPTV 來源]
       │ (UDP 多播)
       ▼
  [網路交換器/路由器]
       │
       ▼
  [樹莓派4 eth0] ──RTMP──> [推流目標]
```

### 靜態 IP 設定（IP 攝影機直連時）

編輯 `/etc/dhcpcd.conf`：

```bash
# 網路孔靜態 IP
interface eth0
static ip_address=192.168.1.50/24
static routers=192.168.1.1
static domain_name_servers=8.8.8.8 8.8.4.4
```

---

## 3. 作業系統安裝

### 使用 Raspberry Pi Imager

1. 下載 [Raspberry Pi Imager](https://www.raspberrypi.org/software/)
2. 選擇 **Raspberry Pi OS (64-bit)**
3. 進階設定（⚙️）：
   - 啟用 SSH
   - 設定 Wi-Fi（備用連線）
   - 設定主機名稱：`raspberrypi`
4. 燒錄到 microSD 卡

### 首次開機設定

```bash
# 更新系統
sudo apt update && sudo apt upgrade -y

# 啟用硬體加速
sudo raspi-config
# 選 Performance Options > GPU Memory > 128
```

---

## 4. 軟體安裝

### 方法一：自動安裝（推薦）

```bash
git clone https://github.com/shian-chi/rasp-rtmp-server.git
cd rasp-rtmp-server
chmod +x scripts/setup.sh
sudo ./scripts/setup.sh
```

### 方法二：手動安裝

```bash
# 更新套件清單
sudo apt update

# 安裝 FFmpeg
sudo apt install -y ffmpeg

# 確認硬體加速支援
ffmpeg -encoders | grep h264_v4l2m2m
# 應顯示：V..... h264_v4l2m2m    V4L2 mem2mem H.264 encoder wrapper

# 安裝 nginx + RTMP 模組
sudo apt install -y nginx libnginx-mod-rtmp

# 複製 nginx 設定
sudo cp config/nginx.conf /etc/nginx/nginx.conf
sudo nginx -t  # 測試設定
sudo systemctl restart nginx

# 安裝 Python 相依套件
pip3 install psutil requests colorlog
```

### 確認硬體加速

```bash
# 載入 V4L2 模組
sudo modprobe bcm2835-v4l2

# 確認編碼器
v4l2-ctl --list-devices
# 應顯示 bcm2835-codec

# 測試硬體編碼
ffmpeg -f lavfi -i testsrc=size=1280x720:rate=30 \
       -t 5 -c:v h264_v4l2m2m -b:v 2M /tmp/test.mp4 -y
```

---

## 5. 設定輸入來源

編輯 `config/config.env`，設定 `INPUT_SOURCE`：

### RTSP（IP 攝影機，最常用）

```bash
# 一般 RTSP 攝影機
INPUT_SOURCE=rtsp://192.168.1.100:554/stream

# 帶有帳號密碼
INPUT_SOURCE=rtsp://admin:password@192.168.1.100:554/stream

# Hikvision 攝影機
INPUT_SOURCE=rtsp://admin:password@192.168.1.100:554/Streaming/Channels/101

# Dahua 攝影機
INPUT_SOURCE=rtsp://admin:password@192.168.1.100:554/cam/realmonitor?channel=1&subtype=0

# Reolink 攝影機
INPUT_SOURCE=rtsp://admin:password@192.168.1.100:554/h264Preview_01_main
```

### RTMP 輸入

```bash
INPUT_SOURCE=rtmp://192.168.1.200/live/stream
```

### HLS 輸入

```bash
INPUT_SOURCE=http://192.168.1.300/hls/stream.m3u8
```

### UDP 多播（IPTV）

```bash
INPUT_SOURCE=udp://239.0.0.1:1234
# 或帶有介面指定
INPUT_SOURCE=udp://239.0.0.1:1234?localaddr=192.168.1.50
```

---

## 6. 設定推流目標

### 推流至本地 nginx RTMP 伺服器

```bash
RTMP_OUTPUT=rtmp://localhost/live/stream
```

播放地址：`rtmp://樹莓派IP/live/stream`

### 推流至 YouTube Live

1. 開啟 [YouTube 直播設定](https://studio.youtube.com)
2. 取得串流金鑰
3. 設定：

```bash
RTMP_OUTPUT=rtmp://a.rtmp.youtube.com/live2/YOUR-STREAM-KEY
```

### 推流至 Twitch

```bash
RTMP_OUTPUT=rtmp://live.twitch.tv/app/YOUR-STREAM-KEY
```

### 同時推至多個目標

```bash
MULTI_OUTPUT=true
RTMP_OUTPUT=rtmp://localhost/live/stream
EXTRA_OUTPUT_1=rtmp://a.rtmp.youtube.com/live2/YT-KEY
EXTRA_OUTPUT_2=rtmp://live.twitch.tv/app/TWITCH-KEY
```

---

## 7. 啟動服務

```bash
# 啟動 nginx RTMP 伺服器
sudo systemctl start nginx
sudo systemctl enable nginx   # 開機自動啟動

# 啟動串流中繼
sudo systemctl start stream-relay
sudo systemctl enable stream-relay

# 查看狀態
sudo systemctl status stream-relay

# 查看即時日誌
journalctl -f -u stream-relay

# 監控介面
./scripts/stream_monitor.sh
```

### 手動測試（不使用 systemd）

```bash
# 直接執行
./scripts/stream_relay.sh

# 指定來源
./scripts/stream_relay.sh --source rtsp://192.168.1.100:554/stream

# 除錯模式
./scripts/stream_relay.sh --debug
```

---

## 8. 驗證串流

### 使用 FFplay 播放

```bash
# 播放 RTMP 串流
ffplay rtmp://樹莓派IP/live/stream

# 播放 HLS 串流
ffplay http://樹莓派IP:8080/hls/stream.m3u8
```

### 使用 VLC 播放

1. 開啟 VLC
2. 媒體 > 開啟網路串流
3. 輸入：`rtmp://樹莓派IP/live/stream`

### 查看 RTMP 統計頁面

瀏覽器開啟：`http://樹莓派IP:8080/stat`

### 查看串流延遲

```bash
# 測量端對端延遲
ffprobe -show_entries format=start_time -of default=noprint_wrappers=1 \
        rtmp://localhost/live/stream
```

---

## 9. 常見問題排解

### 問題：串流無法連線

```bash
# 確認 FFmpeg 進程
ps aux | grep ffmpeg

# 確認 nginx 運行
sudo systemctl status nginx

# 確認埠是否開放
sudo netstat -tlnp | grep 1935

# 查看 FFmpeg 日誌
tail -f /var/log/rtmp-stream/stream.log
```

### 問題：畫面卡頓或延遲

```bash
# 檢查 CPU 使用率
htop

# 切換硬體加速
nano config/config.env
# 設定 VIDEO_CODEC=h264_v4l2m2m

# 降低位元率
VIDEO_BITRATE=1500k

# 降低解析度
VIDEO_SCALE=1280x720
```

### 問題：硬體加速不可用

```bash
# 載入模組
sudo modprobe bcm2835-v4l2
echo "bcm2835-v4l2" | sudo tee -a /etc/modules

# 確認 GPU 記憶體
vcgencmd get_mem gpu

# 若 GPU 記憶體不足，增加到 128MB
sudo raspi-config
# Performance Options > GPU Memory > 128
# 重開機
```

### 問題：網路孔未偵測到

```bash
# 確認介面
ip link show

# 若介面名稱不同（如 enp2s0）
nano config/config.env
# 修改 NETWORK_INTERFACE=enp2s0
```

### 問題：RTSP 連線被拒絕（Connection refused）

```bash
# 步驟 1：確認攝影機可以 ping 到
ping -c 3 192.168.8.12

# 步驟 2：掃描攝影機開放的埠（554 或 8554）
for port in 554 8554 80 8080; do
  timeout 2 bash -c ">/dev/tcp/192.168.8.12/$port" 2>/dev/null \
    && echo "埠 $port 開放" || echo "埠 $port 關閉"
done

# 步驟 3：自動掃描所有可能的 RTSP 路徑
./scripts/diagnose.sh --rtsp
```

#### SangLuWoo V3-365C-AR 常見 RTSP 路徑

```bash
# HiSilicon 主碼流（最常見，已確認相容）
rtsp://admin:123456@192.168.8.12:554/h264/ch1/main/av_stream

# 若主路徑不通，嘗試替代路徑：
rtsp://admin:123456@192.168.8.12:554/h264/ch1/sub/av_stream   # 子碼流
rtsp://admin:123456@192.168.8.12:8554/h264/ch1/main/av_stream # 替代埠 8554
rtsp://admin:123456@192.168.8.12:554/stream1
rtsp://admin:123456@192.168.8.12:554/live/ch0
```

#### 確認 RTSP 路徑

```bash
# 使用 ffprobe 逐一測試，有輸出即為可用
ffprobe -v quiet -rtsp_transport tcp \
  -show_entries stream=codec_name,width,height \
  rtsp://admin:123456@192.168.8.12:554/h264/ch1/main/av_stream
```

### 問題：Mac 無法播放 HLS 串流（VLC / ffplay）

nginx-rtmp 1.1.4 與較新版 FFmpeg（7+）的 RTMP 相容性有問題，
建議改用 **HLS** 方式在 Mac 上觀看：

```bash
# 在樹莓派上確認防火牆已開放 8080
sudo ufw status | grep 8080
# 若未開放：
sudo ufw allow 8080/tcp

# Mac 上用 ffplay 播放 HLS
ffplay http://192.168.8.11:8080/hls/oBYS2OomLmSXZ6QUbqRq__dock.m3u8

# 或 VLC > 媒體 > 開啟網路串流，輸入：
# http://192.168.8.11:8080/hls/oBYS2OomLmSXZ6QUbqRq__dock.m3u8
```

> 樹莓派 IP 為 192.168.8.11（eth0），串流金鑰為 `STREAM_KEY`（config.env）。

---

## 10. 效能調整

### 樹莓派4 最佳設定

```bash
# config.env 最佳配置
VIDEO_CODEC=h264_v4l2m2m    # 硬體加速
VIDEO_BITRATE=2500k          # 適中位元率
VIDEO_FPS=30                 # 30fps
AUDIO_CODEC=aac
RTSP_TRANSPORT=tcp           # 穩定傳輸
RECONNECT_DELAY=3            # 快速重連
```

### 極低延遲配置

```bash
VIDEO_CODEC=copy             # 不轉碼
AUDIO_CODEC=copy
ANALYZEDURATION=0
PROBESIZE=32768
```

### 高畫質配置（需 4GB RAM）

```bash
VIDEO_CODEC=h264_v4l2m2m
VIDEO_BITRATE=6000k
VIDEO_SCALE=1920x1080
VIDEO_FPS=60
```

### 監控 CPU 溫度

```bash
# 即時監控溫度
watch -n 1 vcgencmd measure_temp

# 若溫度持續超過 80°C，建議安裝散熱片或主動散熱
```
