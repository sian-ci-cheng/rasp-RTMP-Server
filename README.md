# 樹莓派4 RTMP 推流伺服器

使用樹莓派 4 (Raspberry Pi 4) 從網路孔（乙太網路）接收影像資料，並透過 RTMP 協定進行推流。

## 系統架構

```
[網路來源]  ──網路孔(eth0)──>  [樹莓派4 RTMP伺服器]  ──RTMP推流──>  [直播平台/播放器]
 IP攝影機                       nginx-rtmp-module            YouTube / 自架伺服器
 RTSP串流                       FFmpeg 轉碼                   OBS / VLC
 HLS串流
```

## 功能特色

- 📡 **從網路孔接收**：支援 RTSP、HLS、UDP、RTMP 等多種輸入來源
- 🔄 **RTMP 推流**：透過 FFmpeg 推送至任意 RTMP 端點
- 🖥️ **本地 RTMP 伺服器**：使用 nginx-rtmp-module 建立本地中繼伺服器
- 🔁 **多路推流**：同時推送至多個目標
- 🛡️ **自動重連**：串流中斷時自動重新連線
- 🚀 **開機自動啟動**：透過 systemd 服務管理

## 目錄結構

```
Rasp-RTMP-Server/
├── README.md
├── config/
│   ├── nginx.conf          # nginx RTMP 伺服器設定
│   └── config.env          # 環境變數設定檔
├── scripts/
│   ├── setup.sh            # 安裝腳本
│   ├── start_server.sh     # 啟動 RTMP 伺服器
│   ├── stream_relay.sh     # 從網路接收並轉推 RTMP
│   └── stream_monitor.sh   # 監控串流狀態
├── src/
│   ├── rtmp_manager.py     # Python 串流管理器
│   └── health_check.py     # 健康狀態監控
├── systemd/
│   ├── rtmp-server.service # nginx RTMP 服務
│   └── stream-relay.service# 串流中繼服務
└── docs/
    └── setup-guide.md      # 詳細安裝設定指南
```

## 快速開始

### 1. 系統需求
- 樹莓派 4 Model B (建議 4GB RAM 以上)
- Raspberry Pi OS (Bullseye/Bookworm 64-bit)
- 乙太網路連線（網路孔接來源設備）

### 2. 一鍵安裝

```bash
git clone https://github.com/shian-chi/rasp-rtmp-server.git
cd rasp-rtmp-server
chmod +x scripts/setup.sh
sudo ./scripts/setup.sh
```

### 3. 設定輸入來源

編輯 `config/config.env`：

```bash
# 輸入來源（來自網路孔的設備）
INPUT_SOURCE=rtsp://192.168.1.100:554/stream   # IP攝影機 RTSP
# INPUT_SOURCE=rtmp://192.168.1.200/live/stream # RTMP 來源
# INPUT_SOURCE=http://192.168.1.300/stream.m3u8 # HLS 來源
# INPUT_SOURCE=udp://239.0.0.1:1234             # UDP 多播

# 推流目標
RTMP_OUTPUT=rtmp://localhost/live/stream        # 推至本地伺服器
# RTMP_OUTPUT=rtmp://a.rtmp.youtube.com/live2/YOUR-STREAM-KEY  # YouTube
```

### 4. 啟動服務

```bash
# 啟動 RTMP 伺服器
sudo systemctl start rtmp-server

# 啟動串流中繼
sudo systemctl start stream-relay

# 查看狀態
sudo systemctl status stream-relay
```

### 5. 播放測試

使用 VLC 或 FFplay 播放：
```bash
ffplay rtmp://樹莓派IP/live/stream
# 或
vlc rtmp://樹莓派IP/live/stream
```

## 詳細文件

請參閱 [安裝設定指南](docs/setup-guide.md)

## 授權

MIT License
=======
# rtsp-RTMP-Server
>>>>>>> 1f54457fb7b883d07ae5f0386bb5fc87462c7e24
