#!/usr/bin/env python3
"""
黑砂 T100 機庫控制腳本
Broker: 192.168.8.8:1883
Device: oBYS2OomLmSXZ6QUbqRq
"""

import paho.mqtt.client as mqtt
import json
import uuid
import time

# ── 設定 ──────────────────────────────────────────
BROKER_HOST = "192.168.8.8"
BROKER_PORT = 1883
DEVICE_SN   = "oBYS2OomLmSXZ6QUbqRq"

TOPIC_SERVICES       = f"thing/product/{DEVICE_SN}/services"
TOPIC_SERVICES_REPLY = f"thing/product/{DEVICE_SN}/services_reply"
TOPIC_REQUESTS       = f"thing/product/{DEVICE_SN}/requests"
TOPIC_REQUESTS_REPLY = f"thing/product/{DEVICE_SN}/requests_reply"
TOPIC_OSD            = f"thing/product/{DEVICE_SN}/osd"

# ── 指令代碼 ──────────────────────────────────────
COVER = {
    "reset": 1,
    "open":  2,
    "close": 3,
    "stop":  4,
}

DIRECT_COVER_METHOD = {
    "open": "cover_open",
    "close": "cover_close",
}

# ── 裝置時間同步 ───────────────────────────────────
_device_time_offset_ms = 0
_bound = False


def sync_device_time(payload: dict):
    global _device_time_offset_ms
    timestamp = payload.get("timestamp")
    if isinstance(timestamp, int):
        _device_time_offset_ms = timestamp - int(time.time() * 1000)


def device_now_ms() -> int:
    return int(time.time() * 1000) + _device_time_offset_ms


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

# ── MQTT callback ──────────────────────────────────
def on_connect(client, userdata, flags, rc, properties=None):
    global _bound
    if rc == 0:
        _bound = False
        print("✅ 已連上 Broker")
        client.subscribe(TOPIC_REQUESTS)
        client.subscribe(TOPIC_SERVICES_REPLY)
        client.subscribe(TOPIC_OSD)
    else:
        print(f"❌ 連線失敗，rc={rc}")

def on_message(client, userdata, msg):
    global _bound
    topic = msg.topic
    try:
        payload = json.loads(msg.payload.decode())
    except Exception:
        return

    sync_device_time(payload)

    # 自動回應 airport_bind_status
    if topic == TOPIC_REQUESTS and payload.get("method") == "airport_bind_status":
        print(f"📡 收到 bind_status 請求，自動回應...")
        reply = {
            "tid":       payload["tid"],
            "bid":       payload["bid"],
            "timestamp": device_now_ms(),
            "gateway":   DEVICE_SN,
            "method":    "airport_bind_status",
            "data":      {"result": 0, "output": bind_output(payload)},
        }
        info = client.publish(TOPIC_REQUESTS_REPLY, json.dumps(reply))
        _bound = True
        print(f"✅ bind_status 已回應 rc={info.rc} offset={_device_time_offset_ms}ms，可以下指令了")

    # 顯示指令回應
    elif topic == TOPIC_SERVICES_REPLY:
        result = payload.get("data", {}).get("result", -1)
        method = payload.get("method", "")
        if result == 0:
            print(f"✅ [{method}] 執行成功")
        else:
            print(f"❌ [{method}] 執行失敗，result={result}")

    # OSD 狀態（只顯示重要欄位）
    elif topic == TOPIC_OSD:
        data = payload.get("data", {})
        cover = data.get("cover_state", "?")
        putter = data.get("putter_state", "?")
        temp = data.get("temperature", "?")
        drone = data.get("drone_in_dock", "?")
        cover_map  = {0:"關閉", 1:"打開", 2:"半開", 3:"異常", 9:"未知"}
        putter_map = {0:"關閉", 1:"打開", 2:"半開", 3:"異常", 9:"未知"}
        print(f"  📊 OSD | 艙蓋:{cover_map.get(cover, cover)}  推杆:{putter_map.get(putter, putter)}  溫度:{temp}°C  無人機在庫:{bool(drone)}")

# ── 發送指令 ──────────────────────────────────────
def send_cover(client, action: str):
    if not _bound:
        print("⚠️  尚未完成 bind_status，請等待 T100 發送綁定請求後再輸入指令")
        return
    code = COVER.get(action)
    if code is None:
        print(f"❌ 未知指令: {action}，可用: {list(COVER.keys())}")
        return
    method = DIRECT_COVER_METHOD.get(action, "cover_instruction")
    data = {} if method != "cover_instruction" else {"instruction": code}
    payload = {
        "tid":       str(uuid.uuid4()),
        "bid":       str(uuid.uuid4()),
        "timestamp": device_now_ms(),
        "gateway":   DEVICE_SN,
        "method":    method,
        "data":      data,
    }
    info = client.publish(TOPIC_SERVICES, json.dumps(payload))
    print(f"📤 發送艙蓋指令: {action} (method={method}, data={data}, rc={info.rc})")

# ── 主程式 ────────────────────────────────────────
def main():
    client = mqtt.Client(
        client_id="dock-controller-001",
        protocol=mqtt.MQTTv311
    )
    client.on_connect = on_connect
    client.on_message = on_message

    print(f"🔌 連線到 {BROKER_HOST}:{BROKER_PORT}...")
    client.connect(BROKER_HOST, BROKER_PORT, keepalive=60)
    client.loop_start()

    time.sleep(1.5)  # 等待連線和 bind_status

    print("\n指令: open / close / stop / reset / quit")
    while True:
        try:
            status = "✅已綁定" if _bound else "⏳等待綁定"
            cmd = input(f"\n[{status}] > ").strip().lower()
            if cmd == "quit":
                break
            elif cmd in COVER:
                send_cover(client, cmd)
            else:
                print(f"可用指令: {list(COVER.keys())} / quit")
        except KeyboardInterrupt:
            break

    client.loop_stop()
    client.disconnect()
    print("👋 已斷線")

if __name__ == "__main__":
    main()
