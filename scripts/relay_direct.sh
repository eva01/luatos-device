#!/usr/bin/env bash
# Test the device's MQTT relay control end-to-end by publishing directly to
# /relay/control/<imei> with payload "<relayId>:<state>". Subscribes to
# /relay/status/<imei> in parallel so the device's state-change echo is visible.
#
# Requires mosquitto-clients (mosquitto_pub + mosquitto_sub). On macOS:
#   brew install mosquitto
# On Debian/Ubuntu:
#   sudo apt-get install mosquitto-clients
#
# Required env vars before running:
#   BROKER_HOST  — MQTT broker IP or hostname (no default; same placeholder as
#                  main.lua mqtt_host so the convention is consistent)
#   DEVICE_ID    — Target device IMEI (no default)
#
# Optional env vars:
#   BROKER_PORT  — Default 1883
#   RELAY_ID     — 1..4 (default 1)
#   STATE        — 1 (on) or 0 (off) (default 1)
#   LISTEN_SECS  — How long to keep the subscriber open after the publish
#                  (default 60)
#
# Examples:
#   BROKER_HOST=192.0.2.10 DEVICE_ID=123456789012345 ./scripts/relay_direct.sh
#   BROKER_HOST=192.0.2.10 DEVICE_ID=123456789012345 RELAY_ID=2 STATE=1 ./scripts/relay_direct.sh
#   BROKER_HOST=192.0.2.10 DEVICE_ID=123456789012345 STATE=0 ./scripts/relay_direct.sh
#
# Expected output on success (within ~1 second of the PUB):
#   [HH:MM:SS] RX  /relay/status/<imei> 1,0,0,0
# That confirms the device received the command, flipped the relay, and
# published the state-change Status back.

set -uo pipefail

BROKER_HOST="${BROKER_HOST:-x.x.x.x}"
BROKER_PORT="${BROKER_PORT:-1883}"
DEVICE_ID="${DEVICE_ID:-000000000000000}"
RELAY_ID="${RELAY_ID:-1}"
STATE="${STATE:-1}"
LISTEN_SECS="${LISTEN_SECS:-60}"

# Fail fast if placeholders are still in place
if [ "$BROKER_HOST" = "x.x.x.x" ] || [ "$DEVICE_ID" = "000000000000000" ]; then
  echo "BROKER_HOST and DEVICE_ID must be set before running." >&2
  echo "Example: BROKER_HOST=192.0.2.10 DEVICE_ID=123456789012345 $0" >&2
  exit 1
fi

if ! command -v mosquitto_pub >/dev/null || ! command -v mosquitto_sub >/dev/null; then
  echo "mosquitto-clients not found. Install: brew install mosquitto (macOS) or apt-get install mosquitto-clients (Debian/Ubuntu)" >&2
  exit 1
fi

stamp() { date "+%H:%M:%S"; }

PAYLOAD="${RELAY_ID}:${STATE}"
echo "[$(stamp)] broker=$BROKER_HOST:$BROKER_PORT device=$DEVICE_ID direct-control=$PAYLOAD listen=${LISTEN_SECS}s"

mosquitto_sub -h "$BROKER_HOST" -p "$BROKER_PORT" -q 1 \
  -t "/relay/status/$DEVICE_ID" -v \
  | while IFS= read -r line; do echo "[$(stamp)] RX  $line"; done &
SUB_PID=$!

trap 'kill $SUB_PID 2>/dev/null; wait $SUB_PID 2>/dev/null; exit' INT TERM EXIT

sleep 2
echo "[$(stamp)] PUB /relay/control/$DEVICE_ID  $PAYLOAD"
mosquitto_pub -h "$BROKER_HOST" -p "$BROKER_PORT" -q 1 \
  -t "/relay/control/$DEVICE_ID" -m "$PAYLOAD"

sleep "$LISTEN_SECS"
echo "[$(stamp)] done"
