#!/usr/bin/env python3
"""
Minimal MQTT probe for Heisha T100 dock.

Usage:
  python3 dock_probe.py open
  python3 dock_probe.py close
  python3 dock_probe.py stop
  python3 dock_probe.py reset

This script bypasses the web UI and prints every MQTT message received on the
dock product topics, so it is useful for separating UI/server issues from
T100/protocol/safety-state issues.
"""

import argparse
import json
import sys
import time
import uuid

import paho.mqtt.client as mqtt


DEFAULT_BROKER = "192.168.8.8"
DEFAULT_PORT = 1883
DEVICE_SN = "oBYS2OomLmSXZ6QUbqRq"

COVER = {
    "reset": 1,
    "open": 2,
    "close": 3,
    "stop": 4,
}

DIRECT_COVER_METHOD = {
    "open": "cover_open",
    "close": "cover_close",
}


def now_ms() -> int:
    return int(time.time() * 1000)


def pretty(payload: bytes) -> str:
    try:
        return json.dumps(json.loads(payload.decode()), ensure_ascii=False)
    except Exception:
        return payload.decode(errors="replace")


def bind_output(payload: dict, fallback_sn: str) -> dict:
    devices = payload.get("data", {}).get("devices") or [{"sn": fallback_sn}]
    bind_status = []
    for device in devices:
        sn = device.get("sn", fallback_sn)
        bind_status.append({
            "sn": sn,
            "is_device_bind_organization": True,
            "organization_id": "local",
            "organization_name": "local",
            "device_callsign": sn,
        })
    return {"bind_status": bind_status}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=sorted(COVER))
    parser.add_argument("--host", default=DEFAULT_BROKER)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--sn", default=DEVICE_SN)
    parser.add_argument("--wait", type=float, default=15.0)
    parser.add_argument("--after-send-wait", type=float, default=8.0)
    parser.add_argument(
        "--legacy",
        action="store_true",
        help="Use legacy remote-controller method cover_instruction instead of direct dock services.",
    )
    args = parser.parse_args()

    topics = {
        "services": f"thing/product/{args.sn}/services",
        "services_reply": f"thing/product/{args.sn}/services_reply",
        "requests": f"thing/product/{args.sn}/requests",
        "requests_reply": f"thing/product/{args.sn}/requests_reply",
        "osd": f"thing/product/{args.sn}/osd",
        "state": f"thing/product/{args.sn}/state",
        "events": f"thing/product/{args.sn}/events",
        "status": f"sys/product/{args.sn}/status",
    }

    bound = False
    sent = False
    sent_at = 0.0
    device_time_offset_ms = 0

    def sync_device_time(payload: dict):
        nonlocal device_time_offset_ms
        timestamp = payload.get("timestamp")
        if isinstance(timestamp, int):
            device_time_offset_ms = timestamp - now_ms()

    def device_now_ms() -> int:
        return now_ms() + device_time_offset_ms

    def send_command(client: mqtt.Client):
        nonlocal sent, sent_at
        if sent:
            return
        sent = True
        sent_at = time.time()
        method = DIRECT_COVER_METHOD.get(args.action)
        data = {}
        if args.legacy or method is None:
            method = "cover_instruction"
            data = {"instruction": COVER[args.action]}

        payload = {
            "tid": str(uuid.uuid4()),
            "bid": str(uuid.uuid4()),
            "timestamp": device_now_ms(),
            "gateway": args.sn,
            "method": method,
            "data": data,
        }
        encoded = json.dumps(payload, ensure_ascii=False)
        info = client.publish(topics["services"], encoded)
        print(f"\nTX {topics['services']} rc={info.rc}")
        print(encoded)

    def on_connect(client, userdata, flags, rc, properties=None):
        if rc != 0:
            print(f"CONNECT FAILED rc={rc}")
            return
        print(f"CONNECTED {args.host}:{args.port}")
        subscriptions = [
            (topics["services_reply"], 0),
            (topics["requests"], 0),
            (topics["requests_reply"], 0),
            (topics["osd"], 0),
            (topics["state"], 0),
            (topics["events"], 0),
            (topics["status"], 0),
        ]
        client.subscribe(subscriptions)
        for topic, _ in subscriptions:
            print(f"SUB {topic}")

    def on_message(client, userdata, msg):
        nonlocal bound
        print(f"\nRX {msg.topic}")
        print(pretty(msg.payload))

        try:
            payload = json.loads(msg.payload.decode())
        except Exception:
            return
        sync_device_time(payload)

        if msg.topic == topics["requests"] and payload.get("method") == "airport_bind_status":
            reply = {
                "tid": payload["tid"],
                "bid": payload["bid"],
                "timestamp": device_now_ms(),
                "gateway": args.sn,
                "method": "airport_bind_status",
                "data": {"result": 0, "output": bind_output(payload, args.sn)},
            }
            encoded = json.dumps(reply, ensure_ascii=False)
            info = client.publish(topics["requests_reply"], encoded)
            bound = True
            print(f"\nTX {topics['requests_reply']} rc={info.rc}")
            print(f"time_offset_ms={device_time_offset_ms}")
            print(encoded)
            send_command(client)

    client = mqtt.Client(client_id=f"dock-probe-{uuid.uuid4().hex[:8]}", protocol=mqtt.MQTTv311)
    client.on_connect = on_connect
    client.on_message = on_message

    print(f"Connecting to {args.host}:{args.port}, SN={args.sn}")
    client.connect(args.host, args.port, keepalive=60)
    client.loop_start()

    deadline = time.time() + args.wait
    while time.time() < deadline:
        if bound and not sent:
            send_command(client)
        if sent and time.time() - sent_at >= args.after_send_wait:
            break
        time.sleep(0.1)

    client.loop_stop()
    client.disconnect()

    if not bound:
        print("\nRESULT: no airport_bind_status received.")
        print("Likely causes: wrong SN/topic, T100 not online, or broker is not the T100 broker.")
    elif sent:
        print("\nRESULT: command was published. Check RX services_reply/result above.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
