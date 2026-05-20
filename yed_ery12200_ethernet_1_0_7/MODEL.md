# YED-ERY12200 Ethernet 1.0.7

Current development source: `main.lua`

This folder is the identifiable `1.0.7` Ethernet upload candidate for the Yinerda ERY12200.

## Current State

- Durable Beads issue: `yinerda-omf`
- Active baseline source: `main.lua`
- Yinerda product page: `https://www.yinerda.com/productinfo/219656.html`
- Development handoff: `docs/ETHERNET_DEVELOPMENT.md`
- Product name: `YED-ERY12200`
- Current app version in source: `1.0.7`
- LuaTool upload target: `LuaTools/project/main.lua`
- Relationship to `firmware/models/yed_ery12200_ethernet/`: that folder preserves the earlier Ethernet development area. This folder is the `1.0.7` upload candidate with local MQTT broker test settings, Google/Cloudflare DNS, and debounced input triggers.
- Backups and extracted bytecode are in `reference/flash-archive/`.
- Extracted factory bytecode is under `reference/flash-archive/extracted_lua_apps/ERY12200_FACTORY_1/`.
- Full flash backups are under:
  - `reference/flash-archive/backups/20260514_155713_ERY12200_FACTORY_1/ap_flash_full_0x000000_0x400000`
  - `reference/flash-archive/backups/20260514_160054_ERY12200_FACTORY_2/ap_flash_full_0x000000_0x400000`
- Factory app identity from bytecode constants: `PROJECT=YED_DTU6`, `VERSION=1.0.4`, model string `ERY12200`.
- Factory core evidence: `EC718PM`, `LuatOS-SoC V2016.25.03`, ROM build `2025-10-09`.
- Factory unit 1 and unit 2 have identical Lua-script regions; use `ERY12200_FACTORY_1` for first reverse pass.

## Product Page Facts

The Yinerda page describes `YED-ERY12200` as an industrial single-RS485 Ethernet DTU/RTU for device control, state detection, and sensor acquisition over Ethernet.

| Function | Product page detail |
| --- | --- |
| Power | 7-36V DC, 10W, 12V recommended |
| Ethernet | 1 x 10/100M adaptive wired Ethernet |
| RS485 | Intro/features say 1 x RS485; hardware table says 2 routes. Verify on hardware. |
| Protocols | TCP client, UDP client, TCP server, MQTT, HTTP |
| Secure protocols | TCPS, MQTTS, HTTPS with SSL certificates |
| Inputs | 2 dry-contact inputs; product resource text also says `IN1-IN4`, so verify terminals. |
| Outputs | 2 normally-open/normally-closed 3-pin relays, 250VAC 10A / 28VDC 10A |
| RTC | Supported |
| Audio | TTS playback, 4 ohm 3W speaker drive, microphone recording |
| LEDs | NET, LINK, ACK, PWR behavior documented |
| USB | Firmware upgrade and log debugging; USB does not power the device |
| BOOT | Used with USB to enter boot upgrade mode |

## Specsheet GPIO Map

User-provided ERY12200 specsheet map:

| Function | Resource | Notes |
| --- | --- | --- |
| RS485 serial | UART2 |  |
| RS485 enable | GPIO2 | EN reverse |
| NET LED | GPIO27 | Output, high = ON, low = OFF |
| Reload button | GPIO26 | Input pull-up, press connects to GND |
| Hardware watchdog | GPIO28 | `air153C_wtd`, feed every 150 seconds recommended |
| Input 1 | GPIO36 |  |
| Input 2 | GPIO37 |  |
| Output 1 | GPIO21 |  |
| Output 2 | GPIO3 |  |
| Output enable | GPIO25 | Set EN high, configure output IO, then set EN low to save power |
| Power voltage collection | ADC0 | Battery voltage = ADC voltage * 103300 / 3300, max 36V |
| RTC | I2C1 | BM8563ESA |
| Ethernet CH390H EN | GPIO24 | Pull high to enable |
| Ethernet CH390H SPI | SPI0 |  |
| Ethernet CH390H CS | GPIO8 |  |
| Ethernet CH390H interrupt | GPIO22 |  |
| PA | Not present | Ignore for base ERY12200; PA GPIO6 applies to `ERY12200-V` only |
| USB | USB port | Firmware download |
| Boot | Boot button | Hold before power-on to force USB download mode |

Factory `per.luac` decompilation matches this corrected map:

- Factory ERY12200 branch maps voltage collection as `adcid = 0`, `ADC_V`, `r1 = 3300`, `r2 = 103300`, matching ADC0 voltage collection.
- Factory TTS/PA GPIO6 is only enabled for model string `ERY12200-V`. The local backup stores `Devname ERY12200`, so ignore PA for base ERY12200 firmware.
- Factory `main.luac` already sets `pm.ioVol(pm.IOVOL_ALL_GPIO, 3300)`, matching the specsheet warning.

## Custom Firmware Baseline

`main.lua` is the first custom ERY12200 baseline, adapted from the SW1004M `relay_4_mqtt_netled` v1.0.6 firmware into a 2-relay/2-input app:

- `PROJECT=relay_2_mqtt_netled`
- `VERSION=1.0.7`
- MQTT host `192.168.80.51`, port `1883`
- Same topic shape as the 4-relay firmware: `/relay/status/<device_id>` and `/relay/control/<device_id>`
- Same commands: `1:on`, `1:off`, `2:1`, `2:0`, and `status`
- Uses the confirmed ERY12200 relay/input/output-enable/watchdog/NET LED pins.
- Initializes CH390 Ethernet directly on GPIO24/SPI0/CS8/IRQ22, enables DHCP, makes `socket.LWIP_ETH` the default adapter, then starts MQTT.
- Sets Ethernet DNS to `8.8.8.8` and `1.1.1.1`.
- Debounces input triggers for about 150 ms before toggling the paired relay.
- This baseline is Ethernet-first/ethernet-only. Cellular fallback can be added later if bench testing shows it is needed.

## First Firmware Steps

1. Confirm physical terminal count and silkscreen for RS485, IN, relay, NET/LINK/ACK, BOOT, and USB.
2. Upload the custom baseline through LuaTools and confirm CH390 link, DHCP address, and MQTT connection logs.
3. Bench-test relay output enable behavior, input polarity, hardware watchdog feed interval, and NET LED behavior.
4. Compare any remaining factory DTU behavior from `procmd.luac`, `pronet.luac`, `prouart.luac`, and `unet.luac` before reintroducing RS485 protocol logic.
5. Confirm target LuatOS core and board package before shipping any custom Lua.
