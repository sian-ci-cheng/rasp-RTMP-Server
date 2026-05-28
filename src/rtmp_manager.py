#!/usr/bin/env python3
"""
樹莓派4 RTMP 推流管理器
Raspberry Pi 4 RTMP Stream Manager

功能：
- 從網路孔（eth0）接收來源影像
- 管理 FFmpeg 推流進程
- 自動重連機制
- 健康狀態監控
- 多路推流支援
"""

import os
import sys
import time
import signal
import logging
import subprocess
import threading
import socket
import json
from pathlib import Path
from typing import Optional, List, Dict
from dataclasses import dataclass, field
from datetime import datetime

# ============================================================
# 設定
# ============================================================
CONFIG_FILE = Path(__file__).parent.parent / "config" / "config.env"
LOG_DIR = Path("/var/log/rtmp-stream")
LOG_DIR.mkdir(parents=True, exist_ok=True)

# 日誌設定
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_DIR / "rtmp_manager.log"),
    ],
)
logger = logging.getLogger("RTMPManager")


# ============================================================
# 資料類別
# ============================================================
@dataclass
class StreamConfig:
    """串流設定"""
    # 網路設定
    network_interface: str = "eth0"

    # 輸入來源
    input_source: str = ""
    rtsp_transport: str = "tcp"
    connection_timeout: int = 10

    # RTMP 輸出
    rtmp_output: str = "rtmp://localhost/live/stream"
    stream_key: str = "live_stream"

    # 多路輸出
    multi_output: bool = False
    extra_outputs: List[str] = field(default_factory=list)

    # 視訊設定
    video_codec: str = "h264_v4l2m2m"
    video_bitrate: str = "2500k"
    video_maxrate: str = "3000k"
    video_bufsize: str = "5000k"
    video_fps: int = 30
    video_scale: str = ""

    # 音訊設定
    audio_codec: str = "aac"
    audio_bitrate: str = "128k"
    audio_samplerate: int = 44100

    # 穩定性設定
    reconnect_delay: int = 5
    max_reconnect: int = 0

    # 日誌設定
    log_level: str = "warning"

    @classmethod
    def from_env_file(cls, config_path: Path) -> "StreamConfig":
        """從 .env 設定檔載入設定"""
        config = cls()

        if not config_path.exists():
            logger.warning(f"設定檔不存在：{config_path}")
            return config

        env_vars: Dict[str, str] = {}
        with open(config_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, _, value = line.partition("=")
                    # 移除行內註解
                    value = value.split("#")[0].strip()
                    # 移除引號
                    value = value.strip("\"'")
                    env_vars[key.strip()] = value

        # 套用設定值
        config.network_interface = env_vars.get("NETWORK_INTERFACE", config.network_interface)
        config.input_source = env_vars.get("INPUT_SOURCE", config.input_source)
        config.rtsp_transport = env_vars.get("RTSP_TRANSPORT", config.rtsp_transport)
        config.connection_timeout = int(env_vars.get("CONNECTION_TIMEOUT", config.connection_timeout))
        config.rtmp_output = env_vars.get("RTMP_OUTPUT", config.rtmp_output)
        config.stream_key = env_vars.get("STREAM_KEY", config.stream_key)
        config.multi_output = env_vars.get("MULTI_OUTPUT", "false").lower() == "true"

        # 多路輸出
        for key in ["EXTRA_OUTPUT_1", "EXTRA_OUTPUT_2", "EXTRA_OUTPUT_3"]:
            val = env_vars.get(key, "")
            if val:
                config.extra_outputs.append(val)

        config.video_codec = env_vars.get("VIDEO_CODEC", config.video_codec)
        config.video_bitrate = env_vars.get("VIDEO_BITRATE", config.video_bitrate)
        config.video_maxrate = env_vars.get("VIDEO_MAXRATE", config.video_maxrate)
        config.video_bufsize = env_vars.get("VIDEO_BUFSIZE", config.video_bufsize)
        config.video_fps = int(env_vars.get("VIDEO_FPS", config.video_fps))
        config.video_scale = env_vars.get("VIDEO_SCALE", config.video_scale)
        config.audio_codec = env_vars.get("AUDIO_CODEC", config.audio_codec)
        config.audio_bitrate = env_vars.get("AUDIO_BITRATE", config.audio_bitrate)
        config.audio_samplerate = int(env_vars.get("AUDIO_SAMPLERATE", config.audio_samplerate))
        config.reconnect_delay = int(env_vars.get("RECONNECT_DELAY", config.reconnect_delay))
        config.max_reconnect = int(env_vars.get("MAX_RECONNECT", config.max_reconnect))
        config.log_level = env_vars.get("LOG_LEVEL", config.log_level)

        logger.info(f"已從 {config_path} 載入設定")
        return config


# ============================================================
# 網路孔監控
# ============================================================
class NetworkMonitor:
    """監控網路孔（eth0）狀態"""

    def __init__(self, interface: str = "eth0"):
        self.interface = interface
        self._prev_rx = 0
        self._prev_tx = 0
        self._prev_time = time.time()

    def get_status(self) -> Dict:
        """取得網路介面狀態"""
        status = {
            "interface": self.interface,
            "state": "unknown",
            "ip": "",
            "rx_bytes": 0,
            "tx_bytes": 0,
            "rx_rate_mbps": 0.0,
            "tx_rate_mbps": 0.0,
        }

        try:
            # 讀取介面狀態
            state_file = Path(f"/sys/class/net/{self.interface}/operstate")
            if state_file.exists():
                status["state"] = state_file.read_text().strip()

            # 讀取流量統計
            rx_file = Path(f"/sys/class/net/{self.interface}/statistics/rx_bytes")
            tx_file = Path(f"/sys/class/net/{self.interface}/statistics/tx_bytes")

            if rx_file.exists():
                status["rx_bytes"] = int(rx_file.read_text())
            if tx_file.exists():
                status["tx_bytes"] = int(tx_file.read_text())

            # 計算速率
            now = time.time()
            elapsed = now - self._prev_time
            if elapsed > 0:
                rx_diff = status["rx_bytes"] - self._prev_rx
                tx_diff = status["tx_bytes"] - self._prev_tx
                status["rx_rate_mbps"] = (rx_diff * 8) / (elapsed * 1_000_000)
                status["tx_rate_mbps"] = (tx_diff * 8) / (elapsed * 1_000_000)

            self._prev_rx = status["rx_bytes"]
            self._prev_tx = status["tx_bytes"]
            self._prev_time = now

        except (OSError, ValueError) as e:
            logger.debug(f"讀取網路介面狀態失敗：{e}")

        return status

    def is_up(self) -> bool:
        """確認網路介面是否連線"""
        status = self.get_status()
        return status["state"] == "up"

    def wait_for_link(self, timeout: int = 30) -> bool:
        """等待網路連線就緒"""
        logger.info(f"等待 {self.interface} 網路連線...")
        deadline = time.time() + timeout

        while time.time() < deadline:
            if self.is_up():
                logger.info(f"{self.interface} 已連線 ✓")
                return True
            time.sleep(1)

        logger.warning(f"{self.interface} 連線逾時")
        return False


# ============================================================
# FFmpeg 推流管理器
# ============================================================
class FFmpegStreamer:
    """管理 FFmpeg 推流進程"""

    def __init__(self, config: StreamConfig):
        self.config = config
        self._process: Optional[subprocess.Popen] = None
        self._lock = threading.Lock()
        self._running = False
        self._reconnect_count = 0
        self._start_time: Optional[datetime] = None

    def build_command(self) -> List[str]:
        """建構 FFmpeg 命令列"""
        cfg = self.config
        cmd = ["ffmpeg", "-hide_banner", "-loglevel", cfg.log_level]

        # 輸入選項（依協定調整）
        input_source = cfg.input_source
        proto = input_source.split("://")[0] if "://" in input_source else ""

        if proto == "rtsp":
            cmd += [
                "-rtsp_transport", cfg.rtsp_transport,
                "-stimeout", str(cfg.connection_timeout * 1_000_000),
            ]
        elif proto in ("http", "https"):
            cmd += [
                "-reconnect", "1",
                "-reconnect_at_eof", "1",
                "-reconnect_streamed", "1",
                "-reconnect_delay_max", "30",
            ]
        elif proto == "udp":
            cmd += [
                "-probesize", "32768",
                "-analyzeduration", "0",
            ]

        cmd += ["-i", input_source]

        # 視訊編碼
        if cfg.video_codec == "copy":
            cmd += ["-c:v", "copy"]
        else:
            cmd += [
                "-c:v", cfg.video_codec,
                "-b:v", cfg.video_bitrate,
                "-maxrate", cfg.video_maxrate,
                "-bufsize", cfg.video_bufsize,
                "-r", str(cfg.video_fps),
            ]

            if cfg.video_scale:
                cmd += ["-vf", f"scale={cfg.video_scale}"]

            if cfg.video_codec == "libx264":
                cmd += ["-preset", "veryfast", "-tune", "zerolatency"]

        # 音訊編碼
        if cfg.audio_codec == "copy":
            cmd += ["-c:a", "copy"]
        else:
            cmd += [
                "-c:a", cfg.audio_codec,
                "-b:a", cfg.audio_bitrate,
                "-ar", str(cfg.audio_samplerate),
            ]

        # 輸出格式
        cmd += ["-f", "flv", "-flvflags", "no_duration_filesize"]

        # 多路輸出
        if cfg.multi_output and cfg.extra_outputs:
            outputs = [f"[f=flv]{cfg.rtmp_output}"]
            for extra in cfg.extra_outputs:
                outputs.append(f"[f=flv]{extra}")
            cmd += ["-map", "0:v", "-map", "0:a", "-f", "tee", "|".join(outputs)]
        else:
            cmd.append(cfg.rtmp_output)

        return cmd

    def start(self) -> bool:
        """啟動推流"""
        with self._lock:
            if self._process and self._process.poll() is None:
                logger.warning("FFmpeg 已在運行中")
                return False

            cmd = self.build_command()
            logger.info(f"啟動 FFmpeg：{' '.join(cmd[:8])}...")

            try:
                self._process = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    universal_newlines=True,
                )
                self._running = True
                self._start_time = datetime.now()
                self._reconnect_count += 1
                logger.info(f"FFmpeg 已啟動 (PID: {self._process.pid})")
                return True
            except FileNotFoundError:
                logger.error("找不到 ffmpeg，請先安裝：sudo apt install ffmpeg")
                return False
            except Exception as e:
                logger.error(f"啟動 FFmpeg 失敗：{e}")
                return False

    def stop(self):
        """停止推流"""
        with self._lock:
            self._running = False
            if self._process:
                logger.info("停止 FFmpeg...")
                try:
                    self._process.terminate()
                    self._process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self._process.kill()
                    self._process.wait()
                self._process = None
                logger.info("FFmpeg 已停止")

    def is_running(self) -> bool:
        """確認推流是否進行中"""
        if not self._process:
            return False
        return self._process.poll() is None

    def get_exit_code(self) -> Optional[int]:
        """取得 FFmpeg 退出碼"""
        if self._process:
            return self._process.poll()
        return None

    def get_stats(self) -> Dict:
        """取得推流統計"""
        return {
            "running": self.is_running(),
            "pid": self._process.pid if self._process else None,
            "reconnect_count": self._reconnect_count,
            "start_time": self._start_time.isoformat() if self._start_time else None,
            "uptime_seconds": (
                (datetime.now() - self._start_time).total_seconds()
                if self._start_time and self.is_running()
                else 0
            ),
        }


