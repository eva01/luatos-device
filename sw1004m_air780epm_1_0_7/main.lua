-- LuaTools needs PROJECT and VERSION information
PROJECT = "relay_4_mqtt_netled"
VERSION = "1.0.8"

log.info("main", PROJECT, VERSION)

_G.sys = require("sys")
_G.sysplus = require("sysplus")

local netLed = require("netLed")
require("air153C_wtd")

local function log_ok(tag, ...)
    log.info(tag, ...)
end

local function log_warn(tag, ...)
    log.warn(tag, ...)
end

local function log_err(tag, ...)
    log.error(tag, ...)
end

local function call_safe(tag, fn, ...)
    if not fn then
        log_warn(tag, "missing function")
        return false
    end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then
        log_err(tag, "failed", a)
        return false
    end
    return true, a, b, c
end

local function call_read(tag, fn)
    if not fn then
        log_warn(tag, "missing read function")
        return nil
    end
    local ok, value = pcall(fn)
    if not ok then
        log_err(tag, "read failed", value)
        return nil
    end
    return value
end

local function bool_text(value)
    return value and "1" or "0"
end

local function safe_pin_write(name, handle, value)
    if not handle then
        log_err("GPIO", name, "handle missing")
        return false
    end
    local ok, err = pcall(handle, value)
    if not ok then
        log_err("GPIO", name, "write failed", value, err)
        return false
    end
    return true
end

local function setup_output(name, pin, default)
    local ok, handle = pcall(gpio.setup, pin, default)
    if not ok or not handle then
        log_err("GPIO", name, "setup output failed", pin, handle)
        return nil
    end
    log_ok("GPIO", name, "output", pin, "default", default)
    return handle
end

local function setup_input(name, pin)
    local ok, handle = pcall(gpio.setup, pin, nil, gpio.PULLUP)
    if not ok or not handle then
        log_err("GPIO", name, "setup input failed", pin, handle)
        return nil
    end
    log_ok("GPIO", name, "input pullup", pin)
    return handle
end

local function get_mem(kind)
    if rtos and rtos.meminfo then
        local ok, value = pcall(rtos.meminfo, kind)
        if ok then
            return value
        end
    end
    return "n/a"
end

local function read_mobile_status()
    if mobile and mobile.status then
        local ok, value = pcall(mobile.status)
        if ok then
            return value
        end
        log_warn("mobile", "status read failed", value)
    end
    return -1
end

local function read_device_id()
    if mobile and mobile.imei then
        local ok, imei = pcall(mobile.imei)
        if ok and imei and imei ~= "" then
            return imei
        end
        log_warn("mobile", "imei unavailable", imei)
    end
    if mcu and mcu.unique_id then
        local ok, uid = pcall(mcu.unique_id)
        if ok and uid then
            local ok_hex, hex = pcall(uid.toHex, uid)
            if ok_hex and hex then
                return hex
            end
        end
    end
    return "unknown_device"
end

local function publish_status(client, topic, states, reason)
    if not client or not client.ready or not client:ready() then
        log_warn("mqtt", "skip publish, client not ready", reason or "-")
        return false
    end
    local payload = table.concat(states, ",")
    local ok, err = pcall(function()
        client:publish(topic, payload, 1)
    end)
    if not ok then
        log_err("mqtt", "publish failed", topic, payload, err)
        return false
    end
    log_ok("mqtt", "publish", reason or "status", topic, payload)
    return true
end

local function normalize_command(command)
    if not command then
        return nil
    end
    if command == "1" or command == "on" or command == "ON" or command == "On" then
        return 1
    end
    if command == "0" or command == "off" or command == "OFF" or command == "Off" then
        return 0
    end
    return nil
end

if wdt then
    local ok, err = pcall(function()
        wdt.init(9000)
        sys.timerLoopStart(wdt.feed, 3000)
    end)
    if ok then
        log_ok("wdt", "software watchdog enabled", 9000)
    else
        log_err("wdt", "software watchdog init failed", err)
    end
else
    log_warn("wdt", "software watchdog API unavailable")
end

if rtos and rtos.bsp and pm and pm.PWK_MODE then
    local ok_bsp, bsp = pcall(rtos.bsp)
    if ok_bsp and bsp == "EC618" then
        call_safe("pm", pm.power, pm.PWK_MODE, false)
        log_ok("pm", "PWK_MODE disabled for easier flashing")
    end
