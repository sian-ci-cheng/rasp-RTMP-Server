#!/usr/bin/env python3
"""
RTMP 推流健康狀態監控
監控串流狀態並提供 HTTP 健康檢查端點
"""

import os
import sys
import time
import json
import logging
import subprocess
import threading
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Dict, Optional
from datetime import datetime

LOG_DIR = Path("/var/log/rtmp-stream")
LOG_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(LOG_DIR / "health_check.log"),
    ],
)
logger = logging.getLogger("HealthCheck")


class SystemMetrics:
    """收集系統指標"""

    @staticmethod
    def get_cpu_temp() -> Optional[float]:
        """取得 CPU 溫度（樹莓派）"""
        temp_file = Path("/sys/class/thermal/thermal_zone0/temp")
        if temp_file.exists():
            try:
                return int(temp_file.read_text()) / 1000
            except (ValueError, OSError):
                pass
        return None

    @staticmethod
    def get_cpu_usage() -> Optional[float]:
        """取得 CPU 使用率"""
        try:
            result = subprocess.run(
                ["top", "-bn1"],
                capture_output=True, text=True, timeout=5
            )
            for line in result.stdout.split("\n"):
                if "Cpu(s)" in line or "%Cpu" in line:
                    # 解析 CPU 使用率
                    parts = line.split()
                    for i, part in enumerate(parts):
                        if "us" in part or (i > 0 and parts[i-1].replace(".", "").isdigit()):
                            try:
                                return float(parts[i-1].rstrip(","))
                            except (ValueError, IndexError):
                                pass
        except Exception:
            pass
        return None

    @staticmethod
    def get_memory_info() -> Dict:
        """取得記憶體資訊"""
        info = {"total_mb": 0, "used_mb": 0, "free_mb": 0, "usage_pct": 0}
        try:
            result = subprocess.run(
                ["free", "-m"], capture_output=True, text=True, timeout=3
            )
            for line in result.stdout.split("\n"):
                if line.startswith("Mem:"):
                    parts = line.split()
                    info["total_mb"] = int(parts[1])
                    info["used_mb"] = int(parts[2])
                    info["free_mb"] = int(parts[3])
                    if info["total_mb"] > 0:
                        info["usage_pct"] = round(info["used_mb"] / info["total_mb"] * 100, 1)
        except Exception:
            pass
        return info

    @staticmethod
    def get_network_stats(interface: str = "eth0") -> Dict:
        """取得網路統計"""
        stats = {
            "interface": interface,
            "state": "unknown",
            "rx_bytes": 0,
            "tx_bytes": 0,
        }
        try:
            state_file = Path(f"/sys/class/net/{interface}/operstate")
            if state_file.exists():
                stats["state"] = state_file.read_text().strip()

            rx_file = Path(f"/sys/class/net/{interface}/statistics/rx_bytes")
            tx_file = Path(f"/sys/class/net/{interface}/statistics/tx_bytes")
            if rx_file.exists():
                stats["rx_bytes"] = int(rx_file.read_text())
            if tx_file.exists():
                stats["tx_bytes"] = int(tx_file.read_text())
        except Exception:
            pass
        return stats

    @staticmethod
    def get_ffmpeg_processes() -> list:
        """取得 FFmpeg 進程資訊"""
        processes = []
        try:
            result = subprocess.run(
                ["pgrep", "-a", "ffmpeg"],
                capture_output=True, text=True, timeout=3
            )
            for line in result.stdout.strip().split("\n"):
                if line:
                    parts = line.split(" ", 1)
                    if len(parts) >= 2:
                        processes.append({
                            "pid": int(parts[0]),
                            "cmd_brief": parts[1][:100],
                        })
        except Exception:
            pass
        return processes


