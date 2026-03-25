-- HVAC Shark Dissector — XYE (RS-485) + Midea UART (SmartKey) protocols
-- Protocol auto-detection via byte 1 of protocol data:
--   XYE commands (0xC0-0xCD range) → XYE decoder
--   UART length  (0x0D-0x40 range) → UART decoder
-- See: PI HVAC databridge docs/protocol_vs_xye.md section 11

hvac_shark_proto = Proto("HVAC_Shark", "HVAC Shark Protocol")

-- ── Proto fields ─────────────────────────────────────────────────────────────
local f = hvac_shark_proto.fields
-- HVAC_shark header
f.start_sequence  = ProtoField.string("hvac_shark.start_sequence",  "Start Sequence")
f.manufacturer    = ProtoField.uint8 ("hvac_shark.manufacturer",    "Manufacturer")
f.bus_type        = ProtoField.uint8 ("hvac_shark.bus_type",        "Bus Type")
f.header_version  = ProtoField.uint8 ("hvac_shark.header_version",  "Header Version")
f.logic_channel   = ProtoField.string("hvac_shark.logic_channel",   "Logic Channel")
f.circuit_board   = ProtoField.string("hvac_shark.circuit_board",   "Circuit Board")
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
    else return string.format("Unknown (0x%02X)", oper_mode) end
end


-- ── UART lookup tables ───────────────────────────────────────────────────────

local UART_MSG_TYPES = {
    [0x02] = "Command",  [0x03] = "Response/Notification",
    [0x04] = "Network",  [0x05] = "Handshake/ACK",
    [0x07] = "Device ID", [0x63] = "Network Status Request",
}

local UART_COMMAND_IDS = {
    [0x40] = "Set Status",   [0x41] = "Query",
    [0x93] = "Ext Status",
    [0xB5] = "Capabilities", [0xC0] = "Status Response",
    [0xC1] = "C1 Response",
}

local function getUartModeString(mode_bits)
    if mode_bits == 1 then return "Auto"
    elseif mode_bits == 2 then return "Cool"
    elseif mode_bits == 3 then return "Dry"
    elseif mode_bits == 4 then return "Heat"
    elseif mode_bits == 5 then return "Fan Only"
    else return string.format("Unknown (%d)", mode_bits) end
end

local function getUartFanString(fan)
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

local function getUartSwingString(nibble)
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