end

if pm and pm.ioVol and pm.IOVOL_ALL_GPIO then
    local ok_iovol, err_iovol = pcall(function()
        pm.ioVol(pm.IOVOL_ALL_GPIO, 3300)
    end)
    if ok_iovol then
        log_ok("pm", "GPIO voltage set", 3300)
    else
        log_err("pm", "GPIO voltage set failed", err_iovol)
    end
else
    log_warn("pm", "ioVol API unavailable")
end

local relay_pins = {22, 24, 21, 28}
local input_pins = {2, 1, 20, 14}
local relay_enable_pin = 36
local hw_watchdog_pin = 29
local netled_pin = 27
local reload_pin = 30
local rs485_enable_pin = 25

local relay_handles = {}
for index, pin in ipairs(relay_pins) do
    relay_handles[index] = setup_output("relay" .. index, pin, 0)
end

local relay_enable_handle = setup_output("relay_enable", relay_enable_pin, 0)
local LEDA = setup_output("netled", netled_pin, 0)
local rs485_enable_handle = setup_output("rs485_enable", rs485_enable_pin, 0)
local reload_handle = setup_input("reload", reload_pin)

local input_handles = {}
for index, pin in ipairs(input_pins) do
    input_handles[index] = setup_input("input" .. index, pin)
end

log_ok("GPIO", "relay pins", table.concat(relay_pins, ","))
log_ok("GPIO", "input pins", table.concat(input_pins, ","))
log_ok("GPIO", "relay_enable", relay_enable_pin, "watchdog", hw_watchdog_pin, "netled", netled_pin, "reload", reload_pin, "rs485_en", rs485_enable_pin)

local relay_states = {0, 0, 0, 0}
local mqtt_host = "x.x.x.x"
local mqtt_port = 1883
local mqtt_isssl = false
local device_id = read_device_id()
local client_id = "relay_control_" .. device_id
local user_name = "user"
local password = "password"
local pub_topic = "/relay/status/" .. device_id
local sub_topic = "/relay/control/" .. device_id
local mqttc = nil
local ip_ready = false
local mqtt_ready = false

local function update_topics(new_device_id)
    device_id = new_device_id or read_device_id()
    client_id = "relay_control_" .. device_id
    pub_topic = "/relay/status/" .. device_id
    sub_topic = "/relay/control/" .. device_id
    log_ok("mqtt", "device_id", device_id)
    log_ok("mqtt", "client_id", client_id)
    log_ok("mqtt", "host", mqtt_host, "port", mqtt_port, "ssl", mqtt_isssl)
    log_ok("mqtt", "pub_topic", pub_topic)
    log_ok("mqtt", "sub_topic", sub_topic)
end

local function log_boot_info()
    local reset_reason = "n/a"
    if pm and pm.lastReson then
        local ok, value = pcall(pm.lastReson)
        if ok then
            reset_reason = value
        end
    end
    local bsp = "n/a"
    if rtos and rtos.bsp then
        local ok, value = pcall(rtos.bsp)
        if ok then
            bsp = value
        end
    end
    log_ok("boot", "project", PROJECT, "version", VERSION)
    log_ok("boot", "bsp", bsp, "reset", reset_reason, "device", device_id)
    log_ok("boot", "sys mem", get_mem("sys"), "lua mem", get_mem("lua"))
    log_ok("boot", "mobile.status", read_mobile_status())
end

log_boot_info()
update_topics(device_id)

sys.subscribe("IP_READY", function(ip, adapter)
    ip_ready = true
    log_ok("network", "IP_READY", ip, adapter, "mobile.status", read_mobile_status())
end)

sys.subscribe("IP_LOSE", function(adapter)
    ip_ready = false
    mqtt_ready = false
    log_warn("network", "IP_LOSE", adapter, "mobile.status", read_mobile_status())
end)

sys.taskInit(function()
    call_safe("watchdog", air153C_wtd.init, hw_watchdog_pin)
    call_safe("watchdog", air153C_wtd.feed_dog, hw_watchdog_pin)
    sys.wait(3000)
    log_ok("watchdog", "hardware watchdog initialized", hw_watchdog_pin)
end)