# ============================================================
# RTMP 串流管理器（主程式）
# ============================================================
class RTMPStreamManager:
    """主要串流管理器，整合所有元件"""

    def __init__(self, config: StreamConfig):
        self.config = config
        self.network_monitor = NetworkMonitor(config.network_interface)
        self.streamer = FFmpegStreamer(config)
        self._running = False
        self._thread: Optional[threading.Thread] = None

        # 設定訊號處理
        signal.signal(signal.SIGTERM, self._signal_handler)
        signal.signal(signal.SIGINT, self._signal_handler)

    def _signal_handler(self, signum, frame):
        """處理系統訊號"""
        logger.info(f"收到訊號 {signum}，停止串流...")
        self.stop()

    def start(self):
        """啟動串流管理器"""
        if not self.config.input_source:
            logger.error("未設定輸入來源（INPUT_SOURCE），請編輯 config/config.env")
            sys.exit(1)

        logger.info("=" * 50)
        logger.info("樹莓派4 RTMP 推流管理器啟動")
        logger.info(f"  網路介面：{self.config.network_interface}")
        logger.info(f"  輸入來源：{self.config.input_source}")
        logger.info(f"  推流目標：{self.config.rtmp_output}")
        logger.info(f"  視訊編碼：{self.config.video_codec}")
        logger.info("=" * 50)

        # 等待網路就緒
        if not self.network_monitor.wait_for_link(timeout=30):
            logger.warning(f"{self.config.network_interface} 未就緒，但仍嘗試推流...")

        self._running = True
        self._stream_loop()

    def stop(self):
        """停止串流管理器"""
        self._running = False
        self.streamer.stop()

    def _stream_loop(self):
        """串流主迴圈（含自動重連）"""
        reconnect_count = 0

        while self._running:
            reconnect_count += 1

            # 檢查最大重連次數
            if self.config.max_reconnect > 0 and reconnect_count > self.config.max_reconnect:
                logger.error(f"已達最大重連次數 ({self.config.max_reconnect})，停止")
                break

            if reconnect_count > 1:
                logger.info(f"第 {reconnect_count} 次重連...")

            # 啟動推流
            if not self.streamer.start():
                logger.error("啟動推流失敗")
                time.sleep(self.config.reconnect_delay)
                continue

            # 等待推流結束
            while self._running and self.streamer.is_running():
                time.sleep(1)

                # 定期記錄網路狀態
                if reconnect_count == 1 and int(time.time()) % 60 == 0:
                    net_status = self.network_monitor.get_status()
                    logger.debug(
                        f"網路狀態：{net_status['state']} "
                        f"RX:{net_status['rx_rate_mbps']:.1f}Mbps "
                        f"TX:{net_status['tx_rate_mbps']:.1f}Mbps"
                    )

            if not self._running:
                break

            exit_code = self.streamer.get_exit_code()
            logger.warning(
                f"FFmpeg 結束（退出碼：{exit_code}），"
                f"{self.config.reconnect_delay} 秒後重連..."
            )
            time.sleep(self.config.reconnect_delay)

        logger.info("串流管理器已停止")

    def get_status(self) -> Dict:
        """取得完整狀態"""
        return {
            "timestamp": datetime.now().isoformat(),
            "running": self._running,
            "config": {
                "input_source": self.config.input_source,
                "rtmp_output": self.config.rtmp_output,
                "video_codec": self.config.video_codec,
            },
            "network": self.network_monitor.get_status(),
            "stream": self.streamer.get_stats(),
        }


