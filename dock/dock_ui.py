#!/usr/bin/env python3
"""
黑砂 T100 機庫控制介面 (PySide6)
安裝依賴: pip3 install PySide6 paho-mqtt
執行: python3 dock_ui.py
"""

import sys
import json
import uuid
import time

import paho.mqtt.client as mqtt

from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget,
    QVBoxLayout, QHBoxLayout, QGridLayout,
    QLabel, QPushButton, QLineEdit, QTextEdit, QFrame,
)
from PySide6.QtCore import Qt, QThread, Signal
from PySide6.QtGui import QFont

# ── 設定 ──────────────────────────────────────────────────────────
DEFAULT_BROKER = "192.168.8.8"
DEFAULT_PORT   = 1883
DEVICE_SN      = "oBYS2OomLmSXZ6QUbqRq"

TOPIC_SERVICES       = f"thing/product/{DEVICE_SN}/services"
TOPIC_SERVICES_REPLY = f"thing/product/{DEVICE_SN}/services_reply"
TOPIC_REQUESTS       = f"thing/product/{DEVICE_SN}/requests"
TOPIC_REQUESTS_REPLY = f"thing/product/{DEVICE_SN}/requests_reply"
TOPIC_OSD            = f"thing/product/{DEVICE_SN}/osd"

COVER_MAP  = {0: "關閉", 1: "打開", 2: "半開", 3: "異常 ⚠", 9: "未知"}
PUTTER_MAP = {0: "關閉", 1: "打開", 2: "半開", 3: "異常 ⚠", 9: "未知"}


def bind_output(payload: dict) -> dict:
    devices = payload.get("data", {}).get("devices") or [{"sn": DEVICE_SN}]
    return {
        "bind_status": [
            {
                "sn": device.get("sn", DEVICE_SN),
                "is_device_bind_organization": True,
                "organization_id": "local",
                "organization_name": "local",
                "device_callsign": device.get("sn", DEVICE_SN),
            }
            for device in devices
        ]
    }


# ── MQTT Worker (獨立 Thread) ──────────────────────────────────────
class MqttWorker(QThread):
    sig_connected    = Signal()
    sig_disconnected = Signal()
    sig_bound        = Signal(bool)
    sig_osd          = Signal(dict)
    sig_log          = Signal(str)

    def __init__(self):
        super().__init__()
        self.client: mqtt.Client | None = None
        self._device_time_offset_ms = 0
        self._bound = False

    # ── 時間同步 ──
    def _sync_device_time(self, payload: dict):
        timestamp = payload.get("timestamp")
        if isinstance(timestamp, int):
            self._device_time_offset_ms = timestamp - int(time.time() * 1000)

    def _device_now_ms(self) -> int:
        return int(time.time() * 1000) + self._device_time_offset_ms

    def connect_broker(self, host: str, port: int):
        self.client = mqtt.Client(client_id="dock-qt-001", protocol=mqtt.MQTTv311)
        self.client.on_connect    = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        self.client.on_message    = self._on_message
        try:
            self.client.connect(host, port, keepalive=60)
            self.client.loop_start()
        except Exception as e:
            self.sig_log.emit(f"❌ 連線失敗: {e}")

    def disconnect_broker(self):
        if self.client:
            self.client.loop_stop()
            self.client.disconnect()

    def publish(self, topic: str, payload: dict):
        if self.client:
            self.client.publish(topic, json.dumps(payload))

    # ── callback ──
    def _on_connect(self, client, userdata, flags, rc, props=None):
        if rc == 0:
            self._bound = False
            client.subscribe([
                (TOPIC_REQUESTS, 0),
                (TOPIC_SERVICES_REPLY, 0),
                (TOPIC_OSD, 0),
            ])
            self.sig_connected.emit()
            self.sig_log.emit("✅ 已連上 Broker，等待 T100 綁定請求...")
        else:
            self.sig_log.emit(f"❌ 連線拒絕 rc={rc}")

    def _on_disconnect(self, client, userdata, rc, props=None):
        self._bound = False
        self.sig_bound.emit(False)
        self.sig_disconnected.emit()
        self.sig_log.emit("🔌 已斷線")

    def _on_message(self, client, userdata, msg):
        try:
            payload = json.loads(msg.payload.decode())
        except Exception:
            return
        topic = msg.topic

        self._sync_device_time(payload)

        # 自動回應 bind_status，加入 gateway 欄位與同步時間
        if topic == TOPIC_REQUESTS and payload.get("method") == "airport_bind_status":
            reply = {
                "tid":       payload["tid"],
                "bid":       payload["bid"],
                "timestamp": self._device_now_ms(),
                "gateway":   DEVICE_SN,
                "method":    "airport_bind_status",
                "data":      {"result": 0, "output": bind_output(payload)},
            }
            info = client.publish(TOPIC_REQUESTS_REPLY, json.dumps(reply))
            self._bound = True
            self.sig_bound.emit(True)
            self.sig_log.emit(
                f"📡 bind_status 已回應 rc={info.rc} offset={self._device_time_offset_ms}ms"
            )

        elif topic == TOPIC_SERVICES_REPLY:
            result = payload.get("data", {}).get("result", -1)
            method = payload.get("method", "")
            icon   = "✅" if result == 0 else "❌"
            self.sig_log.emit(f"{icon} [{method}] result={result}")

        elif topic == TOPIC_OSD:
            self.sig_osd.emit(payload.get("data", {}))