sys.taskInit(function()
    while true do
        local ret, relay_id, state = sys.waitUntil("do_relay_control")
        if ret then
            if type(relay_id) ~= "number" or relay_id < 1 or relay_id > #relay_handles then
                log_warn("relay", "invalid relay id", relay_id, "state", state)
            elseif state ~= 0 and state ~= 1 then
                log_warn("relay", "invalid state", relay_id, state)
            elseif not relay_handles[relay_id] then
                log_err("relay", "missing relay handle", relay_id, relay_pins[relay_id])
            elseif not relay_enable_handle then
                log_err("relay", "relay enable handle missing")
            else
                log_ok("relay", "set begin", relay_id, "pin", relay_pins[relay_id], "state", state)
                safe_pin_write("relay_enable", relay_enable_handle, 1)
                sys.wait(5)
                if safe_pin_write("relay" .. relay_id, relay_handles[relay_id], state) then
                    relay_states[relay_id] = state
                    sys.publish("relay_state_changed", relay_id, state)
                end
                sys.wait(5)
                safe_pin_write("relay_enable", relay_enable_handle, 0)
                log_ok("relay", "set end", relay_id, table.concat(relay_states, ","))
            end
        end
    end
end)

sys.taskInit(function()
    local last_states = {0, 0, 0, 0}
    while true do
        for index = 1, 4 do
            local raw = call_read("input" .. index, input_handles[index])
            if raw ~= nil then
                local state = raw == 0 and 1 or 0
                if state ~= last_states[index] then
                    last_states[index] = state
                    log_ok("input", "changed", index, "pin", input_pins[index], "raw", raw, "relay_state", state)
                    sys.publish("do_relay_control", index, state)
                end
            end
        end
        sys.wait(50)
    end
end)

sys.taskInit(function()
    if not reload_handle then
        log_warn("reload", "button disabled, handle missing", reload_pin)
        return
    end
    local pressed = false
    local held_ticks = 0
    local long_reported = false
    while true do
        local raw = call_read("reload", reload_handle)
        local now_pressed = raw == 0
        if now_pressed and not pressed then
            pressed = true
            held_ticks = 0
            long_reported = false
            log_ok("reload", "pressed", reload_pin)
        elseif now_pressed and pressed then
            held_ticks = held_ticks + 1
            if held_ticks >= 50 and not long_reported then
                long_reported = true
                log_warn("reload", "long press detected", reload_pin, "factory reset intentionally disabled")
            end
        elseif not now_pressed and pressed then
            pressed = false
            local held_ms = held_ticks * 100
            if long_reported then
                log_warn("reload", "released after long press", held_ms, "ms")
            else
                log_ok("reload", "short press", held_ms, "ms")
            end
        end
        sys.wait(100)
    end
end)

sys.taskInit(function()
    sys.wait(5000)
    while true do
        log_ok("watchdog", "feed hardware watchdog", hw_watchdog_pin)
        call_safe("watchdog", air153C_wtd.feed_dog, hw_watchdog_pin)
        sys.wait(150000)
    end
end)

sys.taskInit(function()
    local last_state = ""
    while true do
        local mobile_status = read_mobile_status()
        local state = "WAIT_NET"
        if mqtt_ready then
            state = "MQTT_READY"
        elseif ip_ready then
            state = "IP_READY"
        elseif mobile_status == 1 then
            state = "CELL_REGISTERED"
        end
        if state ~= last_state then
            log_ok("netled", "state", state, "ip", bool_text(ip_ready), "mqtt", bool_text(mqtt_ready), "mobile", mobile_status)
            last_state = state
        end
        if state == "MQTT_READY" then
            local ok_breath, err_breath = pcall(netLed.setupBreateLed, LEDA)
            if not ok_breath then
                log_err("netled", "breathing LED failed", err_breath)
                sys.wait(1000)
            end
        elseif state == "IP_READY" or state == "CELL_REGISTERED" then
            safe_pin_write("netled", LEDA, 1)
            sys.wait(200)
            safe_pin_write("netled", LEDA, 0)
            sys.wait(800)
        else
            safe_pin_write("netled", LEDA, 1)
            sys.wait(100)
            safe_pin_write("netled", LEDA, 0)
            sys.wait(2900)
        end
    end
end)