# ============================================================
# 主程式入口
# ============================================================
def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="樹莓派4 RTMP 推流管理器",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
範例：
  python3 rtmp_manager.py
  python3 rtmp_manager.py --source rtsp://192.168.1.100:554/stream
  python3 rtmp_manager.py --status
        """
    )
    parser.add_argument("--source", help="輸入來源 URL")
    parser.add_argument("--output", help="RTMP 輸出 URL")
    parser.add_argument("--codec", help="視訊編碼器")
    parser.add_argument("--status", action="store_true", help="顯示當前狀態")
    parser.add_argument("--config", default=str(CONFIG_FILE), help="設定檔路徑")
    parser.add_argument("--debug", action="store_true", help="啟用除錯日誌")

    args = parser.parse_args()

    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)

    # 載入設定
    config = StreamConfig.from_env_file(Path(args.config))

    # 命令列覆蓋
    if args.source:
        config.input_source = args.source
    if args.output:
        config.rtmp_output = args.output
    if args.codec:
        config.video_codec = args.codec

    # 狀態模式
    if args.status:
        manager = RTMPStreamManager(config)
        status = manager.get_status()
        print(json.dumps(status, indent=2, ensure_ascii=False))
        return

    # 啟動串流
    manager = RTMPStreamManager(config)
    manager.start()


if __name__ == "__main__":
    main()
