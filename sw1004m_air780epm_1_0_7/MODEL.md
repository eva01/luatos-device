# SW1004M / Air780EPM 1.0.7

Current development source: `main.lua`

## Identity

- Hardware family: SW1004M-10 / SW1004P-style relay controller, newer revision of the SW1004P family
- Chip/core family: Air780EPM / EC718PM
- Current app version in source: `1.0.7`
- LuaTool upload target: `LuaTools/project/main.lua`
- Relationship to `firmware/models/sw1004m_air780epm/`: that folder preserves the earlier `1.0.6` Lua unchanged. This folder is the `1.0.7` upload candidate with factory-style diagnostics, reload-button logging, and improved NET LED state handling.
- Related official reference page: `https://www.yinerda.com/productinfo/5916614.html` (`YED-SW1004P-10`, Air780EP model; keep separate from this Air780EPM revision)
- Separate Air780EP model note: `firmware/models/yed_sw1004p_air780ep/`

## Product Page Facts

- 7-36VDC power, 10W.
- 4 relay outputs.
- 4 dry-contact inputs.
- 1 RS485.
- 2 x 4-20mA current inputs.
- Built-in SIM and external SIM support.
- Page says applicable module schemes include Air780E/Air700/Y100E/Air780EPM/Y100EP.

## GPIO Map

| Function | GPIO |
| --- | --- |
| RS485 | UART1 |
| RS485 enable | GPIO25 |
| NET LED | GPIO27 |
| Reload button | GPIO30 |
| Hardware watchdog | GPIO29 |
| Input 1 | GPIO2 |
| Input 2 | GPIO1 |
| Input 3 | GPIO20 |
| Input 4 | GPIO14 |
| Relay output 1 | GPIO22 |
| Relay output 2 | GPIO24 |
| Relay output 3 | GPIO21 |
| Relay output 4 | GPIO28 |
| Relay enable | GPIO36 |
| Power voltage collection | ADC2 |
| Analog input 1 | ADC0 |
| Analog input 2 | ADC1 |
| RTC | I2C1 BM8563 |
| External SIM | SIM2 |
| Embedded SIM | SIM1 |
| USB port | Firmware download |
| Boot button | Hold before power-on to force USB download mode |

## Backups And Analysis

- Modified/user-code backup: `reference/flash-archive/backups/20260514_153401_SW1004M-10/ap_flash_full_0x000000_0x400000`
- Extracted bytecode: `reference/flash-archive/extracted_lua_apps/SW1004M_MODIFIED_BACKUP_20260514_153401/`
- Findings: `reference/flash-archive/reports/findings_SW1004M-10_vs_FACTORY.txt`
- Factory `hwdef` SW1004P-compatible branch matches the GPIO map above: output enable `GPIO36`, relay outputs `22/24/21/28`, inputs `2/1/20/14`, reload `GPIO30`, NET LED `GPIO27`, watchdog `GPIO29`, and power voltage collection on ADC2.

## 1.0.7 Behavior Notes

- Keeps the same relay/input/MQTT topic behavior as `1.0.6`.
- Adds reload button monitoring on `GPIO30`. Short and long presses are logged, but factory reset is intentionally disabled.
- Adds `RS485 enable` setup on `GPIO25` so the pin is known and logged even though this relay MQTT app does not yet use RS485.
- Reworks NET LED `GPIO27` into explicit states: waiting for network, IP ready/cellular registered, and MQTT ready.
- Adds factory-style console diagnostics for boot/reset information, memory, network state, MQTT events, watchdog feeding, invalid commands, and relay/input changes.