sys.taskInit(function()
    while true do
        local ret, ip, adapter = sys.waitUntil("IP_READY", 120000)
        if ret then
            ip_ready = true
            update_topics(read_device_id())
            log_ok("network", "ready", ip, adapter, "device", device_id)
            sys.publish("net_ready", device_id)
        else
            log_warn("network", "waiting for IP_READY", "mobile.status", read_mobile_status(), "sys mem", get_mem("sys"), "lua mem", get_mem("lua"))
        end
    end
end)

sys.taskInit(function()
    local ret = sys.waitUntil("net_ready")
    if not ret then
        log_err("mqtt", "net_ready wait failed")
        return
    end

    local ok_create, client = pcall(mqtt.create, nil, mqtt_host, mqtt_port, mqtt_isssl)
    if not ok_create or not client then
        log_err("mqtt", "create failed", client)
        return
    end
    mqttc = client

    call_safe("mqtt", function()
        mqttc:auth(client_id, user_name, password)
        mqttc:keepalive(240)
        mqttc:autoreconn(true, 3000)
    end)

    mqttc:on(function(mqtt_client, event, data, payload)
        log_ok("mqtt", "event", event, data or "-", payload or "-")
        if event == "conack" then
            mqtt_ready = true
            sys.publish("mqtt_conack")
            local ok_sub, sub_err = pcall(function()
                mqtt_client:subscribe(sub_topic)
            end)
            if not ok_sub then
                log_err("mqtt", "subscribe failed", sub_topic, sub_err)
            else
                log_ok("mqtt", "subscribed", sub_topic)
            end
            publish_status(mqtt_client, pub_topic, relay_states, "conack")
        elseif event == "recv" then
            if data ~= sub_topic then
                log_warn("mqtt", "ignore topic", data, "expected", sub_topic)
                return
            end
            if payload == "status" or payload == "STATUS" then
                publish_status(mqtt_client, pub_topic, relay_states, "command_status")
                return
            end
            -- INFO: parse "<relayId>:<state>" without Lua patterns. The LuatOS V2034 Lua
            -- pattern library silently returns nil for %d / %w captures on otherwise
            -- valid payloads, so use plain string.find (3rd arg true = plain text) + string.sub.
            local colon_pos = payload and string.find(payload, ":", 1, true)
            local relay_id_raw, command
            if colon_pos then
                relay_id_raw = string.sub(payload, 1, colon_pos - 1)
                command = string.sub(payload, colon_pos + 1)
            end
            local relay_id = tonumber(relay_id_raw)
            local state = normalize_command(command)
            if relay_id and relay_id >= 1 and relay_id <= 4 and state ~= nil then
                log_ok("mqtt", "command", relay_id, command, state)
                sys.publish("do_relay_control", relay_id, state)
            else
                log_warn("mqtt", "invalid payload", payload)
            end
        elseif event == "disconnect" or event == "close" then
            mqtt_ready = false
            log_warn("mqtt", "connection lost", event, data)
        end
    end)

    local ok_connect, connect_err = pcall(function()
        mqttc:connect()
    end)
    if not ok_connect then
        log_err("mqtt", "connect failed", connect_err)
        mqtt_ready = false
        return
    end

    local conack = sys.waitUntil("mqtt_conack", 120000)
    if not conack then
        log_warn("mqtt", "conack timeout; autoreconnect remains enabled")
    end

    sys.subscribe("relay_state_changed", function(relay_id, state)
        publish_status(mqttc, pub_topic, relay_states, "relay_" .. tostring(relay_id) .. "_" .. tostring(state))
    end)

    while true do
        sys.wait(60000)
        publish_status(mqttc, pub_topic, relay_states, "periodic")
    end
end)

sys.taskInit(function()
    while true do
        sys.wait(30000)
        log_ok("health", "sys mem", get_mem("sys"), "lua mem", get_mem("lua"), "ip", bool_text(ip_ready), "mqtt", bool_text(mqtt_ready), "mobile", read_mobile_status(), "relays", table.concat(relay_states, ","))
    end
end)

-- User code ends here---------------------------------------------
-- Always end with this line
sys.run()
-- Don't add any statements after sys.run()!!!!!