class HealthStatus:
    """健康狀態管理"""

    def __init__(self):
        self._metrics = SystemMetrics()
        self._lock = threading.Lock()
        self._last_check: Optional[Dict] = None
        self._check_interval = 5  # 秒
        self._running = True

        # 啟動背景監控執行緒
        self._monitor_thread = threading.Thread(
            target=self._monitor_loop, daemon=True
        )
        self._monitor_thread.start()

    def _monitor_loop(self):
        """背景監控迴圈"""
        while self._running:
            status = self._collect_status()
            with self._lock:
                self._last_check = status

            # 警告邏輯
            cpu_temp = status.get("system", {}).get("cpu_temp_celsius")
            if cpu_temp and cpu_temp > 80:
                logger.warning(f"CPU 溫度過高：{cpu_temp}°C")

            ffmpeg_count = len(status.get("ffmpeg_processes", []))
            if ffmpeg_count == 0:
                logger.warning("沒有 FFmpeg 推流進程在運行")

            time.sleep(self._check_interval)

    def _collect_status(self) -> Dict:
        """收集當前狀態"""
        m = self._metrics

        # nginx 服務狀態
        nginx_running = False
        try:
            result = subprocess.run(
                ["systemctl", "is-active", "nginx"],
                capture_output=True, text=True, timeout=3
            )
            nginx_running = result.stdout.strip() == "active"
        except Exception:
            pass

        # stream-relay 服務狀態
        relay_running = False
        try:
            result = subprocess.run(
                ["systemctl", "is-active", "stream-relay"],
                capture_output=True, text=True, timeout=3
            )
            relay_running = result.stdout.strip() == "active"
        except Exception:
            pass

        cpu_temp = m.get_cpu_temp()
        memory = m.get_memory_info()
        network = m.get_network_stats()
        ffmpeg_procs = m.get_ffmpeg_processes()

        overall_healthy = (
            network.get("state") == "up" and
            len(ffmpeg_procs) > 0 and
            (cpu_temp is None or cpu_temp < 85)
        )

        return {
            "timestamp": datetime.now().isoformat(),
            "healthy": overall_healthy,
            "services": {
                "nginx": nginx_running,
                "stream_relay": relay_running,
                "ffmpeg_active": len(ffmpeg_procs) > 0,
            },
            "system": {
                "cpu_temp_celsius": cpu_temp,
                "memory": memory,
            },
            "network": network,
            "ffmpeg_processes": ffmpeg_procs,
        }

    def get_status(self) -> Dict:
        """取得最新狀態（執行緒安全）"""
        with self._lock:
            if self._last_check is None:
                return self._collect_status()
            return self._last_check

    def stop(self):
        """停止監控"""
        self._running = False


class HealthCheckHandler(BaseHTTPRequestHandler):
    """HTTP 健康檢查請求處理器"""

    health_status: Optional[HealthStatus] = None

    def log_message(self, format, *args):
        pass  # 靜音 HTTP 日誌

    def do_GET(self):
        if self.path in ("/health", "/healthz"):
            self._handle_health()
        elif self.path == "/status":
            self._handle_status()
        elif self.path == "/metrics":
            self._handle_metrics()
        else:
            self._handle_404()

    def _send_json(self, data: dict, status_code: int = 200):
        body = json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def _handle_health(self):
        """簡單健康檢查（用於 loadbalancer probe）"""
        status = self.health_status.get_status() if self.health_status else {}
        healthy = status.get("healthy", False)
        code = 200 if healthy else 503
        self._send_json(
            {"status": "ok" if healthy else "degraded",
             "timestamp": datetime.now().isoformat()},
            code
        )

    def _handle_status(self):
        """完整狀態資訊"""
        status = self.health_status.get_status() if self.health_status else {}
        self._send_json(status)

    def _handle_metrics(self):
        """Prometheus 格式指標（選用）"""
        status = self.health_status.get_status() if self.health_status else {}
        lines = []
        net = status.get("network", {})
        sys_info = status.get("system", {})
        mem = sys_info.get("memory", {})

        lines.append(f'rtmp_stream_healthy {{}} {1 if status.get("healthy") else 0}')
        lines.append(f'rtmp_ffmpeg_processes {{}} {len(status.get("ffmpeg_processes", []))}')

        if net.get("rx_bytes"):
            lines.append(f'rtmp_network_rx_bytes {{interface="{net["interface"]}"}} {net["rx_bytes"]}')
            lines.append(f'rtmp_network_tx_bytes {{interface="{net["interface"]}"}} {net["tx_bytes"]}')

        if sys_info.get("cpu_temp_celsius"):
            lines.append(f'rtmp_cpu_temperature_celsius {{}} {sys_info["cpu_temp_celsius"]}')

        if mem.get("usage_pct"):
            lines.append(f'rtmp_memory_usage_percent {{}} {mem["usage_pct"]}')

        body = "\n".join(lines).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def _handle_404(self):
        self._send_json({"error": "Not Found"}, 404)


def main():
    import argparse

    parser = argparse.ArgumentParser(description="RTMP 推流健康狀態監控")
    parser.add_argument("--port", type=int, default=9090, help="HTTP 服務埠（預設 9090）")
    parser.add_argument("--host", default="0.0.0.0", help="監聽位址")
    args = parser.parse_args()

    # 初始化健康狀態監控
    health = HealthStatus()
    HealthCheckHandler.health_status = health

    # 啟動 HTTP 伺服器
    server = HTTPServer((args.host, args.port), HealthCheckHandler)
    logger.info(f"健康檢查服務啟動：http://{args.host}:{args.port}")
    logger.info(f"  /health  - 簡單健康檢查")
    logger.info(f"  /status  - 完整狀態資訊")
    logger.info(f"  /metrics - Prometheus 指標")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("健康檢查服務停止")
    finally:
        health.stop()
        server.server_close()


if __name__ == "__main__":
    main()