# ── 狀態卡片 ─────────────────────────────────────────────────────
class StatusCard(QFrame):
    def __init__(self, title: str, parent=None):
        super().__init__(parent)
        self.setFixedSize(148, 70)
        self.setStyleSheet("background:#2d2d44; border-radius:10px;")

        layout = QVBoxLayout(self)
        layout.setContentsMargins(10, 8, 10, 8)
        layout.setSpacing(2)

        self._lbl = QLabel(title)
        self._lbl.setStyleSheet("color:#94a3b8; font-size:10px;")
        self._lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)

        self._val = QLabel("--")
        self._val.setStyleSheet("color:#e2e8f0; font-size:17px; font-weight:bold;")
        self._val.setAlignment(Qt.AlignmentFlag.AlignCenter)

        layout.addWidget(self._lbl)
        layout.addWidget(self._val)

    def set_value(self, text: str, color: str = "#e2e8f0"):
        self._val.setText(text)
        self._val.setStyleSheet(
            f"color:{color}; font-size:17px; font-weight:bold;"
        )


# ── 主視窗 ────────────────────────────────────────────────────────
class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("T100 機庫控制台")
        self.setFixedSize(560, 700)
        self.setStyleSheet("background:#1a1a2e; color:#e2e8f0;")

        self._connected = False
        self._worker    = MqttWorker()
        self._worker.sig_connected.connect(self._on_connected)
        self._worker.sig_disconnected.connect(self._on_disconnected)
        self._worker.sig_bound.connect(self._on_bound)
        self._worker.sig_osd.connect(self._update_osd)
        self._worker.sig_log.connect(self._append_log)

        self._build_ui()

    # ── UI ────────────────────────────────────────
    def _build_ui(self):
        root = QWidget()
        self.setCentralWidget(root)
        vbox = QVBoxLayout(root)
        vbox.setContentsMargins(20, 20, 20, 20)
        vbox.setSpacing(14)

        # 標題
        t = QLabel("T100 機庫控制台")
        t.setStyleSheet("font-size:22px; font-weight:bold;")
        t.setAlignment(Qt.AlignmentFlag.AlignCenter)
        vbox.addWidget(t)

        sn = QLabel(f"SN: {DEVICE_SN}")
        sn.setStyleSheet("font-size:10px; color:#64748b; font-family:Menlo,Courier;")
        sn.setAlignment(Qt.AlignmentFlag.AlignCenter)
        vbox.addWidget(sn)

        # 連線區
        conn = QFrame()
        conn.setStyleSheet("background:#2a2a3e; border-radius:12px;")
        hb = QHBoxLayout(conn)
        hb.setContentsMargins(14, 10, 14, 10)

        hb.addWidget(self._muted("Broker"))

        self._host = QLineEdit(DEFAULT_BROKER)
        self._host.setStyleSheet(self._input_css())
        self._host.setFixedWidth(148)
        hb.addWidget(self._host)

        hb.addWidget(self._muted(":"))

        self._port = QLineEdit(str(DEFAULT_PORT))
        self._port.setStyleSheet(self._input_css())
        self._port.setFixedWidth(58)
        hb.addWidget(self._port)

        hb.addStretch()

        # 連線狀態點
        self._dot = QLabel("●")
        self._dot.setStyleSheet("color:#ef4444; font-size:18px;")
        hb.addWidget(self._dot)

        # 綁定狀態標籤
        self._bind_lbl = QLabel("未綁定")
        self._bind_lbl.setStyleSheet("color:#64748b; font-size:11px;")
        hb.addWidget(self._bind_lbl)

        self._conn_btn = QPushButton("連線")
        self._conn_btn.setFixedSize(72, 32)
        self._conn_btn.setStyleSheet(self._btn_css("#7c3aed"))
        self._conn_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        self._conn_btn.clicked.connect(self._toggle_connect)
        hb.addWidget(self._conn_btn)

        vbox.addWidget(conn)

        # OSD 狀態
        vbox.addWidget(self._section_label("即時狀態"))
        grid = QGridLayout()
        grid.setSpacing(8)
        self._cards: dict[str, StatusCard] = {}
        fields = [
            ("cover_state",          "艙蓋狀態"),
            ("putter_state",         "推杆狀態"),
            ("temperature",          "艙內溫度"),
            ("humidity",             "濕度"),
            ("drone_in_dock",        "無人機在庫"),
            ("emergency_stop_state", "急停"),
        ]
        for i, (key, lbl) in enumerate(fields):
            card = StatusCard(lbl)
            self._cards[key] = card
            grid.addWidget(card, i // 3, i % 3)
        vbox.addLayout(grid)

        # 艙蓋控制按鈕
        vbox.addWidget(self._section_label("艙蓋控制"))
        btn_row = QHBoxLayout()
        btn_row.setSpacing(10)
        for label, code, color in [
            ("🔓  開艙蓋", 2, "#16a34a"),
            ("🔒  關艙蓋", 3, "#dc2626"),
            ("⏹  停止",   4, "#d97706"),
            ("↺  復位",   1, "#7c3aed"),
        ]:
            b = QPushButton(label)
            b.setFixedHeight(46)
            b.setStyleSheet(self._btn_css(color))
            b.setCursor(Qt.CursorShape.PointingHandCursor)
            b.clicked.connect(lambda _, c=code: self._send_cover(c))
            btn_row.addWidget(b)
        vbox.addLayout(btn_row)

        # 日誌
        vbox.addWidget(self._section_label("日誌"))
        self._log_box = QTextEdit()
        self._log_box.setReadOnly(True)
        self._log_box.setStyleSheet(
            "background:#2a2a3e; color:#e2e8f0; border-radius:10px;"
            "font-family:Menlo,Courier; font-size:11px; padding:8px;"
        )
        vbox.addWidget(self._log_box)

    # ── 連線 ──────────────────────────────────────
    def _toggle_connect(self):
        if self._connected:
            self._worker.disconnect_broker()
        else:
            host = self._host.text().strip()
            port = int(self._port.text().strip())
            self._worker.connect_broker(host, port)

    def _on_connected(self):
        self._connected = True
        self._dot.setStyleSheet("color:#22c55e; font-size:18px;")
        self._conn_btn.setText("斷線")
        self._conn_btn.setStyleSheet(self._btn_css("#dc2626"))

    def _on_disconnected(self):
        self._connected = False
        self._dot.setStyleSheet("color:#ef4444; font-size:18px;")
        self._conn_btn.setText("連線")
        self._conn_btn.setStyleSheet(self._btn_css("#7c3aed"))
        self._bind_lbl.setText("未綁定")
        self._bind_lbl.setStyleSheet("color:#64748b; font-size:11px;")

    def _on_bound(self, bound: bool):
        if bound:
            self._bind_lbl.setText("已綁定 ✓")
            self._bind_lbl.setStyleSheet("color:#22c55e; font-size:11px; font-weight:bold;")
        else:
            self._bind_lbl.setText("未綁定")
            self._bind_lbl.setStyleSheet("color:#64748b; font-size:11px;")

    # ── 指令 ──────────────────────────────────────
    def _send_cover(self, instruction: int):
        if not self._connected:
            self._append_log("⚠️  尚未連線")
            return
        if not self._worker._bound:
            self._append_log("⚠️  尚未完成 bind_status，請等待「已綁定 ✓」後再操作")
            return
        names = {1: "復位", 2: "開艙蓋", 3: "關艙蓋", 4: "停止"}
        method = {2: "cover_open", 3: "cover_close"}.get(instruction, "cover_instruction")
        data = {} if method != "cover_instruction" else {"instruction": instruction}
        self._worker.publish(TOPIC_SERVICES, {
            "tid":       str(uuid.uuid4()),
            "bid":       str(uuid.uuid4()),
            "timestamp": self._worker._device_now_ms(),
            "gateway":   DEVICE_SN,
            "method":    method,
            "data":      data,
        })
        self._append_log(f"📤 發送: {names.get(instruction)} ({method})")

    # ── OSD ───────────────────────────────────────
    def _update_osd(self, data: dict):
        cover  = data.get("cover_state", 9)
        putter = data.get("putter_state", 9)
        temp   = data.get("temperature", "--")
        humi   = data.get("humidity", "--")
        drone  = data.get("drone_in_dock", 0)
        estop  = data.get("emergency_stop_state", 0)

        c_color = "#22c55e" if cover == 1 else "#ef4444" if cover == 0 else "#f59e0b"
        self._cards["cover_state"].set_value(COVER_MAP.get(cover, str(cover)), c_color)
        self._cards["putter_state"].set_value(PUTTER_MAP.get(putter, str(putter)))
        self._cards["temperature"].set_value(f"{temp} °C")
        self._cards["humidity"].set_value(f"{humi} %")
        self._cards["drone_in_dock"].set_value(
            "是 ✅" if drone else "否",
            "#22c55e" if drone else "#94a3b8",
        )
        self._cards["emergency_stop_state"].set_value(
            "開啟 ⚠️" if estop else "關閉",
            "#ef4444" if estop else "#22c55e",
        )

    # ── 日誌 ──────────────────────────────────────
    def _append_log(self, msg: str):
        ts = time.strftime("%H:%M:%S")
        self._log_box.append(
            f'<span style="color:#64748b">[{ts}]</span> {msg}'
        )
        sb = self._log_box.verticalScrollBar()
        sb.setValue(sb.maximum())

    # ── 輔助 ──────────────────────────────────────
    @staticmethod
    def _muted(text: str) -> QLabel:
        lbl = QLabel(text)
        lbl.setStyleSheet("color:#94a3b8; font-size:12px;")
        return lbl

    @staticmethod
    def _section_label(text: str) -> QLabel:
        lbl = QLabel(text)
        lbl.setStyleSheet("font-size:13px; font-weight:bold; color:#94a3b8;")
        return lbl

    @staticmethod
    def _input_css() -> str:
        return (
            "QLineEdit {"
            "  background:#3a3a52; color:#e2e8f0; border:none;"
            "  border-radius:6px; padding:4px 8px;"
            "  font-family:Menlo,Courier; font-size:12px;"
            "}"
        )

    @staticmethod
    def _btn_css(color: str) -> str:
        return (
            f"QPushButton {{"
            f"  background:{color}; color:white; border:none;"
            f"  border-radius:8px; font-size:13px; font-weight:bold;"
            f"  padding:6px 12px;"
            f"}}"
            f"QPushButton:hover {{ background:{color}cc; }}"
            f"QPushButton:pressed {{ background:{color}99; }}"
        )

    def closeEvent(self, event):
        self._worker.disconnect_broker()
        event.accept()


# ── 入口 ──────────────────────────────────────────────────────────
if __name__ == "__main__":
    app = QApplication(sys.argv)
    app.setFont(QFont("SF Pro Display", 11))
    win = MainWindow()
    win.show()
    sys.exit(app.exec())
