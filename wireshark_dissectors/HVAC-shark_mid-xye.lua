-- HVAC Shark Dissector — XYE (RS-485) + Midea UART (SmartKey) protocols
-- Protocol auto-detection via byte 1 of protocol data:
--   XYE commands (0xC0-0xCD range) → XYE decoder
--   UART length  (0x0D-0x40 range) → UART decoder
-- See: PI HVAC databridge docs/protocol_vs_xye.md section 11
--
-- NOTE: Capture files may contain cut-off packets at the start of a recording
-- session due to frame mis-alignment (the logic analyser can begin capturing
-- mid-frame). These partial frames will show CRC/checksum INVALID errors and
-- may decode as garbled data. This is expected and not a dissector bug.

hvac_shark_proto = Proto("HVAC_Shark", "HVAC Shark Protocol")

-- ── Proto fields ─────────────────────────────────────────────────────────────
local f = hvac_shark_proto.fields
-- HVAC_shark header
f.start_sequence  = ProtoField.string("hvac_shark.start_sequence",  "Start Sequence")
f.manufacturer    = ProtoField.uint8 ("hvac_shark.manufacturer",    "Manufacturer")
f.bus_type        = ProtoField.uint8 ("hvac_shark.bus_type",        "Bus Type")
f.header_version  = ProtoField.uint8 ("hvac_shark.header_version",  "Header Version")
f.logic_channel   = ProtoField.string("hvac_shark.logic_channel",   "Logic Channel")
f.circuit_board   = ProtoField.string("hvac_shark.circuit_board",   "Connected Components")
f.channel_comment = ProtoField.string("hvac_shark.channel_comment", "Comment")
-- shared
f.protocol_type   = ProtoField.string("hvac_shark.protocol_type",   "Protocol")
f.command_code    = ProtoField.uint8 ("hvac_shark.command_code",    "Command Code", base.HEX)
f.data            = ProtoField.bytes ("hvac_shark.data",            "Data")
f.command_length  = ProtoField.uint16("hvac_shark.command_length",  "Frame Length")
-- UART-specific header fields
f.uart_length     = ProtoField.uint8 ("hvac_shark.uart.length",     "Length")
f.uart_appliance  = ProtoField.uint8 ("hvac_shark.uart.appliance",  "Appliance Type", base.HEX)
f.uart_sync       = ProtoField.uint8 ("hvac_shark.uart.sync",       "Sync Byte", base.HEX)
f.uart_protocol   = ProtoField.uint8 ("hvac_shark.uart.protocol",   "Protocol Version")
f.uart_msg_type   = ProtoField.uint8 ("hvac_shark.uart.msg_type",   "Message Type", base.HEX)
-- IR-specific fields
f.ir_device_id    = ProtoField.uint8 ("hvac_shark.ir.device_id",    "Device ID", base.HEX)
f.ir_command      = ProtoField.uint8 ("hvac_shark.ir.command",      "Command Byte", base.HEX)
f.ir_extended     = ProtoField.uint8 ("hvac_shark.ir.extended",     "Extended Byte", base.HEX)
f.ir_complement   = ProtoField.string("hvac_shark.ir.complement",   "Complement Check")
f.ir_frame_type   = ProtoField.string("hvac_shark.ir.frame_type",   "Frame Type")


-- ── XYE lookup tables ────────────────────────────────────────────────────────

local XYE_COMMANDS = {
    [0xC0] = "Query",    [0xC3] = "Set",    [0xC4] = "Ext.Query",
    [0xC6] = "FollowMe", [0xCC] = "Lock",   [0xCD] = "Unlock",
    [0xD0] = "Broadcast",
}

function getFanString(fan)
    if fan == 0x80 then return "Auto"
    elseif fan == 0x01 then return "High"
    elseif fan == 0x02 then return "Medium"
    elseif fan == 0x04 then return "Low"
    elseif fan == 0x00 then return "Off"
    else return string.format("Unknown (0x%02X)", fan) end
end

function getOperModeString(oper_mode)
    if oper_mode == 0x00 then return "Off"
    elseif oper_mode == 0x81 then return "Fan"
    elseif oper_mode == 0x82 then return "Dry"
    elseif oper_mode == 0x84 then return "Heat"
    elseif oper_mode == 0x88 then return "Cool"
    elseif oper_mode == 0x90 then return "Auto"
    elseif oper_mode == 0x91 then return "Auto (sub: Fan)"
    elseif oper_mode == 0x94 then return "Auto (sub: Heat)"
    elseif oper_mode == 0x98 then return "Auto (sub: Cool)"
    else return string.format("Unknown (0x%02X)", oper_mode) end
end

function getSwingString(swing)
    if swing == 0x00 then return "Off"
    elseif swing == 0x10 then return "Vertical (U/D)"
    elseif swing == 0x20 then return "Horizontal (L/R)"
    elseif swing == 0x30 then return "Both (U/D + L/R)"
    else return string.format("Unknown (0x%02X)", swing) end
end


-- ── Serial Protocol lookup tables (shared by UART and R/T buses) ─────────────

local SERIAL_MSG_TYPES = {
    [0x02] = "Command",       [0x03] = "Response/Notification",
    [0x04] = "Heartbeat",     [0x05] = "Handshake/ACK",
    [0x06] = "Status Upload", [0x07] = "Device ID",
    [0x0A] = "Error Report",  [0x0D] = "Network Init",
    [0x0F] = "Status Transport", [0x11] = "Status Transport",
    [0x13] = "Config Data",   [0x14] = "Config Accepted",
    [0x15] = "Config Accepted", [0x16] = "Device Event",
    [0x61] = "Time Sync",     [0x63] = "Network Status",
    [0x64] = "OTA/Key Trigger", [0x65] = "RAC Serial",
    [0x68] = "WiFi Config",
    [0x82] = "Mode Check",    [0x83] = "Config Reset",
    [0x85] = "Config Response", [0x87] = "Version Info",
    [0x90] = "Exception",     [0xA0] = "Proprietary",
}

local SERIAL_COMMAND_IDS = {
    [0x40] = "Set Status",    [0x41] = "Query",
    [0x93] = "Ext Status",
    [0xA0] = "Heartbeat ACK",
    [0xA1] = "Heartbeat A1 (Energy)",
    [0xA2] = "Heartbeat A2",
    [0xA3] = "Heartbeat A3",
    [0xA5] = "Heartbeat A5 (Outdoor)",
    [0xA6] = "Heartbeat A6 (Network)",
    [0xB0] = "TLV Set",       [0xB1] = "TLV Response",
    [0xB5] = "Capabilities",  [0xC0] = "Status Response",
    [0xC1] = "C1 Response",
}

local function getSerialModeString(mode_bits)
    if mode_bits == 1 then return "Auto"
    elseif mode_bits == 2 then return "Cool"
    elseif mode_bits == 3 then return "Dry"
    elseif mode_bits == 4 then return "Heat"
    elseif mode_bits == 5 then return "Fan Only"
    elseif mode_bits == 6 then return "SmartDry"
    else return string.format("Unknown (%d)", mode_bits) end
end

local function getSerialFanString(fan)
    if fan == 102 then return "Auto"
    elseif fan == 100 then return "Turbo"
    elseif fan == 80 then return "High"
    elseif fan == 60 then return "Medium"
    elseif fan == 40 then return "Low"
    elseif fan == 20 then return "Silent"
    elseif fan == 30 then return "Low (variant)"     -- hardware variant per dudanov
    elseif fan == 50 then return "Medium (variant)"   -- hardware variant per dudanov
    else return string.format("Unknown (%d)", fan) end
end

local function getSerialSwingString(nibble)
    if nibble == 0x00 then return "Off"
    elseif nibble == 0x03 then return "Horizontal"
    elseif nibble == 0x0C then return "Vertical"
    elseif nibble == 0x0F then return "Both"
    else return string.format("0x%02X", nibble) end
end


-- ── CRC-8/854 lookup table (from PI HVAC databridge / all Midea UART sources) ──

local CRC8_TABLE = {
    0x00, 0x5E, 0xBC, 0xE2, 0x61, 0x3F, 0xDD, 0x83,
    0xC2, 0x9C, 0x7E, 0x20, 0xA3, 0xFD, 0x1F, 0x41,
    0x9D, 0xC3, 0x21, 0x7F, 0xFC, 0xA2, 0x40, 0x1E,
    0x5F, 0x01, 0xE3, 0xBD, 0x3E, 0x60, 0x82, 0xDC,
    0x23, 0x7D, 0x9F, 0xC1, 0x42, 0x1C, 0xFE, 0xA0,
    0xE1, 0xBF, 0x5D, 0x03, 0x80, 0xDE, 0x3C, 0x62,
    0xBE, 0xE0, 0x02, 0x5C, 0xDF, 0x81, 0x63, 0x3D,
    0x7C, 0x22, 0xC0, 0x9E, 0x1D, 0x43, 0xA1, 0xFF,
    0x46, 0x18, 0xFA, 0xA4, 0x27, 0x79, 0x9B, 0xC5,
    0x84, 0xDA, 0x38, 0x66, 0xE5, 0xBB, 0x59, 0x07,
    0xDB, 0x85, 0x67, 0x39, 0xBA, 0xE4, 0x06, 0x58,
    0x19, 0x47, 0xA5, 0xFB, 0x78, 0x26, 0xC4, 0x9A,
    0x65, 0x3B, 0xD9, 0x87, 0x04, 0x5A, 0xB8, 0xE6,
    0xA7, 0xF9, 0x1B, 0x45, 0xC6, 0x98, 0x7A, 0x24,
    0xF8, 0xA6, 0x44, 0x1A, 0x99, 0xC7, 0x25, 0x7B,
    0x3A, 0x64, 0x86, 0xD8, 0x5B, 0x05, 0xE7, 0xB9,
    0x8C, 0xD2, 0x30, 0x6E, 0xED, 0xB3, 0x51, 0x0F,
    0x4E, 0x10, 0xF2, 0xAC, 0x2F, 0x71, 0x93, 0xCD,
    0x11, 0x4F, 0xAD, 0xF3, 0x70, 0x2E, 0xCC, 0x92,
    0xD3, 0x8D, 0x6F, 0x31, 0xB2, 0xEC, 0x0E, 0x50,
    0xAF, 0xF1, 0x13, 0x4D, 0xCE, 0x90, 0x72, 0x2C,
    0x6D, 0x33, 0xD1, 0x8F, 0x0C, 0x52, 0xB0, 0xEE,
    0x32, 0x6C, 0x8E, 0xD0, 0x53, 0x0D, 0xEF, 0xB1,
    0xF0, 0xAE, 0x4C, 0x12, 0x91, 0xCF, 0x2D, 0x73,
    0xCA, 0x94, 0x76, 0x28, 0xAB, 0xF5, 0x17, 0x49,
    0x08, 0x56, 0xB4, 0xEA, 0x69, 0x37, 0xD5, 0x8B,
    0x57, 0x09, 0xEB, 0xB5, 0x36, 0x68, 0x8A, 0xD4,
    0x95, 0xCB, 0x29, 0x77, 0xF4, 0xAA, 0x48, 0x16,
    0xE9, 0xB7, 0x55, 0x0B, 0x88, 0xD6, 0x34, 0x6A,
    0x2B, 0x75, 0x97, 0xC9, 0x4A, 0x14, 0xF6, 0xA8,
    0x74, 0x2A, 0xC8, 0x96, 0x15, 0x4B, 0xA9, 0xF7,
    0xB6, 0xE8, 0x0A, 0x54, 0xD7, 0x89, 0x6B, 0x35,
}

local function uart_crc8(buf, offset, length)
    -- CRC-8/854 over body bytes (frame[10..N-3])
    local crc = 0
    for i = 0, length - 1 do
        -- Lua table is 1-indexed, CRC8_TABLE[0] → CRC8_TABLE[1]
        crc = CRC8_TABLE[bit.bxor(crc, buf(offset + i, 1):uint()) + 1]
    end
    return crc
end

local function uart_checksum(buf, from_offset, to_offset)
    -- Additive checksum: (256 - sum(frame[1..N-2])) & 0xFF
    local s = 0
    for i = from_offset, to_offset do
        s = s + buf(i, 1):uint()
    end
    return bit.band(256 - s, 0xFF)
end


