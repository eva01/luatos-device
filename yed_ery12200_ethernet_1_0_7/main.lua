-- LuaTools needs PROJECT and VERSION information
PROJECT = "relay_2_mqtt_netled"
VERSION = "1.0.7"

log.info("main", PROJECT, VERSION)

_G.sys = require("sys")
_G.sysplus = require("sysplus")
local netLed = require("netLed")

require("air153C_wtd")

if wdt then
    wdt.init(9000)
    sys.timerLoopStart(wdt.feed, 3000)
end

if rtos.bsp() == "EC618" and pm and pm.PWK_MODE then
    pm.power(pm.PWK_MODE, false)
end

pm.ioVol(pm.IOVOL_ALL_GPIO, 3300)

local relay_pins = {21, 3}
local input_pins = {36, 37}
local relay_enable_pin = 25
local hw_watchdog_pin = 28
local netled_pin = 27
local reload_pin = 26
local rs485_enable_pin = 2
local ch390_power_pin = 24
local ch390_spi_id = 0
local ch390_cs_pin = 8
local ch390_irq_pin = 22

local relay1 = gpio.setup(relay_pins[1], 0)
local relay2 = gpio.setup(relay_pins[2], 0)
local relay_handles = {relay1, relay2}
local relay_enable_handle = gpio.setup(relay_enable_pin, 0)
local LEDA = gpio.setup(netled_pin, 0, gpio.PULLUP)

local input_handles = {}
for i, pin in ipairs(input_pins) do
    input_handles[i] = gpio.setup(pin, nil, gpio.PULLUP)
end

log.info("GPIO", "Setup relay pins:", table.concat(relay_pins, ","))
log.info("GPIO", "Setup relay enable pin:", relay_enable_pin)
log.info("GPIO", "Setup hardware watchdog pin:", hw_watchdog_pin)
log.info("GPIO", "Setup netLed pin:", netled_pin)
log.info("GPIO", "Setup reload pin:", reload_pin)
log.info("GPIO", "Setup RS485 enable pin:", rs485_enable_pin)
log.info("GPIO", "Setup CH390 power pin:", ch390_power_pin)
log.info("GPIO", "Setup CH390 SPI/CS/IRQ:", ch390_spi_id, ch390_cs_pin, ch390_irq_pin)
log.info("GPIO", "Setup input pins:", table.concat(input_pins, ","))

local relay_states = {0, 0}
local input_poll_ms = 50
local input_debounce_samples = 3

local mqtt_host = "192.168.80.51"
local mqtt_port = 1883
local mqtt_isssl = false
local client_id = "relay_control_" .. (mcu.unique_id():toHex())
local user_name = "user"
local password = "password"
local device_id = mcu.unique_id():toHex()
local pub_topic = "/relay/status/" .. device_id
local sub_topic = "/relay/control/" .. device_id

local mqttc = nil

local function resolve_device_id()
    if mobile and mobile.imei then
        return mobile.imei()
    end
    return mcu.unique_id():toHex()
end

local function start_ch390_ethernet()
    log.info("eth", "power cycle CH390", ch390_power_pin)
    gpio.setup(ch390_power_pin, 0, gpio.PULLUP)
    sys.wait(500)
    gpio.setup(ch390_power_pin, 1, gpio.PULLUP)
    sys.wait(100)

    local spi_result = spi.setup(ch390_spi_id, nil, 0, 0, 8, 25600000)
    log.info("eth", "spi.setup", spi_result)
    if spi_result ~= 0 then
        log.error("eth", "spi open error", spi_result)
        return
    end

    if netdrv.setup(socket.LWIP_ETH, netdrv.CH390, {
        spi = ch390_spi_id,
        cs = ch390_cs_pin,
        irq = ch390_irq_pin
    }) == false then
        log.error("eth", "netdrv setup failed")
        return
    end

    sys.wait(500)
    netdrv.dhcp(socket.LWIP_ETH, true)

    while true do
        local ip, mask, gw = netdrv.ipv4(socket.LWIP_ETH)
        local linked = netdrv.link(socket.LWIP_ETH)
        local ready = netdrv.ready(socket.LWIP_ETH)
        log.info("eth", "status", ip, mask, gw, linked, ready)
        if linked and ready and ip and ip ~= "0.0.0.0" then
            socket.dft(socket.LWIP_ETH)
            socket.setDNS(socket.LWIP_ETH, 1, "8.8.8.8")
            socket.setDNS(socket.LWIP_ETH, 2, "1.1.1.1")
            log.info("eth", "ready", socket.localIP(socket.LWIP_ETH), socket.dft())
            sys.publish("net_ready", resolve_device_id(), socket.LWIP_ETH)
            return
        end
        sys.wait(1000)
    end
end

sys.taskInit(function()
    air153C_wtd.init(hw_watchdog_pin)
    air153C_wtd.feed_dog(hw_watchdog_pin)
    sys.wait(3000)
    log.info("Watchdog", "Hardware watchdog initialized")
end)