local function decode_uart_c0_status(body_tree, buf, body_off, body_len)
    -- C0 Status Response (body[0] = 0xC0)
    -- Reference: PI HVAC databridge docs/protocol_uart.md section 6

    body_tree:add(buf(body_off + 0, 1), "Command ID: 0xC0 (Status Response)")

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
        getUartModeString(mode_bits), set_temp))

    -- body[3]: fan speed
    local fan = buf(body_off + 3, 1):uint()
    body_tree:add(buf(body_off + 3, 1), string.format("Fan Speed: %d (%s)",
        fan, getUartFanString(fan)))

    -- body[4-6]: timer fields
    body_tree:add(buf(body_off + 4, 3), "Timer bytes: " ..
        tostring(buf(body_off + 4, 3):bytes()))

    -- body[7]: swing mode
    local swing_val = bit.band(buf(body_off + 7, 1):uint(), 0x0F)
    body_tree:add(buf(body_off + 7, 1), string.format("Swing: %s",
        getUartSwingString(swing_val)))

    -- body[8]: cosy sleep, turbo (location 2), save
    local b8 = buf(body_off + 8, 1):uint()
    local turbo2 = bit.band(b8, 0x20) ~= 0
    body_tree:add(buf(body_off + 8, 1), string.format("Cosy Sleep: %d, Save: %s, Turbo2: %s",
        bit.band(b8, 0x03),
        bit.band(b8, 0x08) ~= 0 and "yes" or "no",
        turbo2 and "yes" or "no"))

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
        "ECO: %s, ChildSleep: %s, DryClean: %s, PTC: %s   [NOTE: ECO bit controversial - bit4=dudanov/midea-local, bit7=set-cmd]",
        eco_str,
        bit.band(b9, 0x01) ~= 0 and "yes" or "no",
        bit.band(b9, 0x04) ~= 0 and "yes" or "no",
        bit.band(b9, 0x08) ~= 0 and "yes" or "no"))

    -- body[10]: sleep, turbo (primary), temp unit
    local b10 = buf(body_off + 10, 1):uint()
    local sleep = bit.band(b10, 0x01) ~= 0
    local turbo = bit.band(b10, 0x02) ~= 0
    local temp_unit = bit.band(b10, 0x04) ~= 0 and "F" or "C"
    body_tree:add(buf(body_off + 10, 1), string.format(
        "Sleep: %s, Turbo: %s, Temp Unit: %s",
        sleep and "yes" or "no", turbo and "yes" or "no", temp_unit))

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

    -- body[14]: display state
    -- *** CONTROVERSY: display ON condition ***
    -- This doc: bits[6:4] == 0x7 → ON
    -- midea-local: bits[6:4] != 0x7 → ON (inverted!) + gated on power
    if body_len > 14 then
        local b14 = buf(body_off + 14, 1):uint()
        local disp_bits = bit.band(bit.rshift(b14, 4), 0x07)
        body_tree:add(buf(body_off + 14, 1), string.format(
            "Display bits: 0x%X (%s=ON, %s=ON)   [CONTROVERSIAL: interpretation inverted between sources]",
            disp_bits,
            disp_bits == 0x07 and "this-doc" or "midea-local",
            disp_bits ~= 0x07 and "this-doc=OFF" or "midea-local=OFF"))
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
    -- All field labels are Hypothesis unless noted.

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

    -- body[10]: T1 temperature (indoor coil) — offset 30
    if n >= 7 then
        local raw = buf(d + 6, 1):uint()
        local t1 = raw >= 30 and (raw - 30) / 2.0 or (30 - raw) / -2.0
        body_tree:add(buf(d + 6, 1), string.format(
            "T1 indoor coil: %.1f °C (raw %d, offset 30)  [Hypothesis]",
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
    if n >= 9 then
        local raw = buf(d + 8, 1):uint()
        local t3 = raw >= 50 and (raw - 50) / 2.0 or (50 - raw) / -2.0
        body_tree:add(buf(d + 8, 1), string.format(
            "T3 outdoor coil: %.1f °C (raw %d, offset 50)  [Hypothesis]",
            t3, raw))
    end

    -- body[13]: T4 temperature (outdoor ambient) — offset 50
    if n >= 10 then
        local raw = buf(d + 9, 1):uint()
        local t4 = raw >= 50 and (raw - 50) / 2.0 or (50 - raw) / -2.0
        body_tree:add(buf(d + 9, 1), string.format(
            "T4 outdoor ambient: %.1f °C (raw %d, offset 50)  [Hypothesis]",
            t4, raw))
    end

    -- body[14]: discharge pipe temperature (Tp) — lookup table, show raw
    if n >= 11 then
        body_tree:add(buf(d + 10, 1), string.format(
            "Tp discharge temp: %d (raw, needs lookup table)  [Hypothesis]",
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
    -- Source: mill1000/midea-msmart (see midea-msmart-mill1000.md, Finding 11)
    -- All fields: Hypothesis.

    local d = body_off + 4
    local n = body_len - 4

    local function bcd(byte)
        return 10 * bit.rshift(bit.band(byte, 0xF0), 4) + bit.band(byte, 0x0F)
    end

    -- body[4..7]: total power consumed (BCD kWh)
    if n >= 4 then
        local val = bcd(buf(d+0,1):uint()) * 10000 + bcd(buf(d+1,1):uint()) * 100
                  + bcd(buf(d+2,1):uint()) + bcd(buf(d+3,1):uint()) / 100.0
        body_tree:add(buf(d + 0, 4), string.format(
            "Total power consumed: %.2f kWh (BCD)  [Hypothesis]", val))
    end

    -- body[8..11]: total running power (BCD kWh)
    if n >= 8 then
        local val = bcd(buf(d+4,1):uint()) * 10000 + bcd(buf(d+5,1):uint()) * 100
                  + bcd(buf(d+6,1):uint()) + bcd(buf(d+7,1):uint()) / 100.0
        body_tree:add(buf(d + 4, 4), string.format(
            "Total running power: %.2f kWh (BCD)  [Hypothesis]", val))
    end

    -- body[12..15]: current run power (BCD kWh)
    if n >= 12 then
        local val = bcd(buf(d+8,1):uint()) * 10000 + bcd(buf(d+9,1):uint()) * 100
                  + bcd(buf(d+10,1):uint()) + bcd(buf(d+11,1):uint()) / 100.0
        body_tree:add(buf(d + 8, 4), string.format(
            "Current run power: %.2f kWh (BCD)  [Hypothesis]", val))
    end

    -- body[16..18]: real-time power (BCD kW)
    if n >= 15 then
        local val = bcd(buf(d+12,1):uint()) + bcd(buf(d+13,1):uint()) / 100.0
                  + bcd(buf(d+14,1):uint()) / 10000.0
        body_tree:add(buf(d + 12, 3), string.format(
            "Real-time power: %.4f kW (BCD)  [Hypothesis]", val))
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
    if body_len > 26 then
        body_tree:add(buf(body_off + 26, 1), string.format(
            "Indoor fault byte 1: 0x%02X  b0=env-sensor b1=pipe-sensor b2=E2 b3=DC-fan-stall b4=indoor-outdoor-comm b5=smart-eye b6=display-E2 b7=RF-module  [Hypothesis]",
            buf(body_off + 26, 1):uint()))
    end
    if body_len > 32 then
        body_tree:add(buf(body_off + 32, 1), string.format(
            "Load state: 0x%02X  b0=defrost b1=aux-heat b6=indoor-fan-run b7=purifier  [Hypothesis]",
            buf(body_off + 32, 1):uint()))
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
    if body_len > 11 then
        body_tree:add(buf(body_off + 11, 1), string.format(
            "Current humidity: %d %%  [Hypothesis]", buf(body_off + 11, 1):uint()))
    end
    if body_len > 12 then
        body_tree:add(buf(body_off + 12, 1), string.format(
            "Temp setpoint (compensated): %.1f °C  [Hypothesis: (raw-30)×0.5]",
            (buf(body_off + 12, 1):uint() - 30) * 0.5))
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
            "Outdoor target compressor frequency: %d  [Hypothesis]",
            buf(body_off + 57, 1):uint()))
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

    -- body[1]: power + beep
    local b1 = buf(body_off + 1, 1):uint()
    body_tree:add(buf(body_off + 1, 1), string.format("Power: %s, Beep: %s",
        bit.band(b1, 0x01) ~= 0 and "ON" or "OFF",
        bit.band(b1, 0x40) ~= 0 and "yes" or "no"))

    -- body[2]: mode + temp
    local b2 = buf(body_off + 2, 1):uint()
    local mode_bits = bit.rshift(bit.band(b2, 0xE0), 5)
    local temp_int = bit.band(b2, 0x0F) + 16
    local temp_half = bit.band(b2, 0x10) ~= 0
    body_tree:add(buf(body_off + 2, 1), string.format("Mode: %s, Temp: %.1f C",
        getUartModeString(mode_bits), temp_int + (temp_half and 0.5 or 0)))

    -- body[3]: fan
    local fan = buf(body_off + 3, 1):uint()
    body_tree:add(buf(body_off + 3, 1), string.format("Fan: %d (%s)",
        fan, getUartFanString(fan)))

    -- body[7]: swing
    if body_len > 7 then
        local swing = bit.band(buf(body_off + 7, 1):uint(), 0x0F)
        body_tree:add(buf(body_off + 7, 1), string.format("Swing: %s",
            getUartSwingString(swing)))
    end

    -- body[9]: eco (SET uses bit 7 — this is correct for set direction!)
    if body_len > 9 then
        local b9 = buf(body_off + 9, 1):uint()
        body_tree:add(buf(body_off + 9, 1), string.format("ECO (set): %s",
            bit.band(b9, 0x80) ~= 0 and "yes" or "no"))
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
    elseif sub == 0x21 then
        body_tree:add(buf(body_off + 1, 1), "body[1] = 0x21 (Dev-param query sub-command)")
        if b2 == 0x01 then
            local group = bit.band(b3, 0x0F)
            local page_name = group_page_names[b3] or string.format("Group %d", group)
            body_tree:add(buf(body_off + 2, 1), "body[2] = 0x01 (Group page query)")
            body_tree:add(buf(body_off + 3, 1), string.format(
                "body[3] = 0x%02X → group = body[3] & 0x0F = %d → %s",
                b3, group, page_name))
        else
            local opt = body_len >= 5 and buf(body_off + 4, 1):uint() or 0
            body_tree:add(buf(body_off + 2, 1), string.format(
                "body[2] = 0x%02X (extended query)", b2))
            body_tree:add(buf(body_off + 3, 1), string.format(
                "body[3] = 0x%02X", b3))
            if body_len >= 5 then
                body_tree:add(buf(body_off + 4, 1), string.format(
                    "body[4] = 0x%02X (optCommand)", opt))
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
    body_tree:add(buf(body_off, 1), "Command ID: 0x93 (Ext Status — KJR/R/T bus)")
    body_tree:add(buf(body_off + 1, math.min(3, body_len - 1)), string.format(
        "Params: 0x%02X 0x%02X 0x%02X [meaning unknown]", b1, b2, b3))
    if body_len > 4 then
        body_tree:add(buf(body_off + 4, body_len - 4),
            "Payload: " .. tostring(buf(body_off + 4, body_len - 4):bytes()))
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

    if version == 0x00 then
        subtree:add(f.header_version, udp_payload_buffer(12, 1)):append_text(" (Legacy)")
    elseif version == 0x01 then
        subtree:add(f.header_version, udp_payload_buffer(12, 1)):append_text(" (Extended)")
        local pos = 13
        -- logicChannel
        local ch_len = udp_payload_buffer(pos, 1):uint()
        pos = pos + 1
        if ch_len > 0 then
            subtree:add(f.logic_channel, udp_payload_buffer(pos, ch_len))
            pinfo.cols.info:append(" [" .. udp_payload_buffer(pos, ch_len):string() .. "]")
            pos = pos + ch_len
        end
        -- circuitBoard
        local board_len = udp_payload_buffer(pos, 1):uint()
        pos = pos + 1
        if board_len > 0 then
            subtree:add(f.circuit_board, udp_payload_buffer(pos, board_len))
            pos = pos + board_len
        end
        -- comment
        local comment_len = udp_payload_buffer(pos, 1):uint()
        pos = pos + 1
        if comment_len > 0 then
            subtree:add(f.channel_comment, udp_payload_buffer(pos, comment_len))
            pos = pos + comment_len
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
            local msg_type_str = UART_MSG_TYPES[msg_type] or "Unknown"
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
                local cmd_id = udp_payload_buffer(body_off, 1):uint()
                local cmd_str = UART_COMMAND_IDS[cmd_id] or string.format("Unknown (0x%02X)", cmd_id)
                pinfo.cols.info:append(" " .. cmd_str)

                if cmd_id == 0xC0 then
                    decode_uart_c0_status(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0xC1 then
                    decode_uart_c1(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0x40 then
                    decode_uart_40_set(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0x41 then
                    decode_uart_41_query(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0x93 then
                    decode_uart_93(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0xB5 then
                    body_tree:add(udp_payload_buffer(body_off, 1), "Command ID: 0xB5 (Capabilities Query/Response)")
                    body_tree:add(udp_payload_buffer(body_off + 1, body_len - 1),
                        "Capability Data: " .. tostring(udp_payload_buffer(body_off + 1, body_len - 1):bytes()))
                else
                    body_tree:add(udp_payload_buffer(body_off, body_len),
                        "Raw Body: " .. tostring(udp_payload_buffer(body_off, body_len):bytes()))
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
            pinfo.cols.info:append(string.format("S->M 0x%02X %s", command_code, command_name))
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
                local c4_tp = protocol_buffer(19, 1):uint()
                data_subtree:add(pbuf(19, 1), string.format("0x13 Tp (compressor): 0x%02X (%.1f C)", c4_tp, (c4_tp - 40) / 2.0))
                data_subtree:add(pbuf(20, 1), string.format("0x14 Unknown: 0x%02X (%.1f C if sensor)", protocol_buffer(20, 1):uint(), (protocol_buffer(20, 1):uint() - 40) / 2.0))
                local c4_t4 = protocol_buffer(21, 1):uint()
                data_subtree:add(pbuf(21, 1), string.format("0x15 T4 (outdoor ambient): 0x%02X (%.1f C)", c4_t4, (c4_t4 - 40) / 2.0))
                local c4_b22 = protocol_buffer(22, 1):uint()
                data_subtree:add(pbuf(22, 1), string.format("0x16 Coil track: 0x%02X (%.1f C)", c4_b22, (c4_b22 - 40) / 2.0))
                for i = 23, 29 do
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
        subtree:add(f.protocol_type, "Display-Mainboard Internal Bus")
        pinfo.cols.info:prepend("DISP-MB ")

        local frame_tree = subtree:add(pbuf(0, proto_len), "Internal Bus Frame")

        frame_tree:add(pbuf(0, 1), string.format("Start: 0x%02X", protocol_buffer(0, 1):uint()))
        frame_tree:add(pbuf(1, 1), string.format("Device Type: 0x%02X", byte1))

        if proto_len >= 3 then
            local pkt_len = protocol_buffer(2, 1):uint()
            local len_match = (pkt_len == proto_len)
            frame_tree:add(pbuf(2, 1), string.format("Packet Length: %d %s",
                pkt_len, len_match and "(matches frame)" or
                string.format("(frame is %d bytes)", proto_len)))

            -- Dump remaining bytes with offset labels
            for i = 3, proto_len - 1 do
                frame_tree:add(pbuf(i, 1), string.format("0x%02X: 0x%02X", i, protocol_buffer(i, 1):uint()))
            end
        end

        subtree:add(pbuf(0, proto_len), "Raw Frame: " .. tostring(protocol_buffer:bytes()))

    elseif is_rt then
        -- ══════════════════════════════════════════════════════════════════
        -- ── BIDIRECTIONAL EXTENSION BOARD (R/T / HA/HB) BUS ──────────────
        -- ══════════════════════════════════════════════════════════════════
        subtree:add(f.protocol_type, "Extension Board R/T (HA/HB)")

        local start_byte = protocol_buffer(0, 1):uint()
        local is_request = (start_byte == 0xAA)
        pinfo.cols.info:prepend(is_request and "R/T-REQ " or "R/T-RSP ")

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
            local msg_type_str = UART_MSG_TYPES[msg_type] or "Unknown"
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
                local cmd_str = UART_COMMAND_IDS[cmd_id] or string.format("Unknown (0x%02X)", cmd_id)
                pinfo.cols.info:append(" " .. cmd_str)

                -- Reuse UART body decoders
                if cmd_id == 0xC0 then
                    decode_uart_c0_status(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0xC1 then
                    decode_uart_c1(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0x40 then
                    decode_uart_40_set(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0x41 then
                    decode_uart_41_query(body_tree, udp_payload_buffer, body_off, body_len)
                elseif cmd_id == 0x93 then
                    decode_uart_93(body_tree, udp_payload_buffer, body_off, body_len)
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