-- ── XYE CRC (two's complement sum) ──────────────────────────────────────────

local function validate_crc(crc_input_data, length)
    local sum = 0
    for i = 0, length - 3 do
        sum = sum + crc_input_data(i, 1):uint()
    end
    sum = sum + crc_input_data( (length - 1), 1):uint()
    return 255 - (sum % 256)
end


-- ══════════════════════════════════════════════════════════════════════════════
-- ── UART BODY DECODERS ──────────────────────────────────────────────────────
-- ══════════════════════════════════════════════════════════════════════════════

local function decode_uart_c0_status(body_tree, buf, body_off, body_len, cmd_id)
    -- C0 / A0 Status body decoder
    -- cmd_id: 0xC0 = dongle status response; 0xA0 = mainboard heartbeat ACK (same layout)
    -- Reference: PI HVAC databridge docs/protocol_uart.md section 6

    cmd_id = cmd_id or 0xC0
    local cmd_label = cmd_id == 0xA0 and "Heartbeat ACK (C0-format status)" or "Status Response"
    body_tree:add(buf(body_off + 0, 1), string.format("Command ID: 0x%02X (%s)", cmd_id, cmd_label))

    -- body[1]: power/error flags
    local b1 = buf(body_off + 1, 1):uint()
    local power = bit.band(b1, 0x01) == 1
    local in_error = bit.band(b1, 0x80) ~= 0
    body_tree:add(buf(body_off + 1, 1), string.format("Power: %s, Error: %s",
        power and "ON" or "OFF", in_error and "YES" or "no"))

    -- body[2]: mode + temperature
    local b2 = buf(body_off + 2, 1):uint()
    local mode_bits = bit.rshift(bit.band(b2, 0xE0), 5)
    local temp_int = bit.band(b2, 0x0F) + 16
    local temp_half = bit.band(b2, 0x10) ~= 0
    local set_temp = temp_int + (temp_half and 0.5 or 0)
    body_tree:add(buf(body_off + 2, 1), string.format("Mode: %s, Set Temp: %.1f C",
        getSerialModeString(mode_bits), set_temp))

    -- body[3]: fan speed
    local fan = buf(body_off + 3, 1):uint()
    body_tree:add(buf(body_off + 3, 1), string.format("Fan Speed: %d (%s)",
        fan, getSerialFanString(fan)))

    -- body[4-6]: timer fields
    body_tree:add(buf(body_off + 4, 3), "Timer bytes: " ..
        tostring(buf(body_off + 4, 3):bytes()))

    -- body[7]: swing mode
    local swing_val = bit.band(buf(body_off + 7, 1):uint(), 0x0F)
    body_tree:add(buf(body_off + 7, 1), string.format("Swing: %s",
        getSerialSwingString(swing_val)))

    -- body[8]: cosy sleep, turbo (location 2), save, Follow Me
    local b8 = buf(body_off + 8, 1):uint()
    local turbo2 = bit.band(b8, 0x20) ~= 0
    local follow_me = bit.band(b8, 0x80) ~= 0
    body_tree:add(buf(body_off + 8, 1), string.format(
        "Cosy Sleep: %d, Save: %s, Turbo2: %s, FollowMe: %s",
        bit.band(b8, 0x03),
        bit.band(b8, 0x08) ~= 0 and "yes" or "no",
        turbo2 and "yes" or "no",
        follow_me and "yes" or "no"))

    -- body[9]: eco, child sleep, PTC, dry clean
    -- *** CONTROVERSY: ECO bit position ***
    -- dudanov + midea-local: bit 4 (0x10) ← consensus
    -- PI HVAC databridge response.py: bit 7 (0x80) ← confirmed bug
    -- SET command (0x40) uses bit 7 — different bit for set vs response!
    local b9 = buf(body_off + 9, 1):uint()
    local eco_bit4 = bit.band(b9, 0x10) ~= 0   -- consensus: bit 4
    local eco_bit7 = bit.band(b9, 0x80) ~= 0   -- bug: bit 7
    local eco_str = ""
    if eco_bit4 then eco_str = "ECO(bit4)" end
    if eco_bit7 then eco_str = eco_str .. (eco_str ~= "" and "+ECO(bit7)" or "ECO(bit7)") end
    if eco_str == "" then eco_str = "no" end
    body_tree:add(buf(body_off + 9, 1), string.format(
        "ECO: %s, ChildSleep: %s, NaturalFan: %s, DryClean: %s, PTC: %s, CleanUp: %s   [NOTE: ECO bit controversial - bit4=dudanov/midea-local, bit7=set-cmd]",
        eco_str,
        bit.band(b9, 0x01) ~= 0 and "yes" or "no",
        bit.band(b9, 0x02) ~= 0 and "yes" or "no",
        bit.band(b9, 0x04) ~= 0 and "yes" or "no",
        bit.band(b9, 0x08) ~= 0 and "yes" or "no",
        bit.band(b9, 0x20) ~= 0 and "yes" or "no"))

    -- body[10]: sleep, turbo (primary), temp unit, exchange air, night light, etc.
    local b10 = buf(body_off + 10, 1):uint()
    local sleep = bit.band(b10, 0x01) ~= 0
    local turbo = bit.band(b10, 0x02) ~= 0
    local temp_unit = bit.band(b10, 0x04) ~= 0 and "F" or "C"
    body_tree:add(buf(body_off + 10, 1), string.format(
        "Sleep: %s, Turbo: %s, Unit: %s, ExchAir: %s, NightLight: %s, CatchCold: %s, PeakElec: %s, CoolFan: %s",
        sleep and "yes" or "no", turbo and "yes" or "no", temp_unit,
        bit.band(b10, 0x08) ~= 0 and "yes" or "no",
        bit.band(b10, 0x10) ~= 0 and "yes" or "no",
        bit.band(b10, 0x20) ~= 0 and "yes" or "no",
        bit.band(b10, 0x40) ~= 0 and "yes" or "no",
        bit.band(b10, 0x80) ~= 0 and "yes" or "no"))

    -- body[11]: indoor temperature
    if body_len > 11 then
        local indoor_raw = buf(body_off + 11, 1):uint()
        local indoor_temp = (indoor_raw - 50) / 2.0
        body_tree:add(buf(body_off + 11, 1), string.format(
            "Indoor Temp: %.1f C (raw: %d)", indoor_temp, indoor_raw))
    end

    -- body[12]: outdoor temperature
    if body_len > 12 then
        local outdoor_raw = buf(body_off + 12, 1):uint()
        local outdoor_temp = (outdoor_raw - 50) / 2.0
        body_tree:add(buf(body_off + 12, 1), string.format(
            "Outdoor Temp: %.1f C (raw: %d)", outdoor_temp, outdoor_raw))
    end

    -- body[13]: new temperature + dust full
    if body_len > 13 then
        local b13 = buf(body_off + 13, 1):uint()
        local new_temp_raw = bit.band(b13, 0x1F)
        if new_temp_raw > 0 then
            body_tree:add(buf(body_off + 13, 1), string.format(
                "New Temp Override: %d C, Dust Full: %s",
                new_temp_raw + 12, bit.band(b13, 0x20) ~= 0 and "yes" or "no"))
        else
            body_tree:add(buf(body_off + 13, 1), string.format(
                "No temp override, Dust Full: %s",
                bit.band(b13, 0x20) ~= 0 and "yes" or "no"))
        end
    end

    -- body[14]: display state + PMV (Predicted Mean Vote)
    -- *** CONTROVERSY: display ON condition ***
    -- This doc: bits[6:4] == 0x7 → ON
    -- midea-local: bits[6:4] != 0x7 → ON (inverted!) + gated on power
    if body_len > 14 then
        local b14 = buf(body_off + 14, 1):uint()
        local disp_bits = bit.band(bit.rshift(b14, 4), 0x07)
        local pmv_raw = bit.band(b14, 0x0F)
        local pmv_str = pmv_raw == 0 and "disabled" or string.format("%.1f", pmv_raw * 0.5 - 3.5)
        body_tree:add(buf(body_off + 14, 1), string.format(
            "Display bits: 0x%X (%s=ON, %s=ON), PMV: %s   [CONTROVERSIAL: display interpretation inverted between sources]",
            disp_bits,
            disp_bits == 0x07 and "this-doc" or "midea-local",
            disp_bits ~= 0x07 and "this-doc=OFF" or "midea-local=OFF",
            pmv_str))
    end

    -- body[15]: temperature decimal precision (t1Dot = low nibble, t4Dot = high nibble)
    if body_len > 15 then
        local b15 = buf(body_off + 15, 1):uint()
        local t1_dot = bit.band(b15, 0x0F)
        local t4_dot = bit.rshift(b15, 4)
        body_tree:add(buf(body_off + 15, 1), string.format(
            "Temp decimals: indoor +0.%d, outdoor +0.%d  [tenths of degree]",
            t1_dot, t4_dot))
    end

    -- body[16]: error code
    if body_len > 16 then
        local err = buf(body_off + 16, 1):uint()
        if err > 0 then
            body_tree:add(buf(body_off + 16, 1), string.format("Error Code: E%d", err))
        else
            body_tree:add(buf(body_off + 16, 1), "Error Code: none")
        end
    end

    -- body[19]: humidity
    if body_len > 19 then
        local hum = bit.band(buf(body_off + 19, 1):uint(), 0x7F)
        body_tree:add(buf(body_off + 19, 1), string.format("Humidity Setpoint: %d%%", hum))
    end

    -- body[21]: frost protection
    if body_len > 21 then
        local b21 = buf(body_off + 21, 1):uint()
        body_tree:add(buf(body_off + 21, 1), string.format("Frost Protection: %s",
            bit.band(b21, 0x80) ~= 0 and "yes" or "no"))
    end
end


local function decode_c1_group1(body_tree, buf, body_off, body_len)
    -- Group Page 0x41 = Group 1 "Base Run Info"
    -- Source: mill1000/midea-msmart (see midea-msmart-mill1000.md, Finding 11)
    -- Cross-checked against own Session 1 captures (R/T bus, 13 unique frames).
    -- Session 6 service menu confirmation: T1=18°C, T3=2°C, T4=4°C, Tp=74°C
    --   → T1/T2 formula (raw-30)/2 confirmed; T3/T4 formula (raw-50)/2 confirmed;
    --   → Tp body[14] = direct integer °C (no lookup table needed on R/T bus).
    -- All field labels are Hypothesis unless noted [ConfirmedS6].

    local d = body_off + 4  -- first data byte after the 4-byte command header
    local n = body_len - 4  -- how many data bytes actually present

    -- body[4]: compressor actual frequency (Hz)
    if n >= 1 then
        body_tree:add(buf(d + 0, 1), string.format(
            "Compressor freq: %d Hz  [Hypothesis]",
            buf(d + 0, 1):uint()))
    end

    -- body[5]: indoor target frequency
    if n >= 2 then
        body_tree:add(buf(d + 1, 1), string.format(
            "Indoor target freq: %d  [Hypothesis]",
            buf(d + 1, 1):uint()))
    end

    -- body[6]: compressor current (unit unclear)
    if n >= 3 then
        body_tree:add(buf(d + 2, 1), string.format(
            "Compressor current: %d (raw, unit unclear)  [Hypothesis]",
            buf(d + 2, 1):uint()))
    end

    -- body[7]: outdoor total current (raw × 4)
    if n >= 4 then
        local raw7 = buf(d + 3, 1):uint()
        body_tree:add(buf(d + 3, 1), string.format(
            "Outdoor total current: %d (raw×4 = %d)  [Hypothesis]",
            raw7, raw7 * 4))
    end

    -- body[8]: outdoor supply voltage (raw)
    if n >= 5 then
        body_tree:add(buf(d + 4, 1), string.format(
            "Outdoor supply voltage: %d (raw)  [Hypothesis]",
            buf(d + 4, 1):uint()))
    end

    -- body[9]: indoor actual operating mode (raw)
    if n >= 6 then
        body_tree:add(buf(d + 5, 1), string.format(
            "Indoor operating mode: %d (raw)  [Hypothesis]",
            buf(d + 5, 1):uint()))
    end

    -- body[10]: T1 temperature (indoor coil or Follow-Me sensor) — offset 30
    -- Confirmed Session 6: raw=0x42=66 → (66-30)/2=18°C, service menu T1=18°C
    if n >= 7 then
        local raw = buf(d + 6, 1):uint()
        local t1 = raw >= 30 and (raw - 30) / 2.0 or (30 - raw) / -2.0
        body_tree:add(buf(d + 6, 1), string.format(
            "T1 indoor coil: %.1f °C (raw %d, offset 30)  [ConfirmedS6]",
            t1, raw))
    end

    -- body[11]: T2 temperature — offset 30
    if n >= 8 then
        local raw = buf(d + 7, 1):uint()
        local t2 = raw >= 30 and (raw - 30) / 2.0 or (30 - raw) / -2.0
        body_tree:add(buf(d + 7, 1), string.format(
            "T2: %.1f °C (raw %d, offset 30)  [Hypothesis]",
            t2, raw))
    end

    -- body[12]: T3 temperature (outdoor coil) — offset 50
    -- Confirmed Session 6: raw=0x36=54 → (54-50)/2=2°C, service menu T3=2°C
    if n >= 9 then
        local raw = buf(d + 8, 1):uint()
        local t3 = raw >= 50 and (raw - 50) / 2.0 or (50 - raw) / -2.0
        body_tree:add(buf(d + 8, 1), string.format(
            "T3 outdoor coil: %.1f °C (raw %d, offset 50)  [ConfirmedS6]",
            t3, raw))
    end

    -- body[13]: T4 temperature (outdoor ambient) — offset 50
    -- Confirmed Session 6: raw=0x3B=59 → (59-50)/2=4.5°C ≈ service menu T4=4°C
    if n >= 10 then
        local raw = buf(d + 9, 1):uint()
        local t4 = raw >= 50 and (raw - 50) / 2.0 or (50 - raw) / -2.0
        body_tree:add(buf(d + 9, 1), string.format(
            "T4 outdoor ambient: %.1f °C (raw %d, offset 50)  [ConfirmedS6]",
            t4, raw))
    end

    -- body[14]: discharge pipe temperature (Tp) — direct integer °C
    -- Confirmed Session 6: raw=0x4A=74, service menu Tp=74 °C → identity mapping.
    -- The outdoor MCU runs ucPQTempTab internally and sends the result in °C.
    if n >= 11 then
        body_tree:add(buf(d + 10, 1), string.format(
            "Tp discharge temp: %d °C  [Confirmed S6]",
            buf(d + 10, 1):uint()))
    end

    -- body[15]: outdoor DC fan stator flux
    if n >= 12 then
        body_tree:add(buf(d + 11, 1), string.format(
            "Outdoor fan stator flux: %d (raw)  [Hypothesis]",
            buf(d + 11, 1):uint()))
    end

    -- body[16]: outdoor supply voltage (duplicate?)
    if n >= 13 then
        body_tree:add(buf(d + 12, 1), string.format(
            "Outdoor voltage (2): %d (raw)  [Hypothesis]",
            buf(d + 12, 1):uint()))
    end

    -- body[17]: indoor fan stator flux
    if n >= 14 then
        body_tree:add(buf(d + 13, 1), string.format(
            "Indoor fan stator flux: %d (raw)  [Hypothesis]",
            buf(d + 13, 1):uint()))
    end

    -- body[18..23]: remaining bytes (not covered by Group 1 parser, typically zero)
    if n > 14 then
        body_tree:add(buf(d + 14, n - 14),
            "Tail: " .. tostring(buf(d + 14, n - 14):bytes()) .. "  [beyond Group 1 fields]")
    end
end


local function decode_c1_group2(body_tree, buf, body_off, body_len)
    -- Group 2 "Indoor Device Params"
    -- Source: mill1000/midea-msmart (see midea-msmart-mill1000.md, Finding 11)
    -- All fields: Hypothesis.

    local d = body_off + 4
    local n = body_len - 4

    -- body[4]: indoor set fan speed (raw × 8 = RPM)
    if n >= 1 then
        local raw = buf(d + 0, 1):uint()
        body_tree:add(buf(d + 0, 1), string.format(
            "Indoor set fan speed: %d RPM (raw %d ×8)  [Hypothesis]", raw * 8, raw))
    end

    -- body[5]: indoor actual fan speed (raw × 8 = RPM)
    if n >= 2 then
        local raw = buf(d + 1, 1):uint()
        body_tree:add(buf(d + 1, 1), string.format(
            "Indoor actual fan speed: %d RPM (raw %d ×8)  [Hypothesis]", raw * 8, raw))
    end

    -- body[6..8]: indoor fault state bytes 1-3 (8-bit packed each)
    if n >= 3 then
        body_tree:add(buf(d + 2, 1), string.format(
            "Indoor fault state 1: 0x%02X  [Hypothesis: 8 flags]", buf(d + 2, 1):uint()))
    end
    if n >= 4 then
        body_tree:add(buf(d + 3, 1), string.format(
            "Indoor fault state 2: 0x%02X  [Hypothesis: 8 flags]", buf(d + 3, 1):uint()))
    end
    if n >= 5 then
        body_tree:add(buf(d + 4, 1), string.format(
            "Indoor fault state 3: 0x%02X  [Hypothesis: 8 flags]", buf(d + 4, 1):uint()))
    end

    -- body[9..11]: indoor freq-limit state bytes 1-3
    if n >= 6 then
        body_tree:add(buf(d + 5, 1), string.format(
            "Indoor freq-limit state 1: 0x%02X  [Hypothesis: 8 flags]", buf(d + 5, 1):uint()))
    end
    if n >= 7 then
        body_tree:add(buf(d + 6, 1), string.format(
            "Indoor freq-limit state 2: 0x%02X  [Hypothesis: 8 flags]", buf(d + 6, 1):uint()))
    end
    if n >= 8 then
        body_tree:add(buf(d + 7, 1), string.format(
            "Indoor freq-limit state 3: 0x%02X  [Hypothesis: 8 flags]", buf(d + 7, 1):uint()))
    end

    -- body[12..13]: indoor load state bytes 1-2
    if n >= 9 then
        body_tree:add(buf(d + 8, 1), string.format(
            "Indoor load state 1: 0x%02X  [Hypothesis: 8 flags]", buf(d + 8, 1):uint()))
    end
    if n >= 10 then
        body_tree:add(buf(d + 9, 1), string.format(
            "Indoor load state 2: 0x%02X  [Hypothesis: 8 flags]", buf(d + 9, 1):uint()))
    end

    -- body[14]: indoor E2 param version
    if n >= 11 then
        body_tree:add(buf(d + 10, 1), string.format(
            "Indoor E2 param version: %d  [Hypothesis]", buf(d + 10, 1):uint()))
    end

    -- body[15..19]: smart-eye child detection fields
    if n >= 12 then
        body_tree:add(buf(d + 11, 1), string.format(
            "Child state: %d  [Hypothesis: smart-eye occupancy]", buf(d + 11, 1):uint()))
    end
    if n >= 13 then
        body_tree:add(buf(d + 12, 1), string.format(
            "Child count: %d  [Hypothesis]", buf(d + 12, 1):uint()))
    end
    if n >= 16 then
        body_tree:add(buf(d + 13, 4), string.format(
            "Child angles/distances: %d / %d / %d / %d  [Hypothesis]",
            buf(d + 13, 1):uint(), buf(d + 14, 1):uint(),
            buf(d + 15, 1):uint(), 0))  -- childDistance2 is hardcoded 0x00
    end
end


local function decode_c1_group3(body_tree, buf, body_off, body_len)
    -- Group 3 "Outdoor Device Params"
    -- Source: mill1000/midea-msmart (see midea-msmart-mill1000.md, Finding 11)
    -- Note: query page 0x43 echoes body[3]=0x03, not 0x43 — dispatch via body[3]&0x0F=3
    -- All fields: Hypothesis.

    local d = body_off + 4
    local n = body_len - 4

    -- body[4..9]: outdoor device state bytes 1-6 (8-bit packed each)
    for i = 0, 5 do
        if n >= (i + 1) then
            body_tree:add(buf(d + i, 1), string.format(
                "Outdoor device state %d: 0x%02X  [Hypothesis: 8 flags]", i + 1, buf(d + i, 1):uint()))
        end
    end

    -- body[10]: outdoor DC fan actual speed (raw × 8 = RPM)
    if n >= 7 then
        local raw = buf(d + 6, 1):uint()
        body_tree:add(buf(d + 6, 1), string.format(
            "Outdoor DC fan speed: %d RPM (raw %d ×8)  [Hypothesis]", raw * 8, raw))
    end

    -- body[11]: electronic expansion valve position (raw × 8 = steps)
    if n >= 8 then
        local raw = buf(d + 7, 1):uint()
        body_tree:add(buf(d + 7, 1), string.format(
            "EEV position: %d steps (raw %d ×8)  [Hypothesis]", raw * 8, raw))
    end

    -- body[12]: outdoor return air (suction) temperature (raw)
    if n >= 9 then
        body_tree:add(buf(d + 8, 1), string.format(
            "Outdoor return air temp: %d (raw)  [Hypothesis]", buf(d + 8, 1):uint()))
    end

    -- body[13]: outdoor DC bus voltage (raw)
    if n >= 10 then
        body_tree:add(buf(d + 9, 1), string.format(
            "Outdoor DC bus voltage: %d (raw)  [Hypothesis]", buf(d + 9, 1):uint()))
    end

    -- body[14]: IPM module temperature (raw °C)
    if n >= 11 then
        body_tree:add(buf(d + 10, 1), string.format(
            "IPM module temp: %d °C  [Hypothesis]", buf(d + 10, 1):uint()))
    end

    -- body[15]: outdoor load state (raw)
    if n >= 12 then
        body_tree:add(buf(d + 11, 1), string.format(
            "Outdoor load state: 0x%02X  [Hypothesis]", buf(d + 11, 1):uint()))
    end

    -- body[16]: outdoor target compressor frequency (raw)
    if n >= 13 then
        body_tree:add(buf(d + 12, 1), string.format(
            "Outdoor target compressor freq: %d  [Hypothesis]", buf(d + 12, 1):uint()))
    end
end


local function decode_c1_group4(body_tree, buf, body_off, body_len)
    -- Group 4 "Power Consumption"
    -- Source: mill1000/midea-msmart Finding 11 (see midea-msmart-mill1000.md); confirmed Sessions 1 + 8, UART bus.
    --
    -- All energy fields use 4-byte "BCD" encoding where each byte's nibbles are treated
    -- as decimal digits (incl. nibbles A-F = 10-15, i.e. not strict BCD).
    -- Formula: bcd[N]*10000 + bcd[N+1]*100 + bcd[N+2] + bcd[N+3]/100  = kWh
    --
    -- curRealTimePower uses 3 bytes:
    -- bcd[16] + bcd[17]/100 + bcd[18]/10000  = kW
    --
    -- Confirmed values:
    --   Session 1 (compressor off): totalPowerConsume=111.45 kWh, curRealTimePower=5-11 W
    --   Session 8 (80 Hz heat):     totalPowerConsume=113.81 kWh, curRealTimePower=381.4 W

    local d = body_off + 4
    local n = body_len - 4

    local function bcd(byte_val)
        return bit.band(bit.rshift(byte_val, 4), 0x0F) * 10 + bit.band(byte_val, 0x0F)
    end

    local function bcd_energy_kwh(off)
        local b0 = buf(off,   1):uint()
        local b1 = buf(off+1, 1):uint()
        local b2 = buf(off+2, 1):uint()
        local b3 = buf(off+3, 1):uint()
        return bcd(b0)*10000 + bcd(b1)*100 + bcd(b2) + bcd(b3)/100.0
    end

    -- body[4..7]: totalPowerConsume — cumulative lifetime energy
    if n >= 4 then
        body_tree:add(buf(d + 0, 4), string.format(
            "totalPowerConsume: %.2f kWh  [ConfirmedS1/S8]", bcd_energy_kwh(d+0)))
    end

    -- body[8..11]: totalRunPower — zeros in all own captures (firmware may not populate)
    if n >= 8 then
        body_tree:add(buf(d + 4, 4), string.format(
            "totalRunPower: %.2f kWh  [Hypothesis]", bcd_energy_kwh(d+4)))
    end

    -- body[12..15]: curRunPower — zeros in all own captures
    if n >= 12 then
        body_tree:add(buf(d + 8, 4), string.format(
            "curRunPower: %.2f kWh  [Hypothesis]", bcd_energy_kwh(d+8)))
    end

    -- body[16..18]: curRealTimePower — instantaneous draw in kW
    if n >= 15 then
        local b16 = buf(d+12,1):uint()
        local b17 = buf(d+13,1):uint()
        local b18 = buf(d+14,1):uint()
        local kw = bcd(b16) + bcd(b17)/100.0 + bcd(b18)/10000.0
        body_tree:add(buf(d + 12, 3), string.format(
            "curRealTimePower: %.4f kW = %.1f W  [ConfirmedS8]", kw, kw * 1000.0))
    end
end


local function decode_c1_group5(body_tree, buf, body_off, body_len)
    -- Group 5 "Extended Params"
    -- Source: mill1000/midea-msmart (see midea-msmart-mill1000.md, Finding 11)
    -- All fields: Hypothesis.

    local d = body_off + 4
    local n = body_len - 4

    -- body[4]: current humidity (%)
    if n >= 1 then
        body_tree:add(buf(d + 0, 1), string.format(
            "Humidity: %d %%  [Hypothesis]", buf(d + 0, 1):uint()))
    end

    -- body[5]: compensated temp setpoint (Tsc)
    if n >= 2 then
        body_tree:add(buf(d + 1, 1), string.format(
            "Compensated temp setpoint (Tsc): %d  [Hypothesis]", buf(d + 1, 1):uint()))
    end

    -- body[6..7]: indoor fan runtime (16-bit LE)
    if n >= 4 then
        local val = buf(d + 2, 1):uint() + buf(d + 3, 1):uint() * 256
        body_tree:add(buf(d + 2, 2), string.format(
            "Indoor fan runtime: %d (16-bit LE)  [Hypothesis]", val))
    end

    -- body[8]: outdoor fan target speed (raw × 8 = RPM)
    if n >= 5 then
        local raw = buf(d + 4, 1):uint()
        body_tree:add(buf(d + 4, 1), string.format(
            "Outdoor fan target speed: %d RPM (raw %d ×8)  [Hypothesis]", raw * 8, raw))
    end

    -- body[9]: EEV target angle (raw × 8 = steps)
    if n >= 6 then
        local raw = buf(d + 5, 1):uint()
        body_tree:add(buf(d + 5, 1), string.format(
            "EEV target angle: %d steps (raw %d ×8)  [Hypothesis]", raw * 8, raw))
    end

    -- body[10]: defrost step
    if n >= 7 then
        local step = buf(d + 6, 1):uint()
        local step_str = ({"none","start","in-progress","ending"})[step + 1] or "unknown"
        body_tree:add(buf(d + 6, 1), string.format(
            "Defrost step: %d (%s)  [Hypothesis]", step, step_str))
    end

    -- body[11..12]: outdoor state 7-8 (reserved)
    if n >= 8 then
        body_tree:add(buf(d + 7, 1), string.format(
            "Outdoor state 7 (reserved): 0x%02X  [Hypothesis]", buf(d + 7, 1):uint()))
    end
    if n >= 9 then
        body_tree:add(buf(d + 8, 1), string.format(
            "Outdoor state 8 (reserved): 0x%02X  [Hypothesis]", buf(d + 8, 1):uint()))
    end

    -- body[13]: compressor current run time (raw × 64 seconds)
    if n >= 10 then
        local raw = buf(d + 9, 1):uint()
        body_tree:add(buf(d + 9, 1), string.format(
            "Compressor run time: %d s (raw %d ×64)  [Hypothesis]", raw * 64, raw))
    end

    -- body[14..15]: compressor cumulative run time (16-bit LE, hours)
    if n >= 12 then
        local val = buf(d + 10, 1):uint() + buf(d + 11, 1):uint() * 256
        body_tree:add(buf(d + 10, 2), string.format(
            "Compressor cumulative run time: %d h (16-bit LE)  [Hypothesis]", val))
    end

    -- body[16]: freq-limit type 2
    if n >= 13 then
        body_tree:add(buf(d + 12, 1), string.format(
            "Freq-limit type 2: %d  [Hypothesis]", buf(d + 12, 1):uint()))
    end

    -- body[17]: max bus voltage (raw + 60 V)
    if n >= 14 then
        body_tree:add(buf(d + 13, 1), string.format(
            "Max bus voltage: %d V (raw %d +60)  [Hypothesis]",
            buf(d + 13, 1):uint() + 60, buf(d + 13, 1):uint()))
    end

    -- body[18]: min bus voltage (raw + 60 V)
    if n >= 15 then
        body_tree:add(buf(d + 14, 1), string.format(
            "Min bus voltage: %d V (raw %d +60)  [Hypothesis]",
            buf(d + 14, 1):uint() + 60, buf(d + 14, 1):uint()))
    end
end


local function decode_c1_extstate_01(body_tree, buf, body_off, body_len)
    -- 0xC1 extended state sub-page 0x01 — sensor temperatures, fault flags, actuator positions
    -- Source: mill1000/midea-msmart (see midea-msmart-mill1000.md, Finding 8)
    -- NOT verified against own captures. All fields: Hypothesis.

    -- Helper: 16-bit LE × 0.01 °C, MSB ≥ 0x80 → negative
    local function t16(off)
        if body_len <= off + 1 then return nil end
        local raw = buf(body_off + off, 2):le_uint()
        local neg = buf(body_off + off + 1, 1):uint() >= 0x80
        return (neg and -(0x10000 - raw) or raw) * 0.01
    end

    body_tree:add(buf(body_off, 2), "Extended State Sub-page: 0x01 (Hypothesis — not in own captures)")

    -- body[2]: device status flags
    if body_len > 2 then
        body_tree:add(buf(body_off + 2, 1), string.format(
            "Device status 1: 0x%02X  b7=newWindMode b6=smartClean b5=sterilize  [Hypothesis]",
            buf(body_off + 2, 1):uint()))
    end
    -- body[3]: device status flags 2
    if body_len > 3 then
        body_tree:add(buf(body_off + 3, 1), string.format(
            "Device status 2: 0x%02X  b5=AC-filter-dirty b4=elecHeat  [Hypothesis]",
            buf(body_off + 3, 1):uint()))
    end
    -- body[4]: run status flags
    if body_len > 4 then
        body_tree:add(buf(body_off + 4, 1), string.format(
            "Run status: 0x%02X  b1=runCurrentStatus b0=deviceCurrentRunStatus  [Hypothesis]",
            buf(body_off + 4, 1):uint()))
    end
    -- body[6]: current run mode
    if body_len > 6 then
        local mode = bit.band(buf(body_off + 6, 1):uint(), 0x0F)
        body_tree:add(buf(body_off + 6, 1), string.format(
            "Current run mode: %d (%s)  [Hypothesis]", mode, getSerialModeString(mode)))
    end

    if body_len > 10 then
        local v = t16(9)
        if v then body_tree:add(buf(body_off + 9,  2), string.format("T1 indoor coil (evap): %.2f °C  [Hypothesis: 16-bit LE ×0.01]", v)) end
    end
    if body_len > 12 then
        local v = t16(11)
        if v then body_tree:add(buf(body_off + 11, 2), string.format("T2: %.2f °C  [Hypothesis: 16-bit LE ×0.01]", v)) end
    end
    if body_len > 14 then
        local v = t16(13)
        if v then body_tree:add(buf(body_off + 13, 2), string.format("T3 outdoor coil (cond): %.2f °C  [Hypothesis: 16-bit LE ×0.01]", v)) end
    end
    if body_len > 16 then
        local v = t16(15)
        if v then body_tree:add(buf(body_off + 15, 2), string.format("T4 outdoor ambient: %.2f °C  [Hypothesis: 16-bit LE ×0.01]", v)) end
    end
    if body_len > 20 then
        body_tree:add(buf(body_off + 20, 1), string.format(
            "Compressor current: %.2f A  [Hypothesis: raw×0.25]",
            buf(body_off + 20, 1):uint() * 0.25))
    end
    if body_len > 21 then
        body_tree:add(buf(body_off + 21, 1), string.format(
            "Outdoor total current: %.2f A  [Hypothesis: raw×0.25]",
            buf(body_off + 21, 1):uint() * 0.25))
    end
    if body_len > 22 then
        body_tree:add(buf(body_off + 22, 1), string.format(
            "Outdoor supply voltage (raw AD): 0x%02X  [Hypothesis]",
            buf(body_off + 22, 1):uint()))
    end
    -- body[17]: Tp discharge pipe temp
    if body_len > 17 then
        body_tree:add(buf(body_off + 17, 1), string.format(
            "Tp discharge temp (raw AD): %d  [Hypothesis]", buf(body_off + 17, 1):uint()))
    end
    -- body[18-19]: compressor actual/target frequency
    if body_len > 18 then
        body_tree:add(buf(body_off + 18, 1), string.format(
            "Compressor actual freq: %d Hz  [Hypothesis]", buf(body_off + 18, 1):uint()))
    end
    if body_len > 19 then
        body_tree:add(buf(body_off + 19, 1), string.format(
            "Compressor target freq: %d Hz  [Hypothesis]", buf(body_off + 19, 1):uint()))
    end
    -- body[23]: indoor operating mode
    if body_len > 23 then
        body_tree:add(buf(body_off + 23, 1), string.format(
            "Indoor operating mode: %d  [Hypothesis]", buf(body_off + 23, 1):uint()))
    end
    if body_len > 26 then
        body_tree:add(buf(body_off + 26, 1), string.format(
            "Indoor fault byte 1: 0x%02X  b0=env-sensor b1=pipe-sensor b2=E2 b3=DC-fan-stall b4=indoor-outdoor-comm b5=smart-eye b6=display-E2 b7=RF-module  [Hypothesis]",
            buf(body_off + 26, 1):uint()))
    end
    -- body[27-28]: indoor fault bytes 2-3
    if body_len > 27 then
        body_tree:add(buf(body_off + 27, 1), string.format(
            "Indoor fault byte 2: 0x%02X  [Hypothesis]", buf(body_off + 27, 1):uint()))
    end
    if body_len > 28 then
        body_tree:add(buf(body_off + 28, 1), string.format(
            "Indoor fault byte 3: 0x%02X  [Hypothesis]", buf(body_off + 28, 1):uint()))
    end
    -- body[29-30]: freq-limit state bytes
    if body_len > 29 then
        body_tree:add(buf(body_off + 29, 1), string.format(
            "Freq-limit state 1: 0x%02X  [Hypothesis]", buf(body_off + 29, 1):uint()))
    end
    if body_len > 30 then
        body_tree:add(buf(body_off + 30, 1), string.format(
            "Freq-limit state 2: 0x%02X  [Hypothesis]", buf(body_off + 30, 1):uint()))
    end
    if body_len > 32 then
        body_tree:add(buf(body_off + 32, 1), string.format(
            "Load state: 0x%02X  b0=defrost b1=aux-heat b6=indoor-fan-run b7=purifier  [Hypothesis]",
            buf(body_off + 32, 1):uint()))
    end
    -- body[35-39]: outdoor fault bytes 1-5
    if body_len > 35 then
        body_tree:add(buf(body_off + 35, 1), string.format(
            "Outdoor fault 1: 0x%02X  b0=E2/E51 b1=T3/E52 b2=T4/E53 b3=discharge/E54  [Hypothesis]",
            buf(body_off + 35, 1):uint()))
    end
    -- body[40]: outdoor AC fan state
    if body_len > 40 then
        body_tree:add(buf(body_off + 40, 1), string.format(
            "Outdoor AC fan: 0x%02X  b3=4-way-valve  [Hypothesis]",
            buf(body_off + 40, 1):uint()))
    end
    if body_len > 41 then
        body_tree:add(buf(body_off + 41, 1), string.format(
            "Outdoor DC fan speed: %d RPM  [Hypothesis: raw×8]",
            buf(body_off + 41, 1):uint() * 8))
    end
    if body_len > 42 then
        body_tree:add(buf(body_off + 42, 1), string.format(
            "EEV position: %d steps  [Hypothesis: raw×8]",
            buf(body_off + 42, 1):uint() * 8))
    end
    -- body[43]: outdoor suction temp (raw AD)
    if body_len > 43 then
        body_tree:add(buf(body_off + 43, 1), string.format(
            "Outdoor suction temp (raw AD): %d  [Hypothesis]", buf(body_off + 43, 1):uint()))
    end
    -- body[44]: outdoor DC bus voltage (raw AD)
    if body_len > 44 then
        body_tree:add(buf(body_off + 44, 1), string.format(
            "Outdoor DC bus voltage (raw AD): %d  [Hypothesis]", buf(body_off + 44, 1):uint()))
    end
    -- body[45]: IPM module temp
    if body_len > 45 then
        body_tree:add(buf(body_off + 45, 1), string.format(
            "IPM module temp: %d  [Hypothesis: raw, may be AD not °C]", buf(body_off + 45, 1):uint()))
    end
    -- body[53-54]: dry/heat cleanup timer (16-bit LE)
    if body_len > 54 then
        body_tree:add(buf(body_off + 53, 2), string.format(
            "Dry/heat cleanup timer: %d min  [Hypothesis: 16-bit LE]",
            buf(body_off + 53, 2):le_uint()))
    end
    -- body[55-56]: CO2/TVOC (16-bit LE)
    if body_len > 56 then
        body_tree:add(buf(body_off + 55, 2), string.format(
            "CO2/TVOC: %d  [Hypothesis: 16-bit LE]", buf(body_off + 55, 2):le_uint()))
    end
    -- body[57-58]: dust/PM2.5 (16-bit LE)
    if body_len > 58 then
        body_tree:add(buf(body_off + 57, 2), string.format(
            "Dust/PM2.5: %d  [Hypothesis: 16-bit LE]", buf(body_off + 57, 2):le_uint()))
    end
    -- body[59]: mainboard humidity
    if body_len > 59 then
        body_tree:add(buf(body_off + 59, 1), string.format(
            "Mainboard humidity: %d %%  [Hypothesis]", buf(body_off + 59, 1):uint()))
    end
    if body_len > 77 then
        body_tree:add(buf(body_off + 77, 1), string.format(
            "Error code: %d  [Hypothesis]", buf(body_off + 77, 1):uint()))
    end
    if body_len > 1 then
        body_tree:add(buf(body_off + 1, body_len - 1),
            "Full payload: " .. tostring(buf(body_off + 1, body_len - 1):bytes()))
    end
end


local function decode_c1_extstate_02(body_tree, buf, body_off, body_len)
    -- 0xC1 extended state sub-page 0x02 — status flags, timers, power, vane angles, compressor
    -- Source: mill1000/midea-msmart (see midea-msmart-mill1000.md, Finding 8)
    -- NOT verified against own captures. All fields: Hypothesis.

    body_tree:add(buf(body_off, 2), "Extended State Sub-page: 0x02 (Hypothesis — not in own captures)")

    if body_len > 3 then
        body_tree:add(buf(body_off + 2, 2), string.format(
            "On-timer: %d min  [Hypothesis: 16-bit LE]",
            buf(body_off + 2, 2):le_uint()))
    end
    if body_len > 5 then
        body_tree:add(buf(body_off + 4, 2), string.format(
            "Off-timer: %d min  [Hypothesis: 16-bit LE]",
            buf(body_off + 4, 2):le_uint()))
    end
    if body_len > 6 then
        body_tree:add(buf(body_off + 6, 1), string.format(
            "Status flags A: 0x%02X  b7=body-sense b6=energy-save b5=strong b0=ECO  [Hypothesis]",
            buf(body_off + 6, 1):uint()))
    end
    if body_len > 7 then
        body_tree:add(buf(body_off + 7, 1), string.format(
            "Status flags B: 0x%02X  b7=dust b6=aux-heat-actual b3=smart-eye b0=night-light  [Hypothesis]",
            buf(body_off + 7, 1):uint()))
    end
    if body_len > 8 then
        body_tree:add(buf(body_off + 8, 1), string.format(
            "Status flags C: 0x%02X  b3=display-on/off b2=self-clean b1=no-direct-wind  [Hypothesis]",
            buf(body_off + 8, 1):uint()))
    end
    -- body[9-10]: vane swing states
    if body_len > 9 then
        body_tree:add(buf(body_off + 9, 1), string.format(
            "Vane swing 1: 0x%02X  [Hypothesis: UD/LR swing bits]", buf(body_off + 9, 1):uint()))
    end
    if body_len > 10 then
        body_tree:add(buf(body_off + 10, 1), string.format(
            "Vane swing 2: 0x%02X  [Hypothesis: top vane swing bits]", buf(body_off + 10, 1):uint()))
    end
    if body_len > 11 then
        body_tree:add(buf(body_off + 11, 1), string.format(
            "Current humidity: %d %%  [Hypothesis]", buf(body_off + 11, 1):uint()))
    end
    if body_len > 12 then
        body_tree:add(buf(body_off + 12, 1), string.format(
            "Temp setpoint (compensated): %.1f °C  [Hypothesis: (raw-30)×0.5]",
            (buf(body_off + 12, 1):uint() - 30) * 0.5))
    end
    -- body[13-14]: indoor fan runtime (16-bit LE, minutes)
    if body_len > 14 then
        body_tree:add(buf(body_off + 13, 2), string.format(
            "Indoor fan runtime: %d min  [Hypothesis: 16-bit LE]",
            buf(body_off + 13, 2):le_uint()))
    end
    -- body[15]: outdoor fan target speed (×8 RPM)
    if body_len > 15 then
        body_tree:add(buf(body_off + 15, 1), string.format(
            "Outdoor fan target: %d RPM  [Hypothesis: raw×8]",
            buf(body_off + 15, 1):uint() * 8))
    end
    -- body[16]: EEV target position (×8 steps)
    if body_len > 16 then
        body_tree:add(buf(body_off + 16, 1), string.format(
            "EEV target: %d steps  [Hypothesis: raw×8]",
            buf(body_off + 16, 1):uint() * 8))
    end
    if body_len > 17 then
        local step = buf(body_off + 17, 1):uint()
        local step_str = ({"none","start","in-progress","ending"})[step + 1] or "unknown"
        body_tree:add(buf(body_off + 17, 1), string.format(
            "Defrost step: %d (%s)  [Hypothesis]", step, step_str))
    end
    if body_len > 20 then
        body_tree:add(buf(body_off + 20, 1), string.format(
            "Compressor current run time: %d s  [Hypothesis]",
            buf(body_off + 20, 1):uint()))
    end
    if body_len > 22 then
        body_tree:add(buf(body_off + 21, 2), string.format(
            "Compressor cumulative run time: %d h  [Hypothesis: 16-bit LE]",
            buf(body_off + 21, 2):le_uint()))
    end
    -- body[24-25]: max/min bus voltage (raw + 60 V)
    if body_len > 24 then
        body_tree:add(buf(body_off + 24, 1), string.format(
            "Max bus voltage (hist): %d V  [Hypothesis: raw+60]",
            buf(body_off + 24, 1):uint() + 60))
    end
    if body_len > 25 then
        body_tree:add(buf(body_off + 25, 1), string.format(
            "Min bus voltage (hist): %d V  [Hypothesis: raw+60]",
            buf(body_off + 25, 1):uint() + 60))
    end
    -- body[30]: compressor flux (×8)
    if body_len > 30 then
        body_tree:add(buf(body_off + 30, 1), string.format(
            "Compressor flux: %d  [Hypothesis: raw×8]",
            buf(body_off + 30, 1):uint() * 8))
    end
    if body_len > 48 then
        body_tree:add(buf(body_off + 47, 2), string.format(
            "Outdoor unit power: %d W  [Hypothesis: 16-bit LE]",
            buf(body_off + 47, 2):le_uint()))
    end
    if body_len > 53 then
        body_tree:add(buf(body_off + 53, 1), string.format(
            "UD vane current angle: %d %%  [Hypothesis]", buf(body_off + 53, 1):uint()))
    end
    if body_len > 56 then
        body_tree:add(buf(body_off + 56, 1), string.format(
            "LR vane current angle: %d %%  [Hypothesis]", buf(body_off + 56, 1):uint()))
    end
    if body_len > 57 then
        body_tree:add(buf(body_off + 57, 1), string.format(
            "Outdoor target compressor freq: %d  [Hypothesis]",
            buf(body_off + 57, 1):uint()))
    end
    -- body[58]: indoor target fan speed
    if body_len > 58 then
        body_tree:add(buf(body_off + 58, 1), string.format(
            "Indoor target fan speed: %d %%  [Hypothesis]", buf(body_off + 58, 1):uint()))
    end
    -- body[67]: second humidity sensor
    if body_len > 67 then
        body_tree:add(buf(body_off + 67, 1), string.format(
            "Second humidity sensor: %d %%  [Hypothesis]", buf(body_off + 67, 1):uint()))
    end
    -- body[68]: extended status flags
    if body_len > 68 then
        body_tree:add(buf(body_off + 68, 1), string.format(
            "Extended status: 0x%02X  b5=strong b4=sterilize b3=newWind b2=humidity b1=clean  [Hypothesis]",
            buf(body_off + 68, 1):uint()))
    end
    -- body[69]: wind-free and panel flags
    if body_len > 69 then
        body_tree:add(buf(body_off + 69, 1), string.format(
            "Wind-free/panel: 0x%02X  [Hypothesis]", buf(body_off + 69, 1):uint()))
    end
    if body_len > 1 then
        body_tree:add(buf(body_off + 1, body_len - 1),
            "Full payload: " .. tostring(buf(body_off + 1, body_len - 1):bytes()))
    end
end


local function decode_uart_c1(body_tree, buf, body_off, body_len)
    -- 0xC1 — dispatch by body[1]/body[2]/body[3]:
    --   body[1]=0x21, body[2]=0x01              → group dev-param page (incl. 0x44 power)
    --   body[1]=0x01                             → extended state sub-page 0x01
    --   body[1]=0x02                             → extended state sub-page 0x02
    --   other                                    → unknown, show raw

    local b1 = body_len >= 2 and buf(body_off + 1, 1):uint() or 0
    local b2 = body_len >= 3 and buf(body_off + 2, 1):uint() or 0
    local b3 = body_len >= 4 and buf(body_off + 3, 1):uint() or 0

    if b1 == 0x21 and b2 == 0x01 then
        -- Group dev-param page response (R/T bus, KJR wall controller)
        -- body[3] = page ID echoed from request; group = body[3] & 0x0F
        -- Source: mill1000/midea-msmart (see midea-msmart-mill1000.md, Finding 11)
        local group = bit.band(b3, 0x0F)
        body_tree:add(buf(body_off + 0, 4), string.format(
            "Command ID: 0xC1 (Group Page Response, page=0x%02X, group=%d)", b3, group))
        if group == 1 then
            decode_c1_group1(body_tree, buf, body_off, body_len)
        elseif group == 2 then
            decode_c1_group2(body_tree, buf, body_off, body_len)
        elseif group == 3 then
            decode_c1_group3(body_tree, buf, body_off, body_len)
        elseif group == 4 then
            decode_c1_group4(body_tree, buf, body_off, body_len)
        elseif group == 5 then
            decode_c1_group5(body_tree, buf, body_off, body_len)
        elseif body_len > 4 then
            body_tree:add(buf(body_off + 4, body_len - 4),
                "Page Data: " .. tostring(buf(body_off + 4, body_len - 4):bytes()))
        end

    elseif b1 == 0x01 then
        -- Extended state sub-page 0x01 — sensor temps, fault flags, actuator positions
        -- Source: mill1000/midea-msmart Finding 8; NOT verified in own captures (Hypothesis)
        body_tree:add(buf(body_off, 2), "Command ID: 0xC1 (Extended State, sub-page 0x01)")
        decode_c1_extstate_01(body_tree, buf, body_off, body_len)

    elseif b1 == 0x02 then
        -- Extended state sub-page 0x02 — timers, power, vanes, compressor
        -- Source: mill1000/midea-msmart Finding 8; NOT verified in own captures (Hypothesis)
        body_tree:add(buf(body_off, 2), "Command ID: 0xC1 (Extended State, sub-page 0x02)")
        decode_c1_extstate_02(body_tree, buf, body_off, body_len)

    else
        body_tree:add(buf(body_off + 0, 1), string.format(
            "Command ID: 0xC1 (unknown sub-type b1=0x%02X b3=0x%02X)", b1, b3))
        if body_len > 1 then
            body_tree:add(buf(body_off + 1, body_len - 1),
                "Payload: " .. tostring(buf(body_off + 1, body_len - 1):bytes()))
        end
    end
end


local function decode_uart_40_set(body_tree, buf, body_off, body_len)
    -- 0x40 Set Command
    body_tree:add(buf(body_off + 0, 1), "Command ID: 0x40 (Set Status)")

    -- body[1]: power, beep, resume, child sleep, timer mode, test2
    local b1 = buf(body_off + 1, 1):uint()
    body_tree:add(buf(body_off + 1, 1), string.format(
        "Power: %s, Beep: %s, Resume: %s, ChildSleep: %s, TimerMode: %s",
        bit.band(b1, 0x01) ~= 0 and "ON" or "OFF",
        bit.band(b1, 0x40) ~= 0 and "yes" or "no",
        bit.band(b1, 0x04) ~= 0 and "yes" or "no",
        bit.band(b1, 0x08) ~= 0 and "yes" or "no",
        bit.band(b1, 0x10) ~= 0 and "yes" or "no"))

    -- body[2]: mode + temp
    local b2 = buf(body_off + 2, 1):uint()
    local mode_bits = bit.rshift(bit.band(b2, 0xE0), 5)
    local temp_int = bit.band(b2, 0x0F) + 16
    local temp_half = bit.band(b2, 0x10) ~= 0
    body_tree:add(buf(body_off + 2, 1), string.format("Mode: %s, Temp: %.1f C",
        getSerialModeString(mode_bits), temp_int + (temp_half and 0.5 or 0)))

    -- body[3]: fan
    local fan = buf(body_off + 3, 1):uint()
    body_tree:add(buf(body_off + 3, 1), string.format("Fan: %d (%s)",
        fan, getSerialFanString(fan)))

    -- body[4-6]: timer fields
    if body_len > 6 then
        local b4 = buf(body_off + 4, 1):uint()
        local b5 = buf(body_off + 5, 1):uint()
        local b6 = buf(body_off + 6, 1):uint()
        local on_en = bit.band(b4, 0x80) ~= 0
        local on_h = bit.band(bit.rshift(b4, 2), 0x1F)
        local on_m_hi = bit.band(b4, 0x03)
        local on_m_lo = bit.rshift(b6, 4)
        local off_en = bit.band(b5, 0x80) ~= 0
        local off_h = bit.band(bit.rshift(b5, 2), 0x1F)
        local off_m_hi = bit.band(b5, 0x03)
        local off_m_lo = bit.band(b6, 0x0F)
        body_tree:add(buf(body_off + 4, 3), string.format(
            "On-timer: %s (%dh%02dm), Off-timer: %s (%dh%02dm)",
            on_en and "ON" or "off", on_h, on_m_hi * 16 + on_m_lo,
            off_en and "ON" or "off", off_h, off_m_hi * 16 + off_m_lo))
    end

    -- body[7]: swing
    if body_len > 7 then
        local swing = bit.band(buf(body_off + 7, 1):uint(), 0x0F)
        body_tree:add(buf(body_off + 7, 1), string.format("Swing: %s",
            getSerialSwingString(swing)))
    end

    -- body[8]: cosy sleep, turbo(loc1), power saver, Follow Me
    if body_len > 8 then
        local b8 = buf(body_off + 8, 1):uint()
        body_tree:add(buf(body_off + 8, 1), string.format(
            "CosySleep: %d, Save: %s, LowFreqFan: %s, Turbo1: %s, PowerSaver: %s, FollowMe: %s",
            bit.band(b8, 0x03),
            bit.band(b8, 0x08) ~= 0 and "yes" or "no",
            bit.band(b8, 0x10) ~= 0 and "yes" or "no",
            bit.band(b8, 0x20) ~= 0 and "yes" or "no",
            bit.band(b8, 0x40) ~= 0 and "yes" or "no",
            bit.band(b8, 0x80) ~= 0 and "yes" or "no"))
    end

    -- body[9]: eco + other flags (SET uses bit 7 for ECO — correct for set direction!)
    if body_len > 9 then
        local b9 = buf(body_off + 9, 1):uint()
        body_tree:add(buf(body_off + 9, 1), string.format(
            "ECO(set): %s, WiseEye: %s, ExchAir: %s, DryClean: %s, PTC: %s, CleanUp: %s",
            bit.band(b9, 0x80) ~= 0 and "yes" or "no",
            bit.band(b9, 0x01) ~= 0 and "yes" or "no",
            bit.band(b9, 0x02) ~= 0 and "yes" or "no",
            bit.band(b9, 0x04) ~= 0 and "yes" or "no",
            bit.band(b9, 0x08) ~= 0 and "yes" or "no",
            bit.band(b9, 0x20) ~= 0 and "yes" or "no"))
    end

    -- body[10]: sleep, turbo
    if body_len > 10 then
        local b10 = buf(body_off + 10, 1):uint()
        body_tree:add(buf(body_off + 10, 1), string.format("Sleep: %s, Turbo: %s",
            bit.band(b10, 0x01) ~= 0 and "yes" or "no",
            bit.band(b10, 0x02) ~= 0 and "yes" or "no"))
    end

    -- body[18]: new temp field (extended range 12-43C)
    if body_len > 18 then
        local new_temp_raw = bit.band(buf(body_off + 18, 1):uint(), 0x1F)
        if new_temp_raw > 0 then
            body_tree:add(buf(body_off + 18, 1), string.format("New Temp (ext): %d C",
                new_temp_raw + 12))
        end
    end
end


local function decode_uart_41_query(body_tree, buf, body_off, body_len)
    -- 0x41 Query — sub-type determined by body[1] then body[2]:
    --
    --   body[1]=0x81 (standard query sub-command):
    --     body[2]=0x00, body[3]=0xFF  → Status query        → expects 0xC0 response
    --     body[2]=0x01, body[3]=page  → Group page query     → expects 0xC1 group page response
    --                                   pages: 0x41/0x42/0x43 observed on R/T bus
    --   body[1]=0x21:
    --     body[2]=0x01, body[3]=0x44  → Power usage query   → expects 0xC1 BCD response
    --     other body[2]               → Extended query (optCommand in body[4], see mill1000/midea-msmart)
    --   body[1]=0x61                  → Display toggle
    --
    -- body[22] (when body_len >= 23): R/T bus MSG_ID / sequence counter (extra byte vs UART path)

    if body_len < 4 then
        body_tree:add(buf(body_off, body_len), string.format(
            "Command: 0x41 (too short, %d bytes)", body_len))
        return
    end

    local sub  = buf(body_off + 1, 1):uint()
    local b2   = buf(body_off + 2, 1):uint()
    local b3   = buf(body_off + 3, 1):uint()

    -- Group page name table
    local group_page_names = {
        [0x40] = "Group 0 (Timing Info)",
        [0x41] = "Group 1 (Base Run Info)",
        [0x42] = "Group 2 (Indoor Device Params)",
        [0x43] = "Group 3 (Outdoor Device Params)",
        [0x44] = "Group 4 (Power Consumption)",
        [0x45] = "Group 5 (Extended Params)",
        [0x46] = "Group 6 (Diagnostics)",
        [0x4B] = "Group 11 (Wind Blade Control)",
    }

    -- body[0]: command ID
    body_tree:add(buf(body_off, 1), "body[0] = 0x41 (Query command)")

    if sub == 0x81 then
        body_tree:add(buf(body_off + 1, 1), "body[1] = 0x81 (Standard query sub-command)")
        if b2 == 0x00 then
            body_tree:add(buf(body_off + 2, 1), "body[2] = 0x00 (Status query)")
            body_tree:add(buf(body_off + 3, 1), string.format(
                "body[3] = 0x%02X (query param — expects 0xC0 response)", b3))
        elseif b2 == 0x01 then
            local group = bit.band(b3, 0x0F)
            local page_name = group_page_names[b3] or string.format("Group %d", group)
            body_tree:add(buf(body_off + 2, 1), "body[2] = 0x01 (Group page query)")
            body_tree:add(buf(body_off + 3, 1), string.format(
                "body[3] = 0x%02X → group = body[3] & 0x0F = %d → %s",
                b3, group, page_name))
        else
            body_tree:add(buf(body_off + 2, 1), string.format(
                "body[2] = 0x%02X (unknown query type)", b2))
            body_tree:add(buf(body_off + 3, 1), string.format(
                "body[3] = 0x%02X", b3))
        end
    elseif sub == 0x21 or bit.band(sub, 0x3F) == 0x21 then
        local buzzer = bit.band(sub, 0x40) ~= 0
        body_tree:add(buf(body_off + 1, 1), string.format(
            "body[1] = 0x%02X (Dev-param query, buzzer=%s)", sub, buzzer and "ON" or "off"))
        if b2 == 0x01 then
            local group = bit.band(b3, 0x0F)
            local page_name = group_page_names[b3] or string.format("Group %d", group)
            body_tree:add(buf(body_off + 2, 1), "body[2] = 0x01 (Group page query)")
            body_tree:add(buf(body_off + 3, 1), string.format(
                "body[3] = 0x%02X → group = body[3] & 0x0F = %d → %s",
                b3, group, page_name))
        else
            local OPT_COMMAND_NAMES = {
                [0x00] = "Sync/Normal Extended",
                [0x01] = "Follow Me Temperature",
                [0x02] = "Special Function Key",
                [0x03] = "Query Extended State",
                [0x04] = "Installation Position",
                [0x05] = "Engineering/Test Mode",
                [0x06] = "Max Freq Limit",
            }
            local opt = body_len >= 5 and buf(body_off + 4, 1):uint() or 0
            local opt_name = OPT_COMMAND_NAMES[opt] or string.format("Unknown(0x%02X)", opt)
            body_tree:add(buf(body_off + 2, 1), string.format(
                "body[2] = 0x%02X (extended query)", b2))
            body_tree:add(buf(body_off + 3, 1), string.format(
                "body[3] = 0x%02X", b3))
            if body_len >= 5 then
                body_tree:add(buf(body_off + 4, 1), string.format(
                    "body[4] = 0x%02X (optCommand: %s)", opt, opt_name))
            end
            -- Follow Me temperature: optCommand=0x01, body[5] = T*2+50
            if opt == 0x01 and body_len >= 6 then
                local fm_raw = buf(body_off + 5, 1):uint()
                body_tree:add(buf(body_off + 5, 1), string.format(
                    "body[5] = 0x%02X (Follow Me temp: %.1f °C)", fm_raw, (fm_raw - 50) / 2.0))
            end
            -- Extended state query: optCommand=0x03, body[7] = queryStat
            if opt == 0x03 and body_len >= 8 then
                local qs = buf(body_off + 7, 1):uint()
                local qs_names = {[0x00]="Invalid", [0x01]="Exit query", [0x02]="Extended state", [0x03]="Outdoor query"}
                body_tree:add(buf(body_off + 7, 1), string.format(
                    "body[7] = 0x%02X (queryStat: %s)", qs, qs_names[qs] or "unknown"))
            end
        end
    elseif sub == 0x61 then
        body_tree:add(buf(body_off + 1, 1), "body[1] = 0x61 (Display toggle)")
    else
        body_tree:add(buf(body_off + 1, 1), string.format(
            "body[1] = 0x%02X (unknown sub-command)", sub))
    end

    -- body[4..19]: padding (all zero in observed queries)
    -- body[20]: random byte, body[21]: CRC-8
    if body_len >= 21 then
        body_tree:add(buf(body_off + 20, 1), string.format(
            "body[20] = 0x%02X (random)", buf(body_off + 20, 1):uint()))
    end
    if body_len >= 22 then
        body_tree:add(buf(body_off + 21, 1), string.format(
            "body[21] = 0x%02X (CRC-8)", buf(body_off + 21, 1):uint()))
    end

    -- R/T bus adds an extra MSG_ID byte at body[22] (body_len=23 vs UART body_len=22)
    if body_len >= 23 then
        body_tree:add(buf(body_off + 22, 1), string.format(
            "body[22] = 0x%02X (Msg ID, R/T bus only)", buf(body_off + 22, 1):uint()))
    end
end


local function decode_uart_93(body_tree, buf, body_off, body_len)
    -- 0x93 — Extension-board / KJR wall-controller status command.
    -- Observed on R/T bus (HA/HB, bidirectionalExtensionBoard) in Session 1.
    -- The same command ID appears in both request (0xAA, msg_type=0x03 or 0x02)
    -- and response (0x55, msg_type=0x03 or 0x02) direction.
    --
    -- Request body[1..3] variants observed:
    --   0x00 0x80 0x84  (msg_type=0x03 — periodic poll)
    --   0x80 0x80 0x84  (msg_type=0x02 — set/ack)
    --   0x80 0x80 0x04  (msg_type=0x02)
    --   0x00 0x80 0x90  (msg_type=0x03)
    --   0x00 0x80 0x04  (msg_type=0x03)
    -- Response body contains ~26 bytes of status data; field meanings unknown.
    -- [Hypothesis — single session, no cross-reference for 0x93 field layout]

    local b1 = body_len >= 2 and buf(body_off + 1, 1):uint() or 0
    local b2 = body_len >= 3 and buf(body_off + 2, 1):uint() or 0
    local b3 = body_len >= 4 and buf(body_off + 3, 1):uint() or 0

    -- Direction heuristic: request=23 bytes, response=30 bytes
    local dir = "?"
    if body_len == 23 then dir = "Request"
    elseif body_len == 30 then dir = "Response" end

    body_tree:add(buf(body_off, 1), string.format(
        "Command ID: 0x93 (Ext Status — KJR/R/T bus, %s, %d bytes)", dir, body_len))

    if dir == "Request" then
        -- Request: body[1] bit7 may indicate type, body[2]=0x80 fixed, body[3] variant
        body_tree:add(buf(body_off + 1, 1), string.format(
            "body[1] = 0x%02X (bit7=%d — type indicator?)  [Hypothesis]",
            b1, bit.band(bit.rshift(b1, 7), 1)))
        body_tree:add(buf(body_off + 2, 1), string.format(
            "body[2] = 0x%02X%s", b2, b2 == 0x80 and " (fixed)" or ""))
        body_tree:add(buf(body_off + 3, 1), string.format(
            "body[3] = 0x%02X (variant: %s)  [Hypothesis]", b3,
            b3 == 0x84 and "status" or b3 == 0x90 and "config" or b3 == 0x04 and "ack" or "unknown"))
        if body_len > 22 then
            body_tree:add(buf(body_off + 22, 1), string.format(
                "body[22] = 0x%02X (MSG_ID)  [Hypothesis]", buf(body_off + 22, 1):uint()))
        end
    elseif dir == "Response" then
        -- Response: body[3] = status code
        body_tree:add(buf(body_off + 1, 3), string.format(
            "Params: 0x%02X 0x%02X 0x%02X (status=0x%02X)", b1, b2, b3, b3))
        -- body[24-27]: 4-zone status
        if body_len > 27 then
            body_tree:add(buf(body_off + 24, 4), string.format(
                "Zone status: 0x%02X 0x%02X 0x%02X 0x%02X (0x80=nominal?)  [Hypothesis]",
                buf(body_off + 24, 1):uint(), buf(body_off + 25, 1):uint(),
                buf(body_off + 26, 1):uint(), buf(body_off + 27, 1):uint()))
        end
    else
        body_tree:add(buf(body_off + 1, math.min(3, body_len - 1)), string.format(
            "Params: 0x%02X 0x%02X 0x%02X", b1, b2, b3))
    end

    if body_len > 4 then
        body_tree:add(buf(body_off + 4, body_len - 4),
            "Payload: " .. tostring(buf(body_off + 4, body_len - 4):bytes()))
    end
end


local function decode_uart_07_devid(body_tree, buf, body_off, body_len)
    -- 0x07 Device Identification (dispatched by msg_type=0x07)
    -- Short form: body = {0x00, 0xFA} — dongle requesting SN from mainboard
    -- Long form: body = 32-byte SN string (ASCII, or all 0xFF when not set)
    -- SN all-0xFF observed in Sessions 2 and 4.
    if body_len >= 2 and buf(body_off, 1):uint() == 0x00
            and buf(body_off + 1, 1):uint() == 0xFA then
        body_tree:add(buf(body_off, 2), "[Device ID 0x07] Sub-request: 00 FA  [Hypothesis: dongle requesting SN]")
    elseif body_len >= 1 then
        local sn_len = body_len
        local all_ff = true
        for i = 0, sn_len - 1 do
            if buf(body_off + i, 1):uint() ~= 0xFF then all_ff = false; break end
        end
        body_tree:add(buf(body_off, sn_len), string.format(
            "SN (%d bytes): %s%s",
            sn_len, tostring(buf(body_off, sn_len):bytes()),
            all_ff and "  [all 0xFF — SN not set]" or ""))
    end
end


local function decode_uart_racserial(body_tree, buf, body_off, body_len)
    -- 0x65 RAC Serial  (dispatched by msg_type=0x65, not body[0])
    -- body[0] is a serial sub-command, not a cmd_id.
    -- Observed at boot: body[0]=0x00, body[1]=0xAC (appliance type echo), rest zeros,
    -- CRC=0x00 (device sends null CRC on this boot-init frame — Hypothesis).
    if body_len >= 1 then
        local b0 = buf(body_off, 1):uint()
        local note = b0 == 0x00 and "  [boot-init null frame — Hypothesis]" or ""
        body_tree:add(buf(body_off, 1), string.format(
            "RAC Serial sub-cmd: 0x%02X%s", b0, note))
    end
    if body_len > 1 then
        body_tree:add(buf(body_off + 1, body_len - 1),
            "Payload: " .. tostring(buf(body_off + 1, body_len - 1):bytes()))
    end
end


local function decode_uart_netstatus(body_tree, buf, body_off, body_len, msg_type)
    -- 0x63 Network Status / 0x0D Network Init  (dispatched by msg_type, not body[0])
    local name = msg_type == 0x63 and "Network Status" or "Network Init"

    -- body[0]: connection status
    if body_len >= 1 then
        local b0 = buf(body_off, 1):uint()
        local conn_names = {[0x00]="Disconnected", [0x01]="Connected"}
        body_tree:add(buf(body_off, 1), string.format(
            "[%s] Connection: 0x%02X (%s)", name, b0, conn_names[b0] or "unknown"))
    end

    -- body[1]: WiFi state
    if body_len >= 2 then
        local b1 = buf(body_off + 1, 1):uint()
        local wifi_names = {[0]="Off", [1]="Connected", [3]="SoftAP"}
        body_tree:add(buf(body_off + 1, 1), string.format(
            "WiFi state: %d (%s)", b1, wifi_names[b1] or string.format("0x%02X", b1)))
    end

    -- body[2]: WiFi mode
    if body_len >= 3 then
        body_tree:add(buf(body_off + 2, 1), string.format(
            "WiFi mode: 0x%02X", buf(body_off + 2, 1):uint()))
    end

    -- body[3..6]: IP address (little-endian byte order — confirmed: 04.B3.A8.C0 = 192.168.179.4)
    if body_len >= 7 then
        body_tree:add(buf(body_off + 3, 4), string.format(
            "IP address: %d.%d.%d.%d",
            buf(body_off + 6, 1):uint(), buf(body_off + 5, 1):uint(),
            buf(body_off + 4, 1):uint(), buf(body_off + 3, 1):uint()))
    end

    -- body[8]: signal strength
    if body_len >= 9 then
        local sig = buf(body_off + 8, 1):uint()
        local sig_names = {[0]="Error", [1]="None", [2]="Fair", [3]="Good", [4]="Excellent", [7]="Auto"}
        body_tree:add(buf(body_off + 8, 1), string.format(
            "Signal strength: %d (%s)", sig, sig_names[sig] or "unknown"))
    end

    -- body[16]: connection detail
    if body_len >= 17 then
        local cd = buf(body_off + 16, 1):uint()
        local cd_names = {[0]="None", [1]="WiFi off + DHCP", [2]="Connected no IP", [3]="Fully connected"}
        body_tree:add(buf(body_off + 16, 1), string.format(
            "Connection detail: %d (%s)", cd, cd_names[cd] or "unknown"))
    end

    -- Raw payload for remaining analysis
    if body_len > 1 then
        body_tree:add(buf(body_off, body_len),
            "Raw payload: " .. tostring(buf(body_off, body_len):bytes()))
    end
end


local function decode_uart_a1_heartbeat(body_tree, buf, body_off, body_len)
    -- 0xA1 Mainboard heartbeat — cumulative energy + temperatures
    -- Source: mill1000/midea-msmart Finding 12 (see midea-msmart-mill1000.md)
    --
    -- Cross-validated against all 55 A1 frames across Sessions 1-9:
    --   energy[1..4] BCD kWh: exact match with C1 Group4 totalPowerConsume
    --     (S1: both = 111.45 kWh; S8: both = 113.81 kWh)
    --   T1/T4: physically consistent with session conditions across all sessions
    --   work_min[9..12]: always zero on Q11 — firmware does not populate this field
    --     (verified: 55 frames including Session 7 spanning 756 s)
    --   byte[18]: not a reliable fractional temp on Q11 — values jump randomly
    --     (0x00, 0x04, 0x94, 0x83 in same session with constant T1/T4)
    --
    -- BCD nibbles A-F are allowed (not strict decimal BCD) — same as C1 Group4.

    local function bcd(b) return math.floor(b / 16) * 10 + (b % 16) end
    local function bcd_kwh(o)
        if body_off + o + 3 >= buf:len() then return nil end
        return bcd(buf(body_off+o,1):uint())*10000
             + bcd(buf(body_off+o+1,1):uint())*100
             + bcd(buf(body_off+o+2,1):uint())
             + bcd(buf(body_off+o+3,1):uint())/100.0
    end

    body_tree:add(buf(body_off, 1), "Command ID: 0xA1 (Heartbeat — Cumulative Energy + Temps)")

    -- body[1..4]: totalPowerConsume — cumulative lifetime energy in kWh
    -- BCD: bcd[1]x10000 + bcd[2]x100 + bcd[3] + bcd[4]/100  kWh; nibbles A-F allowed
    -- [Confirmed: exact match with C1 Group4, Sessions 1 and 8]
    if body_len >= 5 then
        local kwh = bcd_kwh(1)
        if kwh then
            body_tree:add(buf(body_off+1, 4), string.format(
                "totalPowerConsume: %.2f kWh  [Confirmed — Finding 12]", kwh))
        end
    end

    -- body[5..8]: totalRunPower — defined in spec; always 0.00 on Q11
    if body_len >= 9 then
        local kwh = bcd_kwh(5)
        if kwh then
            body_tree:add(buf(body_off+5, 4), string.format(
                "totalRunPower: %.2f kWh  [Finding 12; always 0 on Q11]", kwh))
        end
    end

    -- body[9..12]: currentWorkTime — defined in spec; not implemented on Q11 (always 0)
    -- [9..10]=days 16-bit BE, [11]=hours, [12]=minutes
    -- Verified: 0 in all 55 captures including 756 s session
    if body_len >= 13 then
        local days  = buf(body_off+9,1):uint() * 256 + buf(body_off+10,1):uint()
        local hours = buf(body_off+11,1):uint()
        local mins  = buf(body_off+12,1):uint()
        if days == 0 and hours == 0 and mins == 0 then
            body_tree:add(buf(body_off+9, 4),
                "currentWorkTime: 0 (not implemented on Q11)  [Finding 12, Confirmed]")
        else
            body_tree:add(buf(body_off+9, 4), string.format(
                "currentWorkTime: %dd %02dh %02dm = %d min  [Finding 12]",
                days, hours, mins, days*1440 + hours*60 + mins))
        end
    end

    -- body[13]: T1 indoor temperature  (raw-50)/2 °C, skip 0x00/0xFF  [Confirmed]
    -- body[14]: T4 outdoor temperature (raw-50)/2 °C, skip 0x00/0xFF  [Confirmed]
    if body_len >= 14 then
        local r = buf(body_off+13,1):uint()
        if r ~= 0x00 and r ~= 0xFF then
            body_tree:add(buf(body_off+13,1), string.format(
                "T1 indoor: %.1f C (raw 0x%02X, (raw-50)/2)  [Confirmed — Finding 12]",
                (r-50)/2.0, r))
        else
            body_tree:add(buf(body_off+13,1), string.format(
                "T1 indoor: N/A (raw 0x%02X — sensor not ready)", r))
        end
    end
    if body_len >= 15 then
        local r = buf(body_off+14,1):uint()
        if r ~= 0x00 and r ~= 0xFF then
            body_tree:add(buf(body_off+14,1), string.format(
                "T4 outdoor: %.1f C (raw 0x%02X, (raw-50)/2)  [Confirmed — Finding 12]",
                (r-50)/2.0, r))
        else
            body_tree:add(buf(body_off+14,1), string.format(
                "T4 outdoor: N/A (raw 0x%02X — sensor not ready/absent)", r))
        end
    end

    -- body[15..16]: pm25Value 16-bit BE (µg/m3) — always 0 on Q11 (no sensor)  [Finding 12]
    if body_len >= 17 then
        local pm25 = buf(body_off+15,1):uint() * 256 + buf(body_off+16,1):uint()
        body_tree:add(buf(body_off+15,2), string.format(
            "pm25Value: %d ug/m3  [Finding 12; 0 on Q11 — no sensor]", pm25))
    end

    -- body[17]: curHum (%) — always 0 on Q11 (no humidity sensor)  [Finding 12]
    if body_len >= 18 then
        body_tree:add(buf(body_off+17,1), string.format(
            "curHum: %d%%  [Finding 12; 0 on Q11 — no sensor]",
            buf(body_off+17,1):uint()))
    end

    -- body[18]: Unknown on Q11 — spec assigns fractional temp nibbles but values
    -- are random on Q11 hardware (jump 0x00->0x94->0x83 with constant T1/T4)
    if body_len >= 19 then
        local b18 = buf(body_off+18,1):uint()
        body_tree:add(buf(body_off+18,1), string.format(
            "byte[18] = 0x%02X (lo=%d hi=%d)  [Unknown on Q11 — not reliable fractional temp]",
            b18, b18 % 16, math.floor(b18 / 16)))
    end

    -- body[19]: lightAdValue (raw ADC) — always 0 on Q11  [Finding 12]
    if body_len >= 20 then
        body_tree:add(buf(body_off+19,1), string.format(
            "lightAdValue: %d (raw ADC)  [Finding 12; 0 on Q11]",
            buf(body_off+19,1):uint()))
    end

    -- remaining bytes
    if body_len > 20 then
        body_tree:add(buf(body_off+20, body_len-20),
            "Tail: " .. tostring(buf(body_off+20, body_len-20):bytes()) .. "  [unknown]")
    end
end


local function decode_uart_heartbeat_subpage(body_tree, buf, body_off, body_len, cmd_id)
    -- 0xA2/A3/A5/A6 mainboard heartbeat sub-pages (msg_type=0x04, body[0]=Ax)
    -- These are mainboard→dongle pushes for cloud forwarding.
    -- A2/A3/A5/A6 are not decoded in mill1000/midea-msmart reference material (see midea-msmart-mill1000.md).
    local names = {
        [0xA2] = "Heartbeat A2 (Device Params — undecoded)",
        [0xA3] = "Heartbeat A3 (Device Params 2 — undecoded)",
        [0xA5] = "Heartbeat A5 (Outdoor Unit — undecoded)",
        [0xA6] = "Heartbeat A6 (Network Info — undecoded)",
    }
    local name = names[cmd_id] or string.format("Heartbeat 0x%02X (undecoded)", cmd_id)
    body_tree:add(buf(body_off, 1), string.format("Command ID: 0x%02X (%s)", cmd_id, name))
    if body_len > 1 then
        body_tree:add(buf(body_off + 1, body_len - 1),
            "Payload: " .. tostring(buf(body_off + 1, body_len - 1):bytes()))
    end
end


local function decode_uart_b0b1_tlv(body_tree, buf, body_off, body_len, cmd_id)
    -- 0xB0 TLV Set / 0xB1 TLV Response — property protocol (newer devices)
    -- body[0]: 0xB0 or 0xB1
    -- body[1]: N_props (number of properties)
    -- body[2..]: property entries, each = prop_id_lo(1) + prop_id_hi(1) + data_len(1) + value(N)

    local PROP_NAMES = {
        [0x0009] = "wind_swing_ud_angle", [0x000A] = "wind_swing_lr_angle",
        [0x0015] = "indoor_humidity",     [0x0018] = "no_wind_sense",
        [0x001A] = "buzzer",              [0x0021] = "cool_hot_sense",
        [0x0025] = "self_clean",          [0x0030] = "nobody_energy_save",
        [0x0032] = "wind_straight_avoid", [0x0039] = "smart_eye",
        [0x0042] = "prevent_straight_wind", [0x0043] = "gentle_wind_sense",
        [0x0049] = "prevent_super_cool",  [0x004B] = "fresh_air",
        [0x0090] = "cool_heat_amount",
        [0x0226] = "auto_prevent_straight_wind",
        [0x0225] = "temperature_ranges",
    }

    local n_props = body_len >= 2 and buf(body_off + 1, 1):uint() or 0

    -- Heuristic: query format has body_len ≈ 2 + N_props × 2 (just IDs, no data)
    -- Response format has body_len > 2 + N_props × 2 (IDs + data_len + value)
    local is_query = (body_len <= 2 + n_props * 2 + 1)
    local name
    if cmd_id == 0xB0 then name = "Property Set"
    elseif is_query then name = "Property Query"
    else name = "Property Response" end

    body_tree:add(buf(body_off, 1), string.format("Command ID: 0x%02X (%s)", cmd_id, name))
    if body_len >= 2 then
        body_tree:add(buf(body_off + 1, 1), string.format("N_props: %d", n_props))
    end
    if body_len <= 2 then return end

    local pos = body_off + 2
    local end_off = body_off + body_len
    local tlv_n = 0

    if is_query then
        -- Query format: just 2-byte property IDs, no data
        while pos + 1 < end_off and tlv_n < n_props do
            local id_lo = buf(pos, 1):uint()
            local id_hi = buf(pos + 1, 1):uint()
            local prop_id = id_lo + id_hi * 256
            local prop_name = PROP_NAMES[prop_id] or string.format("0x%04X", prop_id)
            body_tree:add(buf(pos, 2), string.format(
                "Query[%d] %s (id=0x%02X,0x%02X)", tlv_n, prop_name, id_lo, id_hi))
            pos = pos + 2
            tlv_n = tlv_n + 1
        end
        if pos < end_off then
            body_tree:add(buf(pos, end_off - pos),
                "Trailing: " .. tostring(buf(pos, end_off - pos):bytes()))
        end
    else
        -- Response/Set format: prop_id(2) + type(1) + data_len(1) + value(N)
        -- The 'type' byte (byte[2] of each entry) is present in responses;
        -- observed as 0x00 in all captures. Stride = 4 + data_len.
        while pos + 3 < end_off and tlv_n < 64 do
            local id_lo = buf(pos, 1):uint()
            local id_hi = buf(pos + 1, 1):uint()
            local prop_id = id_lo + id_hi * 256
            local ptype = buf(pos + 2, 1):uint()
            local dlen = buf(pos + 3, 1):uint()
            local prop_name = PROP_NAMES[prop_id] or string.format("0x%04X", prop_id)

            if pos + 4 + dlen > end_off then
                body_tree:add(buf(pos, end_off - pos), string.format(
                    "Prop[%d] %s: TRUNCATED (need %d, have %d)",
                    tlv_n, prop_name, dlen, end_off - pos - 4))
                break
            end

            local val_str
            if dlen == 0 then
                val_str = "(empty)"
            elseif dlen == 1 then
                val_str = string.format("0x%02X (%d)", buf(pos + 4, 1):uint(), buf(pos + 4, 1):uint())
            else
                val_str = tostring(buf(pos + 4, dlen):bytes())
            end

            body_tree:add(buf(pos, 4 + dlen), string.format(
                "Prop[%d] %s (id=0x%02X,0x%02X type=%d len=%d): %s",
                tlv_n, prop_name, id_lo, id_hi, ptype, dlen, val_str))
            pos = pos + 4 + dlen
            tlv_n = tlv_n + 1
        end
        if tlv_n == 0 and body_len > 2 then
            body_tree:add(buf(body_off + 2, body_len - 2),
                "Payload (no valid entries): " .. tostring(buf(body_off + 2, body_len - 2):bytes()))
        end
    end
end


local function decode_uart_b5_capabilities(body_tree, buf, body_off, body_len)
    -- 0xB5 Capabilities (TLV format, new protocol dataType=0x03)
    -- body[0]=0xB5, body[1]=record count, body[2..]=TLV records
    -- Each TLV: cap_id(1) + type(1) + data_len(1) + data(N)

    local CAP_NAMES = {
        [0x10] = "Fan Speed Control",  [0x12] = "Eco Mode",
        [0x13] = "Frost Protection",   [0x14] = "Operating Modes",
        [0x15] = "Swing/Fan Direction", [0x16] = "Power Calculation",
        [0x17] = "Nest/Filter Check",   [0x18] = "Self Clean",
        [0x19] = "Aux Electric Heat",   [0x1A] = "Turbo Mode",
        [0x1C] = "Comfort Sleep",       [0x1F] = "Humidity Control",
        [0x22] = "Unit Changeable",     [0x24] = "Light/LED Control",
        [0x25] = "Temperature Ranges",  [0x2C] = "Buzzer",
        [0x30] = "Body Sense",          [0x32] = "Strong Wind",
        [0x33] = "Soft Wind",           [0x39] = "Smart Eye",
        [0x42] = "No Wind Sense",       [0x43] = "Gentle Wind",
    }

    local CAP_MODE_VALUES = {
        [0] = "cool+dry+auto (no heat)", [1] = "all four modes",
        [2] = "heat+auto (no cool/dry)", [3] = "cool only",
    }
    local CAP_TURBO_VALUES = {
        [0] = "cool-only", [1] = "both", [2] = "neither", [3] = "heat-only",
    }

    body_tree:add(buf(body_off, 1), "Command ID: 0xB5 (Capabilities)")
    if body_len < 2 then return end

    local count = buf(body_off + 1, 1):uint()
    body_tree:add(buf(body_off + 1, 1), string.format("Record count: %d", count))

    local pos = body_off + 2
    local end_off = body_off + body_len
    local n = 0
    while pos + 2 < end_off and n < count do
        local cap_id = buf(pos, 1):uint()
        local cap_type = buf(pos + 1, 1):uint()
        local dlen = buf(pos + 2, 1):uint()
        local cap_name = CAP_NAMES[cap_id] or string.format("0x%02X", cap_id)
        local type_str = cap_type == 0x00 and "simple" or cap_type == 0x02 and "extended" or string.format("0x%02X", cap_type)

        if pos + 3 + dlen > end_off then
            body_tree:add(buf(pos, end_off - pos), string.format(
                "Cap[%d] %s: TRUNCATED", n, cap_name))
            break
        end

        local val_str = ""
        if dlen > 0 then
            local val = buf(pos + 3, 1):uint()
            val_str = string.format("val=%d", val)
            -- Decode known capability values
            if cap_id == 0x14 then
                val_str = val_str .. " (" .. (CAP_MODE_VALUES[val] or "?") .. ")"
            elseif cap_id == 0x1A then
                val_str = val_str .. " (" .. (CAP_TURBO_VALUES[val] or "?") .. ")"
            elseif cap_id == 0x10 then
                val_str = val_str .. (val ~= 1 and " (supported)" or " (NOT supported)")
            elseif cap_id == 0x22 then
                val_str = val_str .. (val == 0 and " (changeable)" or " (fixed)")
            elseif cap_id == 0x25 and dlen >= 6 then
                -- Temperature ranges: 6 bytes, each × 0.5 = °C
                local temps = {}
                for i = 0, 5 do
                    temps[i+1] = buf(pos + 3 + i, 1):uint() * 0.5
                end
                val_str = string.format("cool=%.0f-%.0f, auto=%.0f-%.0f, heat=%.0f-%.0f °C",
                    temps[1], temps[2], temps[3], temps[4], temps[5], temps[6])
            end
            if dlen > 1 and cap_id ~= 0x25 then
                val_str = val_str .. " raw=" .. tostring(buf(pos + 3, dlen):bytes())
            end
        end

        body_tree:add(buf(pos, 3 + dlen), string.format(
            "Cap[%d] %s (%s): %s", n, cap_name, type_str, val_str))
        pos = pos + 3 + dlen
        n = n + 1
    end
end


-- ══════════════════════════════════════════════════════════════════════════════
-- ── MAIN DISSECTOR ──────────────────────────────────────────────────────────
-- ══════════════════════════════════════════════════════════════════════════════

function hvac_shark_proto.dissector(udp_payload_buffer, pinfo, tree)
    pinfo.cols.protocol = hvac_shark_proto.name

    local subtree = tree:add(hvac_shark_proto, udp_payload_buffer(), "HVAC Shark Protocol Data")

    -- Check for the start sequence "HVAC_shark"
    if udp_payload_buffer(0, 10):string() ~= "HVAC_shark" then return end

    subtree:add(f.start_sequence, udp_payload_buffer(0, 10))

    local manufacturer = udp_payload_buffer(10, 1):uint()
    local bus_type = udp_payload_buffer(11, 1):uint()
    local version = udp_payload_buffer(12, 1):uint()

    if manufacturer == 1 then
        subtree:add(f.manufacturer, udp_payload_buffer(10, 1)):append_text(" (Midea)")
    else
        subtree:add(f.manufacturer, udp_payload_buffer(10, 1))
    end

    local BUS_TYPE_NAMES = {
        [0x00] = "XYE",
        [0x01] = "UART",
        [0x02] = "disp-mainboard_1",
        [0x03] = "r-t_1",
        [0x04] = "IR",
    }
    local bus_name = BUS_TYPE_NAMES[bus_type] or string.format("Unknown (0x%02X)", bus_type)
    subtree:add(f.bus_type, udp_payload_buffer(11, 1)):append_text(" (Bus = " .. bus_name .. ")")

    -- ── Header version & extended metadata ──────────────────────────────
    local data_offset = 13
    local channel_direction = nil  -- fromAC / toAC / unknown (parsed from comment tag)
    local channel_info_str = ""   -- "[channel, direction] " prefix for info column

    if version == 0x00 then
        subtree:add(f.header_version, udp_payload_buffer(12, 1)):append_text(" (Legacy)")
    elseif version == 0x01 then
        subtree:add(f.header_version, udp_payload_buffer(12, 1)):append_text(" (Extended)")
        local pos = 13
        -- logicChannel (stored for info column, appended after direction is known)
        local ch_len = udp_payload_buffer(pos, 1):uint()
        local channel_name = nil
        pos = pos + 1
        if ch_len > 0 then
            channel_name = udp_payload_buffer(pos, ch_len):string()
            subtree:add(f.logic_channel, udp_payload_buffer(pos, ch_len))
            pos = pos + ch_len
        end
        -- circuitBoard
        local board_len = udp_payload_buffer(pos, 1):uint()
        pos = pos + 1
        if board_len > 0 then
            subtree:add(f.circuit_board, udp_payload_buffer(pos, board_len))
            pos = pos + board_len
        end
        -- comment (may contain [fromAC]/[toAC]/[unknown] direction tag)
        local comment_len = udp_payload_buffer(pos, 1):uint()
        pos = pos + 1
        if comment_len > 0 then
            local comment_str = udp_payload_buffer(pos, comment_len):string()
            subtree:add(f.channel_comment, udp_payload_buffer(pos, comment_len))
            -- Extract direction tag from comment: [toACmainboard], [fromACmainboard],
            -- [toACdisplay], [fromACdisplay], [unknown]
            local dir_match = string.match(comment_str, "%[(%a+)%]")
            if dir_match then
                channel_direction = dir_match
            end
            pos = pos + comment_len
        end
        -- Build [channel, direction] prefix for info column (prepended later per bus type)
        if channel_name then
            local dir_str = channel_direction and channel_direction ~= "unknown"
                and channel_direction or nil
            if dir_str then
                channel_info_str = "[" .. channel_name .. ", " .. dir_str .. "] "
            else
                channel_info_str = "[" .. channel_name .. "] "
            end
        end
        data_offset = pos
    else
        subtree:add(f.header_version, udp_payload_buffer(12, 1)):append_text(" (Unknown)")
    end

    -- ── Helper: buffer slice relative to protocol data start ─────────────
    local function pbuf(offset, length)
        return udp_payload_buffer(data_offset + offset, length)
    end

    local proto_len = udp_payload_buffer:len() - data_offset
    if proto_len < 2 then return end

    local protocol_buffer = udp_payload_buffer(data_offset, proto_len)

    -- ── Protocol selection ─────────────────────────────────────────────
    -- bus_type from HVAC_shark header determines the parser:
    --   0x00 = XYE,  0x01 = UART,  0x02 = disp-mainboard_1,  0x03 = r-t_1
    -- For legacy packets (bus_type=0x00), auto-detect via byte 1:
    --   XYE commands {0xC0..0xCD} vs UART length {0x0D..0x40}

    local byte1 = protocol_buffer(1, 1):uint()
    local is_xye, is_uart, is_disp_mb, is_rt, is_ir

    if bus_type == 0x01 then
        is_uart = true
    elseif bus_type == 0x02 then
        is_disp_mb = true
    elseif bus_type == 0x03 then
        is_rt = true
    elseif bus_type == 0x04 then
        is_ir = true
    elseif bus_type == 0x00 then
        -- Legacy auto-detection for XYE-tagged packets
        is_xye = XYE_COMMANDS[byte1] ~= nil
        is_uart = (not is_xye) and (byte1 >= 0x0D and byte1 <= 0x40)
    else
        -- Unknown bus type — try auto-detection
        is_xye = XYE_COMMANDS[byte1] ~= nil
        is_uart = (not is_xye) and (byte1 >= 0x0D and byte1 <= 0x40)
    end

    if is_uart then
        -- ══════════════════════════════════════════════════════════════════
        -- ── MIDEA UART (SmartKey) PROTOCOL ──────────────────────────────
        -- ══════════════════════════════════════════════════════════════════
        subtree:add(f.protocol_type, "Midea UART (SmartKey)")
        pinfo.cols.info:prepend("UART ")
        pinfo.cols.info:prepend(channel_info_str)

        local frame_len = byte1 + 1  -- total frame = LENGTH + 1 (byte 0)

        -- Frame header
        subtree:add(f.command_length, frame_len)
        local hdr_tree = subtree:add(pbuf(0, math.min(10, proto_len)), "UART Frame Header")
        hdr_tree:add(pbuf(0, 1), string.format("Start: 0x%02X", protocol_buffer(0, 1):uint()))
        hdr_tree:add(f.uart_length, pbuf(1, 1))
        hdr_tree:add(f.uart_appliance, pbuf(2, 1)):append_text(
            protocol_buffer(2, 1):uint() == 0xAC and " (Air Conditioner)" or "")

        -- Sync validation — spec says LENGTH XOR APPLIANCE_TYPE,
        -- but many devices leave this as 0x00 (unimplemented)
        local sync_val = protocol_buffer(3, 1):uint()
        local sync_expected = bit.bxor(byte1, protocol_buffer(2, 1):uint())
        local sync_text
        if sync_val == sync_expected then
            sync_text = " (Valid)"
        elseif sync_val == 0x00 then
            sync_text = " (Zero — not implemented by device)"
        else
            sync_text = string.format(" (INVALID, expected 0x%02X)", sync_expected)
        end
        hdr_tree:add(f.uart_sync, pbuf(3, 1)):append_text(sync_text)

        hdr_tree:add(pbuf(4, 4), "Reserved: " .. tostring(protocol_buffer(4, 4):bytes()))

        if proto_len >= 10 then
            hdr_tree:add(f.uart_protocol, pbuf(8, 1))
            local msg_type = protocol_buffer(9, 1):uint()
            local msg_type_str = SERIAL_MSG_TYPES[msg_type] or "Unknown"
            hdr_tree:add(f.uart_msg_type, pbuf(9, 1)):append_text(" (" .. msg_type_str .. ")")
        end

        -- Body + integrity
        if proto_len >= frame_len and frame_len >= 12 then
            local body_off = data_offset + 10
            local body_len = frame_len - 12  -- minus header(10) + CRC(1) + checksum(1)

            -- CRC-8 validation (over body bytes)
            local crc_offset = data_offset + frame_len - 2
            local crc_val = udp_payload_buffer(crc_offset, 1):uint()
            local crc_calc = uart_crc8(udp_payload_buffer, body_off, body_len)
            local crc_ok = crc_val == crc_calc

            -- Checksum validation (over bytes 1..N-2)
            local cksum_offset = data_offset + frame_len - 1
            local cksum_val = udp_payload_buffer(cksum_offset, 1):uint()
            local cksum_calc = uart_checksum(udp_payload_buffer, data_offset + 1, crc_offset)
            local cksum_ok = cksum_val == cksum_calc

            local integrity_str = string.format("CRC8: 0x%02X %s, Checksum: 0x%02X %s",
                crc_val, crc_ok and "(Valid)" or string.format("(INVALID, calc 0x%02X)", crc_calc),
                cksum_val, cksum_ok and "(Valid)" or string.format("(INVALID, calc 0x%02X)", cksum_calc))

            -- Body tree
            local body_tree = subtree:add(udp_payload_buffer(body_off, body_len),
                string.format("Body (%d bytes) — %s", body_len, integrity_str))

            if body_len > 0 then
                local cmd_id   = udp_payload_buffer(body_off, 1):uint()
                local msg_type = proto_len >= 10 and protocol_buffer(9, 1):uint() or 0
                -- For msg_type-dispatched frames body[0] is not a cmd_id; use msg_type label instead
                local msg_type_dispatched = (msg_type == 0x07 or msg_type == 0x63
                    or msg_type == 0x0D or msg_type == 0x65)
                local cmd_str
                if msg_type_dispatched then
                    cmd_str = SERIAL_MSG_TYPES[msg_type] or string.format("msgtype=0x%02X", msg_type)
                else
                    cmd_str = SERIAL_COMMAND_IDS[cmd_id] or string.format("0x%02X", cmd_id)
                end
                pinfo.cols.info:append(" " .. cmd_str)

                -- Dispatch: some frame types are keyed on msg_type (body[0] is not a cmd_id)
                if msg_type == 0x07 then
                    decode_uart_07_devid(body_tree, udp_payload_buffer, body_off, body_len)
                elseif msg_type == 0x63 or msg_type == 0x0D then
                    decode_uart_netstatus(body_tree, udp_payload_buffer, body_off, body_len, msg_type)
                elseif msg_type == 0x65 then
                    decode_uart_racserial(body_tree, udp_payload_buffer, body_off, body_len)
                -- Standard body[0]-keyed dispatch
                elseif cmd_id == 0xC0 then
                    decode_uart_c0_status(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0xA0 then
                    -- Heartbeat ACK: body layout identical to C0
                    decode_uart_c0_status(body_tree, udp_payload_buffer, body_off, body_len, 0xA0)
                elseif cmd_id == 0xA1 then
                    decode_uart_a1_heartbeat(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0xA2 or cmd_id == 0xA3
                        or cmd_id == 0xA5 or cmd_id == 0xA6 then
                    decode_uart_heartbeat_subpage(body_tree, udp_payload_buffer, body_off, body_len, cmd_id)
                elseif cmd_id == 0xC1 then
                    decode_uart_c1(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0x40 then
                    decode_uart_40_set(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0x41 then
                    decode_uart_41_query(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0x93 then
                    decode_uart_93(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0xB0 or cmd_id == 0xB1 then
                    decode_uart_b0b1_tlv(body_tree, udp_payload_buffer, body_off, body_len, cmd_id)
                elseif cmd_id == 0xB5 then
                    decode_uart_b5_capabilities(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0x64 then
                    body_tree:add(udp_payload_buffer(body_off, 1), "Command ID: 0x64 (OTA/Key Trigger)")
                    if body_len > 1 then
                        body_tree:add(udp_payload_buffer(body_off + 1, body_len - 1),
                            "Payload: " .. tostring(udp_payload_buffer(body_off + 1, body_len - 1):bytes()))
                    end
                else
                    body_tree:add(udp_payload_buffer(body_off, body_len),
                        string.format("Raw Body (0x%02X): ", cmd_id) ..
                        tostring(udp_payload_buffer(body_off, body_len):bytes()))
                end
            end

            -- CRC + checksum display
            subtree:add(udp_payload_buffer(crc_offset, 1), string.format(
                "CRC-8: 0x%02X %s", crc_val,
                crc_ok and "(Valid)" or string.format("(INVALID, calculated 0x%02X)", crc_calc)))
            subtree:add(udp_payload_buffer(cksum_offset, 1), string.format(
                "Checksum: 0x%02X %s", cksum_val,
                cksum_ok and "(Valid)" or string.format("(INVALID, calculated 0x%02X)", cksum_calc)))
        else
            subtree:add(pbuf(0, proto_len), "Frame data (incomplete): " ..
                tostring(protocol_buffer:bytes()))
        end

        -- Raw frame hex dump (always shown for research)
        subtree:add(pbuf(0, proto_len), "Raw Frame: " .. tostring(protocol_buffer:bytes()))

    elseif is_xye then
        -- ══════════════════════════════════════════════════════════════════
        -- ── XYE RS-485 PROTOCOL (existing decoder) ──────────────────────
        -- ══════════════════════════════════════════════════════════════════
        subtree:add(f.protocol_type, "XYE (RS-485)")
        pinfo.cols.info:prepend("XYE ")
        pinfo.cols.info:prepend(channel_info_str)

        subtree:add(f.command_code, pbuf(1, 1))

        local protocol_length = protocol_buffer:len()
        subtree:add(f.command_length, protocol_length)
        local protocol_buffer_anotation_string = string.format("(Length: %d bytes - ", protocol_length)

        if protocol_length >= 3 then
            local protocol_crc = protocol_buffer(protocol_length - 2, 1):uint()
            local calculated_protocol_crc = validate_crc(protocol_buffer, protocol_length)
            protocol_buffer_anotation_string = protocol_buffer_anotation_string .. string.format("CRC: 0x%02X %s",
                protocol_crc,
                calculated_protocol_crc == protocol_crc and " valid" or
                string.format(" invalid, calculated: 0x%02X", calculated_protocol_crc))
        end

        local data_subtree = subtree:add(f.data, udp_payload_buffer(data_offset, proto_len)):append_text(
            " " .. protocol_buffer_anotation_string .. ")")

        if protocol_length == 16 then
            data_subtree:add(pbuf(0, 1), "0x00 Preamble: " .. string.format("0x%02X", protocol_buffer(0, 1):uint()))
            local command_code = protocol_buffer(1, 1):uint()
            local command_name = XYE_COMMANDS[command_code] or "Unknown"
            pinfo.cols.info:append(string.format("M->S 0x%02X %s", command_code, command_name))
            data_subtree:add(pbuf(1, 1), "0x01 Command: " .. string.format("0x%02X", command_code) .. " (" .. command_name .. ")")
            data_subtree:add(pbuf(2, 1), "0x02 Destination: " .. string.format("0x%02X", protocol_buffer(2, 1):uint()))
            data_subtree:add(pbuf(3, 1), "0x03 Source / Own ID: " .. string.format("0x%02X", protocol_buffer(3, 1):uint()))
            data_subtree:add(pbuf(4, 1), "0x04 From Master: " .. string.format("0x%02X", protocol_buffer(4, 1):uint()))
            data_subtree:add(pbuf(5, 1), "0x05 Source / Own ID: " .. string.format("0x%02X", protocol_buffer(5, 1):uint()))

            if command_code == 0xC3 then
                local oper_mode = protocol_buffer(6, 1):uint()
                data_subtree:add(pbuf(6, 1), "0x06 Operating Mode: " .. string.format("0x%02X", oper_mode) .. " (" .. getOperModeString(oper_mode) .. ")")
                local fan = protocol_buffer(7, 1):uint()
                data_subtree:add(pbuf(7, 1), "0x07 Fan: " .. string.format("0x%02X", fan) .. " (" .. getFanString(fan) .. ")")
                data_subtree:add(pbuf(8, 1), "0x08 Set Temp: " .. string.format("0x%02X", protocol_buffer(8, 1):uint()) .. " C")
                local mode_flags = protocol_buffer(9, 1):uint()
                local mode_flags_str = "Unknown"
                if mode_flags == 0x02 then mode_flags_str = "Aux Heat (Turbo)"
                elseif mode_flags == 0x00 then mode_flags_str = "Normal"
                elseif mode_flags == 0x01 then mode_flags_str = "ECO Mode (Sleep)"
                elseif mode_flags == 0x04 then mode_flags_str = "Swing"
                elseif mode_flags == 0x88 then mode_flags_str = "Ventilate" end
                data_subtree:add(pbuf(9, 1), "0x09 Mode Flags: " .. string.format("0x%02X", mode_flags) .. " (" .. mode_flags_str .. ")")
                data_subtree:add(pbuf(10, 1), "0x0A Timer Start: " .. string.format("0x%02X", protocol_buffer(10, 1):uint()))
                data_subtree:add(pbuf(11, 1), "0x0B Timer Stop: " .. string.format("0x%02X", protocol_buffer(11, 1):uint()))
                data_subtree:add(pbuf(12, 1), "0x0C Unknown: " .. string.format("0x%02X", protocol_buffer(12, 1):uint()))
            elseif command_code == 0xC6 then
                -- C6 master request: Follow-Me + Swing activation (Sessions 7/8)
                local swing = protocol_buffer(6, 1):uint()
                data_subtree:add(pbuf(6, 1), string.format("0x06 Swing: 0x%02X (%s)", swing, getSwingString(swing)))
                data_subtree:add(pbuf(7, 1), string.format("0x07 Unknown: 0x%02X", protocol_buffer(7, 1):uint()))
                data_subtree:add(pbuf(8, 1), string.format("0x08 Unknown: 0x%02X", protocol_buffer(8, 1):uint()))
                data_subtree:add(pbuf(9, 1), string.format("0x09 Unknown: 0x%02X", protocol_buffer(9, 1):uint()))
                data_subtree:add(pbuf(10, 1), string.format("0x0A Unknown: 0x%02X", protocol_buffer(10, 1):uint()))
                data_subtree:add(pbuf(11, 1), string.format("0x0B Unknown: 0x%02X", protocol_buffer(11, 1):uint()))
                data_subtree:add(pbuf(12, 1), string.format("0x0C Unknown: 0x%02X", protocol_buffer(12, 1):uint()))
            else
                data_subtree:add(pbuf(6, 7), "Payload: " .. tostring(protocol_buffer(6, 7):bytes()))
            end

            data_subtree:add(pbuf(13, 1), "0x0D Command Check: " .. string.format("0x%02X", protocol_buffer(13, 1):uint()))
            local calculated_crc = validate_crc(udp_payload_buffer(data_offset, 16), 16)
            local crc_value = protocol_buffer(14, 1):uint()
            if calculated_crc == crc_value then
                data_subtree:add(pbuf(14, 1), "0x0E CRC: " .. string.format("0x%02X", crc_value) .. " (Valid)")
            else
                data_subtree:add(pbuf(14, 1), "0x0E CRC: " .. string.format("0x%02X", crc_value) .. " (Invalid, calculated: 0x%02X)", calculated_crc)
            end
            data_subtree:add(pbuf(15, 1), "0x0F EndOfFrame: " .. string.format("0x%02X", protocol_buffer(15, 1):uint()))

        elseif protocol_length == 32 then
            local command_code = protocol_buffer(1, 1):uint()
            local command_name = XYE_COMMANDS[command_code] or "Unknown"
            if command_code == 0xD0 then
                pinfo.cols.info:append(string.format("BCAST 0x%02X %s", command_code, command_name))
            else
                pinfo.cols.info:append(string.format("S->M 0x%02X %s", command_code, command_name))
            end
            data_subtree:add(pbuf(0, 1), "0x00 Preamble: " .. string.format("0x%02X", protocol_buffer(0, 1):uint()))
            data_subtree:add(pbuf(1, 1), "0x01 Response Code: " .. string.format("0x%02X", command_code) .. " (" .. command_name .. ")")

            if command_code == 0xC0 or command_code == 0xC3 then
                data_subtree:add(pbuf(2, 1), "0x02 To Master: " .. string.format("0x%02X", protocol_buffer(2, 1):uint()))
                data_subtree:add(pbuf(3, 1), "0x03 Destination: " .. string.format("0x%02X", protocol_buffer(3, 1):uint()))
                data_subtree:add(pbuf(4, 1), "0x04 Source/Own ID: " .. string.format("0x%02X", protocol_buffer(4, 1):uint()))
                data_subtree:add(pbuf(5, 1), "0x05 Destination (masterID): " .. string.format("0x%02X", protocol_buffer(5, 1):uint()))

                local oper_mode = protocol_buffer(8, 1):uint()
                data_subtree:add(pbuf(8, 1), "0x08 Operating Mode: " .. string.format("0x%02X", oper_mode) .. " (" .. getOperModeString(oper_mode) .. ")")
                local fan = protocol_buffer(9, 1):uint()
                data_subtree:add(pbuf(9, 1), "0x09 Fan: " .. string.format("0x%02X", fan) .. " (" .. getFanString(fan) .. ")")
                local set_temp_raw = protocol_buffer(10, 1):uint()
                data_subtree:add(pbuf(10, 1), string.format("0x0A Set Temp: 0x%02X (%.0f C)", set_temp_raw, set_temp_raw - 0x40))
                -- Confirmed Sessions 3/4: setT = raw - 0x40 (e.g. 0x56=22°C, 0x59=25°C)

                -- Sensor byte formula: (raw - 40) / 2.0  [codeberg Erlang emulator, offset=40]
                -- Confirmed Session 4: T1=0x42→13°C matches R-T UART Indoor Temp (T×2+50);
                -- T3=0x33→5.5°C matches R-T UART Outdoor Temp. README formula (offset=48) was off by 4°C.
                local t1 = protocol_buffer(11, 1):uint()
                data_subtree:add(pbuf(11, 1), string.format("0x0B T1 (indoor air): 0x%02X (%.1f C)", t1, (t1 - 40) / 2.0))
                local t2a = protocol_buffer(12, 1):uint()
                data_subtree:add(pbuf(12, 1), string.format("0x0C T2A (indoor coil in): 0x%02X (%.1f C)", t2a, (t2a - 40) / 2.0))
                local t2b = protocol_buffer(13, 1):uint()
                data_subtree:add(pbuf(13, 1), string.format("0x0D T2B (indoor coil out): 0x%02X (%.1f C)", t2b, (t2b - 40) / 2.0))
                local t3 = protocol_buffer(14, 1):uint()
                data_subtree:add(pbuf(14, 1), string.format("0x0E T3 (outdoor coil): 0x%02X (%.1f C)", t3, (t3 - 40) / 2.0))
                data_subtree:add(pbuf(15, 1), "0x0F Current: " .. string.format("0x%02X", protocol_buffer(15, 1):uint()))

                local timer_start = protocol_buffer(17, 1):uint()
                local hours_start = math.floor((timer_start % 128) * 15 / 60)
                local minutes_start = (timer_start % 128) * 15 % 60
                data_subtree:add(pbuf(17, 1), "0x11 Timer Start: " .. string.format("0x%02X (%dh%02dm)", timer_start, hours_start, minutes_start))
                local timer_stop = protocol_buffer(18, 1):uint()
                local hours_stop = math.floor((timer_stop % 128) * 15 / 60)
                local minutes_stop = (timer_stop % 128) * 15 % 60
                data_subtree:add(pbuf(18, 1), "0x12 Timer Stop: " .. string.format("0x%02X (%dh%02dm)", timer_stop, hours_stop, minutes_stop))

                data_subtree:add(pbuf(19, 1), "0x13 Run: " .. string.format("0x%02X", protocol_buffer(19, 1):uint()))
                data_subtree:add(pbuf(20, 1), "0x14 Mode Flags: " .. string.format("0x%02X", protocol_buffer(20, 1):uint()))
                data_subtree:add(pbuf(21, 1), "0x15 Operating Flags: " .. string.format("0x%02X", protocol_buffer(21, 1):uint()))
                data_subtree:add(pbuf(22, 1), "0x16 Error E (0..7): " .. string.format("0x%02X", protocol_buffer(22, 1):uint()))
                data_subtree:add(pbuf(23, 1), "0x17 Error E (7..f): " .. string.format("0x%02X", protocol_buffer(23, 1):uint()))
                data_subtree:add(pbuf(24, 1), "0x18 Protect P (0..7): " .. string.format("0x%02X", protocol_buffer(24, 1):uint()))
                data_subtree:add(pbuf(25, 1), "0x19 Protect P (7..f): " .. string.format("0x%02X", protocol_buffer(25, 1):uint()))
                data_subtree:add(pbuf(26, 1), "0x1A CCM Comm Error: " .. string.format("0x%02X", protocol_buffer(26, 1):uint()))

                for i = 27, 29 do
                    data_subtree:add(pbuf(i, 1), string.format("0x%02X Unknown: 0x%02X", i, protocol_buffer(i, 1):uint()))
                end
            elseif command_code == 0xC4 or command_code == 0xC6 then
                -- C4/C6 extended response: partially decoded (Sessions 6/7)
                for i = 2, 15 do
                    data_subtree:add(pbuf(i, 1), string.format("0x%02X: 0x%02X", i, protocol_buffer(i, 1):uint()))
                end
                local c4_mode = protocol_buffer(16, 1):uint()
                data_subtree:add(pbuf(16, 1), string.format("0x10 Operating Mode: 0x%02X (%s)", c4_mode, getOperModeString(c4_mode)))
                local c4_fan = protocol_buffer(17, 1):uint()
                data_subtree:add(pbuf(17, 1), string.format("0x11 Fan: 0x%02X (%s)", c4_fan, getFanString(c4_fan)))
                local c4_sett = protocol_buffer(18, 1):uint()
                data_subtree:add(pbuf(18, 1), string.format("0x12 Set Temp: 0x%02X (%.0f C)", c4_sett, c4_sett - 0x40))
                -- byte[19] = 0xBC = fixed outdoor-unit device-type field, NOT Tp
                data_subtree:add(pbuf(19, 1), string.format("0x13 Device type: 0x%02X (fixed)", protocol_buffer(19, 1):uint()))
                data_subtree:add(pbuf(20, 1), string.format("0x14 Unknown: 0x%02X (%.1f C if XYE sensor formula)", protocol_buffer(20, 1):uint(), (protocol_buffer(20, 1):uint() - 40) / 2.0))
                local c4_t4 = protocol_buffer(21, 1):uint()
                data_subtree:add(pbuf(21, 1), string.format("0x15 T4 (outdoor ambient): 0x%02X (%.1f C)", c4_t4, (c4_t4 - 40) / 2.0))
                -- byte[22] = Tp discharge temperature, confirmed by cross-session UART comparison
                local c4_tp = protocol_buffer(22, 1):uint()
                data_subtree:add(pbuf(22, 1), string.format("0x16 Tp (compressor discharge): 0x%02X (%.1f C)  [ConfirmedS6]", c4_tp, (c4_tp - 40) / 2.0))
                for i = 23, 29 do
                    data_subtree:add(pbuf(i, 1), string.format("0x%02X: 0x%02X", i, protocol_buffer(i, 1):uint()))
                end
            elseif command_code == 0xD0 then
                -- D0 broadcast: periodic status report (Sessions 7/8)
                for i = 2, 4 do
                    data_subtree:add(pbuf(i, 1), string.format("0x%02X: 0x%02X", i, protocol_buffer(i, 1):uint()))
                end
                local d0_mode = protocol_buffer(5, 1):uint()
                data_subtree:add(pbuf(5, 1), string.format("0x05 Operating Mode: 0x%02X (%s)", d0_mode, getOperModeString(d0_mode)))
                local d0_fan = protocol_buffer(6, 1):uint()
                data_subtree:add(pbuf(6, 1), string.format("0x06 Fan: 0x%02X (%s)", d0_fan, getFanString(d0_fan)))
                local d0_sett = protocol_buffer(7, 1):uint()
                data_subtree:add(pbuf(7, 1), string.format("0x07 Set Temp: 0x%02X (%.0f C)", d0_sett, d0_sett - 0x40))
                for i = 8, 10 do
                    data_subtree:add(pbuf(i, 1), string.format("0x%02X: 0x%02X", i, protocol_buffer(i, 1):uint()))
                end
                local d0_swing = protocol_buffer(11, 1):uint()
                data_subtree:add(pbuf(11, 1), string.format("0x0B Swing: 0x%02X (%s)", d0_swing, getSwingString(d0_swing)))
                for i = 12, 29 do
                    data_subtree:add(pbuf(i, 1), string.format("0x%02X: 0x%02X", i, protocol_buffer(i, 1):uint()))
                end
            else
                -- Other response codes: dump all bytes with offset labels
                for i = 2, 29 do
                    data_subtree:add(pbuf(i, 1), string.format("0x%02X: 0x%02X", i, protocol_buffer(i, 1):uint()))
                end
            end

            -- CRC + EndOfFrame for 32-byte XYE
            local crc_32 = protocol_buffer(30, 1):uint()
            local calc_crc_32 = validate_crc(udp_payload_buffer(data_offset, 32), 32)
            if calc_crc_32 == crc_32 then
                data_subtree:add(pbuf(30, 1), "0x1E CRC: " .. string.format("0x%02X", crc_32) .. " (Valid)")
            else
                data_subtree:add(pbuf(30, 1), "0x1E CRC: " .. string.format("0x%02X", crc_32) .. " (Invalid, calculated: 0x%02X)", calc_crc_32)
            end
            data_subtree:add(pbuf(31, 1), "0x1F EndOfFrame: " .. string.format("0x%02X", protocol_buffer(31, 1):uint()))

        else
            data_subtree:add(udp_payload_buffer(data_offset, proto_len),
                "Data: " .. tostring(protocol_buffer:bytes()))
        end

        -- Raw frame hex dump (always shown for research)
        subtree:add(pbuf(0, proto_len), "Raw Frame: " .. tostring(protocol_buffer:bytes()))

    elseif is_disp_mb then
        -- ══════════════════════════════════════════════════════════════════
        -- ── DISPLAY ↔ MAINBOARD INTERNAL BUS ─────────────────────────────
        -- ══════════════════════════════════════════════════════════════════
        -- Frame structure (confirmed across 25,832 frames, 8 sessions):
        --   byte[0]    = 0xAA  (start)
        --   byte[1]    = type  (0x20/0x30/0x31/0x50/0xFF)
        --   byte[2]    = total frame length (includes all bytes 0..N-1)
        --   byte[3..N-3] = payload
        --   byte[N-2]  = CRC-8/MAXIM over bytes[0..N-3]  (same table as UART CRC-8)
        --   byte[N-1]  = checksum = (256 - sum(frame[1..N-2])) & 0xFF
        --
        -- Direction by length for type 0x20:
        --   36 bytes = Grey (display -> mainboard request)
        --   29 bytes = Blue (mainboard -> display response)
        -- See protocol_mainboard.md for full specification.
        subtree:add(f.protocol_type, "Display-Mainboard Internal Bus")

        local frame_type = byte1

        -- ── Mainboard lookup tables ─────────────────────────────────────
        local MB_MODE_NAMES = {
            [0] = "Cool", [1] = "Dry", [2] = "Fan", [3] = "Heat", [4] = "Auto",
            [5] = "Initializing",
        }
        local MB_FAN_NAMES = {
            [0] = "Stopped", [1] = "Idle", [20] = "Silent", [23] = "Heat warm-up",
            [40] = "Low", [60] = "Medium", [80] = "High",
            [100] = "Max", [102] = "Auto", [103] = "Heat full",
        }

        local function getMbModeString(m)
            return MB_MODE_NAMES[m] or string.format("Unknown(%d)", m)
        end
        local function getMbFanString(f_val)
            return MB_FAN_NAMES[f_val] or string.format("%d", f_val)
        end

        -- ── Direction and type label ────────────────────────────────────
        local type_names = {
            [0x20] = "Status",
            [0x30] = "Telemetry",
            [0x31] = "Config",
            [0x50] = "Boot Init",
            [0xFF] = "Bus Sync",
        }
        local type_label = type_names[frame_type] or string.format("0x%02X", frame_type)

        -- Direction: Grey = display->mainboard (request), Blue = mainboard->display (response)
        local direction
        if frame_type == 0x20 then
            if proto_len == 36 then direction = "Grey"    -- display -> mainboard
            elseif proto_len == 29 then direction = "Blue" -- mainboard -> display
            end
        elseif frame_type == 0x30 then
            if proto_len == 10 then direction = "Grey" else direction = "Blue" end
        elseif frame_type == 0x31 then
            if proto_len == 32 then direction = "Grey" else direction = "Blue" end
        elseif frame_type == 0x50 then
            if proto_len == 21 then direction = "Grey" else direction = "Blue" end
        end
        local dir_label = direction or "?"
        local dir_arrow = direction == "Grey" and "Disp->MB" or
                          direction == "Blue" and "MB->Disp" or "?"

        -- ── Build info column summary ───────────────────────────────────
        local info_summary = string.format("DISP-MB %s %s ", type_label, dir_label)

        -- ── Frame tree ──────────────────────────────────────────────────
        local frame_tree = subtree:add(pbuf(0, proto_len),
            string.format("Internal Bus: %s %s (%s) len=%d",
                type_label, dir_label, dir_arrow, proto_len))

        frame_tree:add(pbuf(0, 1), string.format("Start: 0xAA"))
        frame_tree:add(pbuf(1, 1), string.format("Frame Type: 0x%02X (%s)", frame_type, type_label))

        if proto_len >= 3 then
            local pkt_len = protocol_buffer(2, 1):uint()
            local len_ok = (pkt_len == proto_len)
            frame_tree:add(pbuf(2, 1), string.format("Length: %d %s",
                pkt_len, len_ok and "(valid)" or
                string.format("(MISMATCH: frame=%d)", proto_len)))
        end

        -- ── Type 0x20 Grey: Display -> Mainboard request (36 bytes) ────
        if frame_type == 0x20 and proto_len == 36 then
            local pay_tree = frame_tree:add(pbuf(3, 31), "Control Request (Grey)")

            local mode = protocol_buffer(3, 1):uint()
            pay_tree:add(pbuf(3, 1), string.format("Mode: %d (%s)",
                mode, getMbModeString(mode)))

            local temp_raw = protocol_buffer(4, 1):uint()
            local temp_c = (temp_raw - 30) / 2.0
            pay_tree:add(pbuf(4, 1), string.format("Set Temp: %.1f C (raw: %d)",
                temp_c, temp_raw))

            local fan = protocol_buffer(5, 1):uint()
            pay_tree:add(pbuf(5, 1), string.format("Fan Speed: %d (%s)",
                fan, getMbFanString(fan)))

            local flags = protocol_buffer(9, 1):uint()
            local power = bit.band(bit.rshift(flags, 6), 1)
            local h_swing = bit.band(bit.rshift(flags, 4), 1)
            local v_swing = bit.band(bit.rshift(flags, 2), 1)
            pay_tree:add(pbuf(9, 1), string.format(
                "Flags: 0x%02X  Power=%s  H-Swing=%s  V-Swing=%s",
                flags, power == 1 and "ON" or "OFF",
                h_swing == 1 and "ON" or "OFF",
                v_swing == 1 and "ON" or "OFF"))

            local counter = protocol_buffer(16, 1):uint()
            pay_tree:add(pbuf(16, 1), string.format("Counter: 0x%02X  [H-05]", counter))

            if proto_len > 21 then
                local vane = protocol_buffer(21, 1):uint()
                local h_vane = bit.rshift(vane, 4)
                local v_vane = bit.band(vane, 0x0F)
                if vane ~= 0 then
                    pay_tree:add(pbuf(21, 1), string.format(
                        "Vane Position: 0x%02X  H=%d V=%d  [H-06]", vane, h_vane, v_vane))
                end
            end

            -- Info column summary
            info_summary = string.format("DISP-MB %s Grey  %s %.0fC %s  Pwr=%s",
                type_label, getMbModeString(mode), temp_c,
                getMbFanString(fan), power == 1 and "ON" or "OFF")

        -- ── Type 0x20 Blue: Mainboard -> Display response (29 bytes) ───
        elseif frame_type == 0x20 and proto_len == 29 then
            local pay_tree = frame_tree:add(pbuf(3, 24), "Status Response (Blue)")

            local mode = protocol_buffer(3, 1):uint()
            pay_tree:add(pbuf(3, 1), string.format("Mode: %d (%s)",
                mode, getMbModeString(mode)))

            local actual_fan = protocol_buffer(5, 1):uint()
            pay_tree:add(pbuf(5, 1), string.format("Actual Fan: %d (%s)",
                actual_fan, getMbFanString(actual_fan)))

            if proto_len > 13 then
                local status_flag = protocol_buffer(13, 1):uint()
                pay_tree:add(pbuf(13, 1), string.format("Status Flag: 0x%02X  [H-09]",
                    status_flag))
            end

            if proto_len > 19 then
                local ready = protocol_buffer(19, 1):uint()
                pay_tree:add(pbuf(19, 1), string.format("Ready: 0x%02X (%s)  [H-10]",
                    ready, ready == 0xFF and "Ready" or
                    ready == 0x00 and "Booting" or "Unknown"))
            end

            -- Info column summary
            info_summary = string.format("DISP-MB %s Blue  %s  Fan=%s",
                type_label, getMbModeString(mode), getMbFanString(actual_fan))

        -- ── Type 0x30 Grey: Telemetry query (10 bytes) ─────────────────
        elseif frame_type == 0x30 and proto_len == 10 then
            frame_tree:add(pbuf(3, 5), "Telemetry Query (fixed)")
            info_summary = string.format("DISP-MB %s Grey  Query", type_label)

        -- ── Type 0x30 Blue: Telemetry response (64 bytes) ──────────────
        elseif frame_type == 0x30 and proto_len == 64 then
            local pay_tree = frame_tree:add(pbuf(3, 59), "Telemetry Response")

            local sub_type = protocol_buffer(3, 1):uint()
            pay_tree:add(pbuf(3, 1), string.format("Sub-type: 0x%02X  [H-11]", sub_type))

            -- Outdoor temperature: raw / 2.0 °C
            -- Cross-bus validated: 488 pairs vs R/T outdoor, avg_diff=0.88°C, 93.8% within 2°C
            if proto_len > 4 then
                local outdoor_raw = protocol_buffer(4, 1):uint()
                local outdoor_c = outdoor_raw / 2.0
                pay_tree:add(pbuf(4, 1), string.format(
                    "Outdoor Temp: %.1f °C (raw: %d, encoding: raw/2)",
                    outdoor_c, outdoor_raw))
            end

            -- Temperature candidates [T?] — require UART A1 heartbeat for validation
            -- byte[6]: small range 2-20, varies across sessions. Unknown encoding.
            if proto_len > 6 then
                local t6 = protocol_buffer(6, 1):uint()
                pay_tree:add(pbuf(6, 1), string.format(
                    "Byte[6]: %d  [T? unknown encoding, range 2-20]", t6))
            end

            -- byte[11]: 0 when cold, 40-88 during active heating — likely compressor
            -- discharge pipe temp (Tp). Encoding candidate: direct °C
            if proto_len > 11 then
                local t11 = protocol_buffer(11, 1):uint()
                pay_tree:add(pbuf(11, 1), string.format(
                    "Byte[11]: %d  [T? discharge pipe temp? direct °C]", t11))
            end

            -- Appliance type and protocol version [H-13]
            if proto_len > 17 then
                local app_type = protocol_buffer(16, 1):uint()
                local proto_ver = protocol_buffer(17, 1):uint()
                pay_tree:add(pbuf(16, 2), string.format(
                    "Appliance: 0x%02X (%s)  Proto ver: %d  [H-13]",
                    app_type, app_type == 0xAC and "Air Conditioner" or
                    string.format("Unknown(0x%02X)", app_type), proto_ver))
            end

            -- byte[19]: 0 when compressor off, rises during operation (0-145)
            if proto_len > 19 then
                local t19 = protocol_buffer(19, 1):uint()
                if t19 > 0 then
                    pay_tree:add(pbuf(19, 1), string.format(
                        "Byte[19]: %d  [T? compressor-related, 0=off]", t19))
                end
            end

            -- byte[45]: mostly 0, peaks to 59 during sustained heating
            if proto_len > 45 then
                local t45 = protocol_buffer(45, 1):uint()
                if t45 > 0 then
                    pay_tree:add(pbuf(45, 1), string.format(
                        "Byte[45]: %d  [T? heat-related, 0=idle]", t45))
                end
            end

            -- Show remaining payload as hex dump (skip already-decoded bytes)
            local decoded_bytes = {[3]=1, [4]=1, [6]=1, [11]=1, [16]=1, [17]=1, [19]=1, [45]=1}
            if proto_len > 5 then
                local rem_tree = pay_tree:add(pbuf(5, proto_len - 5 - 2),
                    string.format("Remaining payload (%d bytes)", proto_len - 5 - 2))
                for i = 5, proto_len - 3 do
                    if not decoded_bytes[i] then
                        local bval = protocol_buffer(i, 1):uint()
                        if bval ~= 0 then
                            rem_tree:add(pbuf(i, 1), string.format("[%d] 0x%02X (%d)", i, bval, bval))
                        end
                    end
                end
            end

            info_summary = string.format("DISP-MB %s Blue  sub=0x%02X  Out=%.1f°C",
                type_label, sub_type,
                proto_len > 4 and protocol_buffer(4, 1):uint() / 2.0 or 0)

        -- ── Type 0x31 Grey: Config query (32 bytes) ────────────────────
        elseif frame_type == 0x31 and proto_len == 32 then
            frame_tree:add(pbuf(3, 27), "Config Query (all-zeros)")
            info_summary = string.format("DISP-MB %s Grey  Query", type_label)

        -- ── Type 0x31 Blue: Config response (64 bytes) ─────────────────
        elseif frame_type == 0x31 and proto_len == 64 then
            local pay_tree = frame_tree:add(pbuf(3, 59), "Config Response")

            if proto_len > 4 then
                local temp_raw = protocol_buffer(4, 1):uint()
                local temp_c = (temp_raw - 30) / 2.0
                pay_tree:add(pbuf(4, 1), string.format(
                    "Setpoint echo: %.1f °C (raw: %d)  [H-14]", temp_c, temp_raw))
            end

            -- Stored outdoor temperature: (raw - 40) / 2.0 °C
            -- Cross-bus matched: 487 pairs vs R/T outdoor, avg_diff=0.93°C
            -- Constant within sessions — likely a stored/config value, not live sensor
            if proto_len > 5 then
                local out_raw = protocol_buffer(5, 1):uint()
                local out_c = (out_raw - 40) / 2.0
                pay_tree:add(pbuf(5, 1), string.format(
                    "Stored outdoor temp: %.1f °C (raw: %d, encoding: (r-40)/2)  [cross-bus candidate]",
                    out_c, out_raw))
            end

            -- Show non-zero payload bytes
            local rem_tree = pay_tree:add(pbuf(6, proto_len - 6 - 2),
                string.format("Remaining payload (%d bytes)", proto_len - 6 - 2))
            for i = 6, proto_len - 3 do
                local bval = protocol_buffer(i, 1):uint()
                if bval ~= 0 then
                    rem_tree:add(pbuf(i, 1), string.format("[%d] 0x%02X (%d)", i, bval, bval))
                end
            end

            info_summary = string.format("DISP-MB %s Blue  Config  Set=%.1f°C",
                type_label,
                proto_len > 4 and (protocol_buffer(4, 1):uint() - 30) / 2.0 or 0)

        -- ── Type 0x50: Boot Init ────────────────────────────────────────
        elseif frame_type == 0x50 then
            local label = proto_len == 21 and "Boot Init Query  [H-16]" or
                          "Boot Init Response  [H-16]"
            frame_tree:add(pbuf(3, proto_len - 5), label)
            info_summary = string.format("DISP-MB %s %s  BOOT", type_label, dir_label)

        -- ── Type 0xFF: Bus Sync ─────────────────────────────────────────
        elseif frame_type == 0xFF then
            frame_tree:add(pbuf(3, proto_len - 5), "Bus Sync Handshake  [H-15]")
            info_summary = string.format("DISP-MB %s  SYNC", type_label)

        -- ── Unknown frame types: show raw payload ───────────────────────
        else
            if proto_len >= 5 then
                local pay_tree = frame_tree:add(pbuf(3, proto_len - 5),
                    string.format("Payload (%d bytes)", proto_len - 5))
                for i = 3, proto_len - 3 do
                    local bval = protocol_buffer(i, 1):uint()
                    pay_tree:add(pbuf(i, 1), string.format("[%d] 0x%02X", i, bval))
                end
            end
        end

        -- ── CRC-8/MAXIM verification (byte[N-2]) ───────────────────────
        -- Same polynomial as UART CRC-8 (table CRC8_TABLE), but computed
        -- over bytes[0..N-3] (includes 0xAA start byte).
        if proto_len >= 4 then
            local crc_byte = protocol_buffer(proto_len - 2, 1):uint()
            local crc_calc = uart_crc8(udp_payload_buffer, data_offset, proto_len - 2)
            local crc_ok = (crc_byte == crc_calc)
            frame_tree:add(pbuf(proto_len - 2, 1), string.format(
                "CRC-8: 0x%02X %s (computed 0x%02X)",
                crc_byte, crc_ok and "(valid)" or "*** INVALID ***", crc_calc))
        end

        -- ── Additive checksum verification (byte[N-1]) ─────────────────
        if proto_len >= 3 then
            local ck_byte = protocol_buffer(proto_len - 1, 1):uint()
            local ck_computed = uart_checksum(udp_payload_buffer, data_offset + 1, data_offset + proto_len - 2)
            local ck_ok = (ck_byte == ck_computed)
            frame_tree:add(pbuf(proto_len - 1, 1), string.format(
                "Checksum: 0x%02X %s (computed 0x%02X)",
                ck_byte, ck_ok and "(valid)" or "*** INVALID ***", ck_computed))
        end

        pinfo.cols.info:prepend(info_summary .. " ")
        pinfo.cols.info:prepend(channel_info_str)

        subtree:add(pbuf(0, proto_len), "Raw Frame: " .. tostring(protocol_buffer:bytes()))

    elseif is_rt then
        -- ══════════════════════════════════════════════════════════════════
        -- ── BIDIRECTIONAL EXTENSION BOARD (R/T / HA/HB) BUS ──────────────
        -- ══════════════════════════════════════════════════════════════════
        subtree:add(f.protocol_type, "Extension Board R/T (HA/HB)")

        local start_byte = protocol_buffer(0, 1):uint()
        local is_request = (start_byte == 0xAA)
        -- Direction: from channel_direction tag (set by converter for R/T per-frame),
        -- or infer from start byte if tag is absent (legacy pcaps)
        -- 0xAA = bus adapter → display (toACdisplay), 0x55 = display → bus adapter (fromACdisplay)
        -- Resolve R/T per-frame direction for legacy pcaps without converter tags
        if channel_direction == nil or channel_direction == "unknown" then
            channel_direction = is_request and "toACdisplay" or "fromACdisplay"
        end
        pinfo.cols.info:prepend(string.format("R/T-%s ", is_request and "REQ" or "RSP"))
        -- For R/T, update channel_info_str with resolved per-frame direction
        if channel_name then
            channel_info_str = "[" .. channel_name .. ", " .. (channel_direction or "unknown") .. "] "
        end
        pinfo.cols.info:prepend(channel_info_str)

        local rt_len = proto_len >= 3 and (protocol_buffer(2, 1):uint() + 4) or proto_len

        -- Frame header
        local hdr_tree = subtree:add(pbuf(0, math.min(11, proto_len)), "R/T Frame Header")
        hdr_tree:add(pbuf(0, 1), string.format("Start: 0x%02X (%s)",
            start_byte, is_request and "Request" or "Response"))
        if proto_len >= 2 then
            hdr_tree:add(pbuf(1, 1), string.format("Device Type: 0x%02X", protocol_buffer(1, 1):uint()))
        end
        if proto_len >= 3 then
            local len_val = protocol_buffer(2, 1):uint()
            local len_match = (len_val + 4 == proto_len)
            hdr_tree:add(pbuf(2, 1), string.format("Length: 0x%02X (%d) %s",
                len_val, len_val, len_match and "(valid, total=" .. proto_len .. ")" or
                string.format("(MISMATCH, frame=%d)", proto_len)))
        end
        if proto_len >= 4 then
            hdr_tree:add(pbuf(3, 1), string.format("Appliance: 0x%02X%s",
                protocol_buffer(3, 1):uint(),
                protocol_buffer(3, 1):uint() == 0xAC and " (Air Conditioner)" or ""))
        end
        if proto_len >= 9 then
            hdr_tree:add(pbuf(4, 5), "Reserved: " .. tostring(protocol_buffer(4, 5):bytes()))
        end
        if proto_len >= 10 then
            hdr_tree:add(pbuf(9, 1), string.format("Protocol Version: %d", protocol_buffer(9, 1):uint()))
        end
        if proto_len >= 11 then
            local msg_type = protocol_buffer(10, 1):uint()
            local msg_type_str = SERIAL_MSG_TYPES[msg_type] or "Unknown"
            hdr_tree:add(pbuf(10, 1), string.format("Message Type: 0x%02X (%s)", msg_type, msg_type_str))
        end

        -- Body + integrity (UART-compatible body starts at byte 11)
        -- 0xAA requests: header(11) + body + CRC-8(1) + checksum(1) + 0x00(1) + frame_ck(1) → tail=4
        -- 0x55 responses: header(11) + body + checksum(1) + 0x00(1) + EF(1) → tail=3 (no CRC-8)
        local tail_len = is_request and 4 or 3
        if proto_len >= 11 + 1 + tail_len then  -- need at least header + 1 body + tail
            local body_off = data_offset + 11
            local body_len = proto_len - 11 - tail_len

            -- Body tree
            local integrity_str
            local crc_ok = true
            if is_request then
                -- CRC-8 over body (confirmed for 0xAA requests, not present on 0x55)
                local crc_offset = data_offset + proto_len - 4
                local crc_val = udp_payload_buffer(crc_offset, 1):uint()
                local crc_calc = uart_crc8(udp_payload_buffer, body_off, body_len)
                crc_ok = crc_val == crc_calc
                integrity_str = string.format("CRC8: 0x%02X %s",
                    crc_val, crc_ok and "(Valid)" or string.format("(calc 0x%02X)", crc_calc))
            else
                integrity_str = "no CRC-8"
            end
            local body_tree = subtree:add(udp_payload_buffer(body_off, body_len),
                string.format("Body (%d bytes) — %s", body_len, integrity_str))

            if body_len > 0 then
                local cmd_id = udp_payload_buffer(body_off, 1):uint()
                local cmd_str = SERIAL_COMMAND_IDS[cmd_id] or string.format("Unknown (0x%02X)", cmd_id)
                pinfo.cols.info:append(" " .. cmd_str)

                -- Reuse serial protocol body decoders (shared with UART)
                if cmd_id == 0xC0 then
                    decode_uart_c0_status(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0xA0 then
                    decode_uart_c0_status(body_tree, udp_payload_buffer, body_off, body_len, 0xA0)
                elseif cmd_id == 0xA1 then
                    decode_uart_a1_heartbeat(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0xA2 or cmd_id == 0xA3
                        or cmd_id == 0xA5 or cmd_id == 0xA6 then
                    decode_uart_heartbeat_subpage(body_tree, udp_payload_buffer, body_off, body_len, cmd_id)
                elseif cmd_id == 0xC1 then
                    decode_uart_c1(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0x40 then
                    decode_uart_40_set(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0x41 then
                    decode_uart_41_query(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0x93 then
                    decode_uart_93(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0xB0 or cmd_id == 0xB1 then
                    decode_uart_b0b1_tlv(body_tree, udp_payload_buffer, body_off, body_len, cmd_id)
                elseif cmd_id == 0xB5 then
                    decode_uart_b5_capabilities(body_tree, udp_payload_buffer, body_off, body_len)
                else
                    body_tree:add(udp_payload_buffer(body_off, 1),
                        string.format("Command ID: 0x%02X (%s)", cmd_id, cmd_str))
                    if body_len > 1 then
                        body_tree:add(udp_payload_buffer(body_off + 1, body_len - 1),
                            "Payload: " .. tostring(udp_payload_buffer(body_off + 1, body_len - 1):bytes()))
                    end
                end
            end

            -- Tail bytes
            local tail_off = data_offset + proto_len - tail_len

            if is_request then
                -- 0xAA: CRC-8 + Checksum + 0x00 + Frame Checksum
                local crc_val = udp_payload_buffer(tail_off, 1):uint()
                local crc_calc = uart_crc8(udp_payload_buffer, body_off, body_len)
                subtree:add(udp_payload_buffer(tail_off, 1), string.format(
                    "CRC-8: 0x%02X %s", crc_val,
                    crc_ok and "(Valid)" or string.format("(calc 0x%02X)", crc_calc)))
                tail_off = tail_off + 1
            end

            -- Additive checksum (XYE-style two's complement of sum)
            -- Checksum sits at byte[N-3] in both directions.
            -- Range covers header + body only (excludes CRC-8, checksum, padding, tail):
            --   0xAA: bytes [1..N-5]  (devtype through last body byte, excludes CRC-8 at N-4)
            --   0x55: bytes [2..N-4]  (length through last body byte, no CRC-8 present)
            local cksum_val = udp_payload_buffer(tail_off, 1):uint()
            local cksum_sum = 0
            if is_request then
                for i = 1, proto_len - 5 do
                    cksum_sum = cksum_sum + protocol_buffer(i, 1):uint()
                end
            else
                for i = 2, proto_len - 4 do
                    cksum_sum = cksum_sum + protocol_buffer(i, 1):uint()
                end
            end
            local cksum_calc = bit.band(bit.bnot(bit.band(cksum_sum, 0xFF)) + 1, 0xFF)
            local cksum_ok = cksum_val == cksum_calc
            subtree:add(udp_payload_buffer(tail_off, 1), string.format(
                "Checksum: 0x%02X %s", cksum_val,
                cksum_ok and "(Valid)" or string.format("(INVALID, calc 0x%02X)", cksum_calc)))

            subtree:add(udp_payload_buffer(tail_off + 1, 1), string.format(
                "Padding: 0x%02X", udp_payload_buffer(tail_off + 1, 1):uint()))

            local last_byte = udp_payload_buffer(tail_off + 2, 1):uint()
            if is_request then
                subtree:add(udp_payload_buffer(tail_off + 2, 1), string.format(
                    "Frame Checksum: 0x%02X (sum=0)", last_byte))
            else
                subtree:add(udp_payload_buffer(tail_off + 2, 1), string.format(
                    "End Marker: 0x%02X%s", last_byte,
                    last_byte == 0xEF and " (EF)" or " (unexpected)"))
            end
        else
            subtree:add(pbuf(0, proto_len), "Frame data (too short): " ..
                tostring(protocol_buffer:bytes()))
        end

        -- Raw frame hex dump
        subtree:add(pbuf(0, proto_len), "Raw Frame: " .. tostring(protocol_buffer:bytes()))

    elseif is_ir then
        -- ══════════════════════════════════════════════════════════════════
        -- ── MIDEA IR REMOTE CONTROL PROTOCOL ─────────────────────────────
        -- ══════════════════════════════════════════════════════════════════
        -- 6 bytes per frame: 3 complement pairs (byte[n] XOR byte[n+1] = 0xFF)
        -- Device IDs: 0xB2 = AC control, 0xB9 = Setup/Programming, 0xD5 = Follow-up

        local IR_DEVICE_NAMES = {
            [0xB2] = "Midea AC",
            [0xB9] = "Setup/Programming",
            [0xD5] = "Follow-up",
        }

        local IR_AC_MODES = {
            [0] = "Auto", [1] = "Cool", [2] = "Dry", [3] = "Heat", [4] = "Fan",
        }

        local IR_AC_FAN = {
            [0] = "Auto", [1] = "High", [2] = "Medium", [4] = "Low",
        }

        if proto_len < 6 then
            subtree:add(f.protocol_type, "Midea IR (truncated)")
            subtree:add(pbuf(0, proto_len), "Raw Frame: " .. tostring(protocol_buffer:bytes()))
        else
            local device_id  = protocol_buffer(0, 1):uint()
            local device_cpl = protocol_buffer(1, 1):uint()
            local cmd_byte   = protocol_buffer(2, 1):uint()
            local cmd_cpl    = protocol_buffer(3, 1):uint()
            local ext_byte   = protocol_buffer(4, 1):uint()
            local ext_cpl    = protocol_buffer(5, 1):uint()

            local dev_name = IR_DEVICE_NAMES[device_id] or string.format("Unknown (0x%02X)", device_id)

            -- Complement validation
            local cpl1_ok = bit.bxor(device_id, device_cpl) == 0xFF
            local cpl2_ok = bit.bxor(cmd_byte, cmd_cpl) == 0xFF
            local cpl3_ok = bit.bxor(ext_byte, ext_cpl) == 0xFF
            local all_cpl_ok = cpl1_ok and cpl2_ok and cpl3_ok

            -- Frame type for info column
            local frame_label
            if device_id == 0xB2 then
                frame_label = "IR AC"
            elseif device_id == 0xB9 then
                frame_label = "IR Setup"
            elseif device_id == 0xD5 then
                frame_label = "IR Follow-up"
            else
                frame_label = "IR"
            end

            subtree:add(f.protocol_type, "Midea IR (" .. dev_name .. ")")
            pinfo.cols.info:prepend("[" .. frame_label .. "] ")
            pinfo.cols.info:prepend(channel_info_str)

            -- Device ID
            subtree:add(f.ir_device_id, protocol_buffer(0, 1)):append_text(
                " (" .. dev_name .. ")")
            subtree:add(f.ir_frame_type, frame_label)

            -- Complement check summary
            local cpl_str = string.format("Pair1=%s  Pair2=%s  Pair3=%s",
                cpl1_ok and "OK" or "MISMATCH",
                cpl2_ok and "OK" or "MISMATCH",
                cpl3_ok and "OK" or "MISMATCH")
            local cpl_node = subtree:add(f.ir_complement, cpl_str)
            if not all_cpl_ok then
                cpl_node:add_expert_info(PI_CHECKSUM, PI_WARN, "Complement mismatch")
            end

            -- ── Device-specific decoding ─────────────────────────────────
            if device_id == 0xB2 then
                -- AC Control Command — field mapping from Session 2 cross-referencing
                -- Byte 2 (cmd_byte): mode/power flags — constant 0xBF in all captured
                --   sessions; exact bit assignments TBD (need captures with mode changes)
                -- Byte 4 (ext_byte) encoding — confirmed from 5 distinct frames:
                --   bits[7:5] = temperature - 20  (3 data points: 22C/26C/24C confirmed)
                --   bit  [4]  = swing (0=off, 1=on)   (confirmed from swing toggle)
                --   bits [3:0]= always 0xC in all captures (fixed protocol marker, TBD)
                local ir_tree = subtree:add(pbuf(2, 4), "AC Control")

                -- Command byte: mode/power flags (encoding TBD)
                ir_tree:add(f.ir_command, protocol_buffer(2, 1)):append_text(
                    string.format(" (mode/power flags=0x%02X [TBD])", cmd_byte))

                -- Extended byte: temperature + swing (confirmed), lower nibble fixed
                local temp_bits = bit.rshift(bit.band(ext_byte, 0xE0), 5)
                local temp_c    = temp_bits + 20
                local swing_on  = bit.band(ext_byte, 0x10) ~= 0
                local low_nibble = bit.band(ext_byte, 0x0F)

                ir_tree:add(f.ir_extended, protocol_buffer(4, 1)):append_text(
                    string.format(" (Temp=%d\xC2\xB0C, Swing=%s, fixed=0x%X)",
                        temp_c, swing_on and "On" or "Off", low_nibble))

            elseif device_id == 0xB9 then
                -- Setup / Programming Command
                -- cmd_byte 0xF7 observed; ext_byte = parameter index
                --   0x00-0xFF: installer/setter mode parameter (0x00-0x08 observed as mode 0-8)
                --   0xFF:      settermode query (observed at "enter settermode, query")
                local ir_tree = subtree:add(pbuf(2, 4), "Setup/Programming")
                ir_tree:add(f.ir_command, protocol_buffer(2, 1)):append_text(
                    string.format(" (Function=0x%02X)", cmd_byte))
                if ext_byte == 0xFF then
                    ir_tree:add(f.ir_extended, protocol_buffer(4, 1)):append_text(
                        " (Settermode Query)")
                else
                    ir_tree:add(f.ir_extended, protocol_buffer(4, 1)):append_text(
                        string.format(" (Param=%d)", ext_byte))
                end

            elseif device_id == 0xD5 then
                -- Follow-up / Termination Frame
                local ir_tree = subtree:add(pbuf(2, 4), "Follow-up Frame")
                ir_tree:add(f.ir_command, protocol_buffer(2, 1)):append_text(
                    string.format(" (0x%02X)", cmd_byte))
                ir_tree:add(f.ir_extended, protocol_buffer(4, 1)):append_text(
                    string.format(" (0x%02X)", ext_byte))
                if not cpl1_ok then
                    ir_tree:add_expert_info(PI_PROTOCOL, PI_NOTE,
                        "Non-standard complement (0xD5^0x66≠0xFF)")
                end

            else
                -- Unknown IR device
                subtree:add(f.ir_command, protocol_buffer(2, 1))
                subtree:add(f.ir_extended, protocol_buffer(4, 1))
            end

            -- Raw frame hex dump
            subtree:add(pbuf(0, proto_len), "Raw Frame: " .. tostring(protocol_buffer:bytes()))
        end

    else
        -- Unknown protocol
        subtree:add(f.protocol_type, string.format("Unknown (bus=0x%02X, byte1=0x%02X)", bus_type, byte1))
        subtree:add(udp_payload_buffer(data_offset, proto_len),
            "Raw Frame: " .. tostring(protocol_buffer:bytes()))
    end
end

-- Register the dissector
local udp_port = DissectorTable.get("udp.port")
udp_port:add(22222, hvac_shark_proto)