sys.taskInit(function()
    log.info("os.date()", os.date())
    local t = rtc.get()
    log.info("rtc", json.encode(t))
    sys.wait(2000)

    while true do
        local ret, relay_id, state = sys.waitUntil("do_relay_control")
        if ret and relay_id and relay_handles[relay_id] then
            log.info("Relay", "Setting relay", relay_id, "to:", state)
            relay_enable_handle(1)
            sys.wait(5)
            relay_handles[relay_id](state)
            sys.wait(5)
            relay_enable_handle(0)
            relay_states[relay_id] = state
            sys.publish("relay_state_changed", relay_id, state)
        end
    end
end)

sys.taskInit(function()
    local stable_states = {0, 0}
    local candidate_states = {}
    local candidate_counts = {0, 0}
    while true do
        for i = 1, 2 do
            local state = input_handles[i]() == 0 and 1 or 0
            if state == stable_states[i] then
                candidate_states[i] = nil
                candidate_counts[i] = 0
            elseif state == candidate_states[i] then
                candidate_counts[i] = candidate_counts[i] + 1
                if candidate_counts[i] >= input_debounce_samples then
                    stable_states[i] = state
                    candidate_states[i] = nil
                    candidate_counts[i] = 0
                    sys.publish("do_relay_control", i, state)
                    log.info("Input", "Input pin", input_pins[i], "changed, relay", i, "set to", state, "debounced_ms", input_poll_ms * input_debounce_samples)
                end
            else
                candidate_states[i] = state
                candidate_counts[i] = 1
            end
        end
        sys.wait(input_poll_ms)
    end
end)

sys.taskInit(function()
    sys.wait(5000)
    while true do
        log.info("Watchdog", "Feeding hardware watchdog")
        air153C_wtd.feed_dog(hw_watchdog_pin)
        sys.wait(150000)
    end
end)

sys.taskInit(function()
    sys.wait(5000)
    while true do
        if socket.adapter(socket.LWIP_ETH) then
            sys.wait(600)
            netLed.setupBreateLed(LEDA)
        else
            sys.wait(3000)
            LEDA(0)
            log.info("eth", "net fail")
        end
    end
end)

sys.taskInit(function()
    start_ch390_ethernet()
end)

sys.taskInit(function()
    local _, ready_device_id = sys.waitUntil("net_ready")
    device_id = ready_device_id or resolve_device_id()
    client_id = "relay_control_" .. device_id
    pub_topic = "/relay/status/" .. device_id
    sub_topic = "/relay/control/" .. device_id
    log.info("mqtt", "adapter", socket.dft())
    log.info("mqtt", "device_id", device_id)
    log.info("mqtt", "pub_topic", pub_topic)
    log.info("mqtt", "sub_topic", sub_topic)
    sys.publish("mqtt_ready", device_id)
end)

sys.taskInit(function()
    sys.waitUntil("mqtt_ready")
    mqttc = mqtt.create(nil, mqtt_host, mqtt_port, mqtt_isssl)
    mqttc:auth(client_id, user_name, password)
    mqttc:keepalive(240)
    mqttc:autoreconn(true, 3000)

    mqttc:on(function(mqtt_client, event, data, payload)
        log.info("mqtt", "event", event, data, payload)
        if event == "conack" then
            sys.publish("mqtt_conack")
            mqtt_client:subscribe(sub_topic)
            mqtt_client:publish(pub_topic, table.concat(relay_states, ","), 1)
        elseif event == "recv" then
            log.info("mqtt", "Received control command", data, payload)
            if data == sub_topic then
                local relay_id, command = payload:match("(%d+):(%w+)")
                relay_id = tonumber(relay_id)
                if relay_id and relay_id >= 1 and relay_id <= 2 then
                    if command == "1" or command == "on" or command == "ON" then
                        sys.publish("do_relay_control", relay_id, 1)
                    elseif command == "0" or command == "off" or command == "OFF" then
                        sys.publish("do_relay_control", relay_id, 0)
                    end
                elseif payload == "status" or payload == "STATUS" then
                    mqtt_client:publish(pub_topic, table.concat(relay_states, ","), 1)
                end
            end
        end
    end)

    mqttc:connect()
    sys.waitUntil("mqtt_conack")
    sys.subscribe("relay_state_changed", function(relay_id, state)
        if mqttc and mqttc:ready() then
            mqttc:publish(pub_topic, table.concat(relay_states, ","), 1)
            log.info("mqtt", "Publishing relay state", relay_id, state)
        end
    end)

    while true do
        sys.wait(60000)
        if mqttc and mqttc:ready() then
            mqttc:publish(pub_topic, table.concat(relay_states, ","), 1)
            log.info("mqtt", "Periodic relay state update", table.concat(relay_states, ","))
        end
    end
end)

sys.run()
