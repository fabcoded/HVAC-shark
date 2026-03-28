# Midea UART vs XYE — Comparison and Correlation Analysis

> **Source Status — Community, Open-Source, and Own Hardware Observations**
> Based on open-source repositories, community forum discussions, and own hardware captures
> from the `HVAC-shark-dumps` repository. No official Midea specification is publicly available.
> Uncertainties are flagged explicitly. A discrepancy is only considered resolved after
> independent hardware verification.

See individual protocol reference documents for full frame layouts and checksum algorithms:
- [protocol_uart.md](protocol_uart.md) — Midea UART (SmartKey / Wi-Fi dongle interface)
- [protocol_xye.md](protocol_xye.md) — XYE (RS-485 central controller bus)

XYE sources: [codeberg.org/xye/xye](https://codeberg.org/xye/xye), [esphome-mideaXYE-rs485](https://github.com/wtahler/esphome-mideaXYE-rs485), [HA Community – Midea A/C via local XYE](https://community.home-assistant.io/t/midea-a-c-via-local-xye/857679)

---

## 1. Overview: Two Different Interfaces

Midea air conditioners expose at least two serial interfaces with distinct protocols:

| Property               | **Midea UART** (SmartKey)               | **XYE Protocol** (RS-485 bus)           |
|------------------------|------------------------------------------|-----------------------------------------|
| Purpose                | Wi-Fi dongle / local control (1:1)      | Central controller (CCM), up to 64 units |
| Physical layer         | 5 V TTL UART                            | RS-485 differential                     |
| Connector              | USB-style or 5-pin JST                  | 3-terminal: X (A), Y (B), E (GND)      |
| Baud rate              | **9600 bps**                            | **4800 bps**                            |
| Data format            | 8N1                                     | 8N1                                     |
| Topology               | Point-to-point                          | Multi-drop bus                          |
| Start byte             | `0xAA`                                  | `0xAA`                                  |
| End byte               | None                                    | `0x55`                                  |
| Frame size             | Variable (typically 34–36 bytes)        | Fixed: 16 (cmd) or 32 (response) bytes  |
| Integrity              | CRC-8/854 + additive checksum           | Two's complement sum only               |

---

## 2. Checksum Algorithm Comparison

### Midea UART — two integrity fields

**CRC-8/854** (over body bytes, lookup table) + **additive checksum** (last byte):
```python
checksum = (256 - sum(frame[1:-1])) & 0xFF
```

### XYE — one checksum (two's complement sum)

```
CRC = (255 - (sum_of_all_bytes_except_CRC % 256) + 1) & 0xFF
```
Covers the entire frame including `0xAA` preamble and `0x55` epilogue.

**Difference:** Midea UART uses a proper polynomial CRC-8 over the body plus an additive
checksum on the full frame. XYE uses only a simpler two's complement sum over the whole frame.

---

## 3. Command Code Comparison

| Function              | Midea UART (body[0])  | XYE (byte 1)    | Correlation                   |
|-----------------------|-----------------------|-----------------|-------------------------------|
| Query status          | `0x41`                | `0xC0`          | Same semantics, different codes |
| Set parameters        | `0x40`                | `0xC3`          | Same semantics, different codes |
| Status response       | **`0xC0`**            | **`0xC0`**      | ⭐ **Identical code!**         |
| Extended query        | `0xB5` (capabilities) | `0xC4`          | Similar concept               |
| Extended set          | —                     | `0xC6` (Follow-Me) | No UART equivalent         |
| Lock / Unlock unit    | —                     | `0xCC` / `0xCD` | No UART equivalent            |
| Power consumption     | `0x41` sub `0x21` → `0xC1` response | — | No XYE equivalent       |
| Capabilities query    | `0xB5`                | —               | UART only                     |
| Network status        | MSG_TYPE `0x63`       | —               | UART/dongle only              |

---

## 4. Field Correlation: Operating Modes

### Midea UART — body[2] bits [7:5]:
```
1 = Auto, 2 = Cool, 3 = Dry, 4 = Heat, 5 = Fan only
```

### XYE — response byte 0x08 / payload byte 0x06:
```
0x80 = Auto, 0x88 = Cool, 0x82 = Dry, 0x84 = Heat, 0x81 = Fan only, 0x00 = Off
```

**Analysis:** XYE always sets bit 7 (except Off) and uses bits [2:0] for the mode —
conceptually similar but numerically incompatible. The XYE bit pattern `0x88 = Cool`
(`0b10001000`) does not match Midea UART `mode=2` (`0b010` in bits [7:5]).

---

## 5. Field Correlation: Fan Speed

### Midea UART — body[3]:
```
102 = Auto, 100 = Turbo, 80 = High, 60 = Medium, 40 = Low, 20 = Silent
```

### XYE — response byte 0x09:
```
0x80 = Auto, 0x01 = High, 0x02 = Medium, 0x03 = Low
```

**Analysis:** Completely different encoding. UART values are proportional percentages
(40 = 40%), XYE uses discrete index values with a different bit pattern.

---

## 6. Field Correlation: Temperatures

### Target temperature

| Protocol     | Encoding                                              |
|--------------|-------------------------------------------------------|
| Midea UART   | body[2] bits [3:0] = temp − 16 (bit 4 = +0.5 °C flag) |
| XYE response | byte 0x0A = direct °C value                           |

### Measured temperatures (sensors)

| Sensor            | Midea UART              | XYE                          |
|-------------------|-------------------------|------------------------------|
| Indoor air (T1)   | body[11]: (val−50) / 2  | byte 0x0B: (raw−0x30) × 0.5  |
| Coil inlet (T2A)  | —                       | byte 0x0C                    |
| Coil outlet (T2B) | —                       | byte 0x0D                    |
| Outdoor coil (T3) | body[12]: (val−50) / 2  | byte 0x0E                    |
| Outdoor air (T4)  | — (extended response only) | byte in 0xC4 response     |

**Analysis:** Both protocols use an offset mechanism for temperatures, but different offsets:
- UART: `offset=50`, `scale=0.5` → range −25 °C to +102.5 °C
- XYE:  `offset=0x30=48`, `scale=0.5` → range −24 °C to +103.5 °C

The offsets (50 vs. 48) are **nearly identical** — strong indicator of shared origin.

---

## 7. Field Correlation: Status Flags

### Midea UART — C0 response:
```
body[10] bit 1  = Turbo
body[9]  bit 4  = Eco mode
body[10] bit 0  = Sleep mode
body[7]  bits [3:0] = Swing mode (0x03=H, 0x0C=V, 0x0F=both)
body[1]  bit 0  = Power ON
body[1]  bit 7  = Error active
body[16]        = Error code (0–33)
```

### XYE — slave response:
```
byte 0x14 bit 1 = Turbo / aux heat
byte 0x14 bit 0 = ECO / sleep
byte 0x14 bit 2 = Swing active
byte 0x13 bit 0 = RUN_STATUS (running)
byte 0x15 bit 7 = Locked
byte 0x16-0x19  = Error/protection bitmasks
```

**Analysis:** Same semantic concepts (turbo, ECO, swing, error) but different byte
positions and bitmasks.

---

## 8. Significant Similarities (Evidence of Common Origin)

| Feature                      | Finding                                                              |
|------------------------------|----------------------------------------------------------------------|
| Start byte `0xAA`            | **Identical** in both protocols                                      |
| Status response code `0xC0`  | **Identical** — UART body[0]=`0xC0`, XYE command=`0xC0`            |
| Temperature offset principle | UART: offset 50; XYE: offset 48 — nearly identical                  |
| Feature set                  | Same concepts: mode, fan, temp, swing, turbo, ECO, sleep, error code |

**Hypothesis:** Midea UART and XYE share the same internal origin (Midea internal protocol
family). The `0xC0` status response pattern and `0xAA` start byte are most likely deliberately
kept consistent. The UART SmartKey protocol is probably an evolution that:
1. Was made point-to-point capable (no address field)
2. Gained extended features (capabilities `0xB5`, power metering `0xC1`)
3. Received stronger integrity protection (CRC-8 + checksum instead of checksum only)

---

## 9. What Each Protocol Offers Exclusively

### XYE only:
- **Multi-unit addressing** (up to 64 units on one bus)
- **T2A / T2B** heat exchanger temperatures (evaporator inlet / outlet)
- **Current draw** (byte 0x0F, direct Ampere value)
- **Follow-Me** (room temperature from remote sensor, cmd `0xC6`)
- **Static pressure** control (ventilation applications)
- **Emergency heat** mode
- **Lock / Unlock** (`0xCC` / `0xCD`)

### Midea UART only:
- **Capabilities query** (`0xB5`) — structured enumeration of supported features
- **Power consumption** (kWh, BCD-encoded in `0xC1` response)
- **Network status protocol** (MSG_TYPE `0x63`, `0x04`) for dongle communication
- **Device identification** (MSG_TYPE `0x07`)
- **Humidity setpoint** (body[19])
- **Frost protection mode** (body[21] bit 7)
- **Silky Cool / PMV mode** — comfort-optimized control
- **Error codes** (0–33, explicit in body[16])

---

## 10. Frame Disambiguation and Protocol Router

### 10.1 Identifying the protocol from byte 1

Both protocols start with `0xAA`. After that, byte 1 unambiguously identifies the protocol
because the valid value ranges **never overlap**:

| Byte 1 value | Meaning | Protocol |
|---|---|---|
| `0x0D`–`0x40` (13–64) | LENGTH field (variable frame size) | **Midea UART** |
| `0xC0`, `0xC3`, `0xC4`, `0xC6`, `0xCC`, `0xCD` (192–205) | COMMAND byte (fixed frame size) | **XYE** |

A Midea UART length of `0xC0` would imply a 193-byte frame — no known UART command comes
close to that size. In practice UART frames are 13–39 bytes (`0x0D`–`0x27`).

### 10.2 Determining frame length after identification

**Midea UART (dynamic length):**
```
total_bytes = frame[1] + 1
```

**XYE (static length) — two sub-cases decided by byte 2:**

| Byte 2 value | Meaning | Frame size |
|---|---|---|
| `0x80` | Direction flag: slave→master | **32 bytes** |
| `0x00`–`0x3F` | DEST_ID: master→slave command | **16 bytes** |

### 10.3 Complete framing logic for a dual-protocol router

```python
def read_frame(stream) -> tuple[str, bytes]:
    start = stream.read(1)
    assert start[0] == 0xAA

    b1 = stream.read(1)[0]

    if b1 in (0xC0, 0xC3, 0xC4, 0xC6, 0xCC, 0xCD):
        # XYE packet — read byte 2 to determine length
        b2 = stream.read(1)[0]
        total = 32 if b2 == 0x80 else 16
        rest = stream.read(total - 3)        # 3 bytes already consumed
        return ("XYE", bytes([0xAA, b1, b2]) + rest)
    else:
        # Midea UART — b1 is the LENGTH field
        rest = stream.read(b1 - 1)           # LENGTH counts from byte 1 onward
        return ("UART", bytes([0xAA, b1]) + rest)
```

No lookahead needed. At most 3 bytes are consumed before the total frame length is known.

### 10.4 Semantic translation table

A router can parse both streams robustly, but cannot simply forward packets from one
protocol to the other. Each field requires translation:

| Field | UART encoding | XYE encoding | Translatable? |
|---|---|---|---|
| Mode | bits [7:5] of body[2]; `2`=Cool, `4`=Heat | byte 0x08; `0x88`=Cool, `0x84`=Heat | ✅ Yes, lookup table |
| Fan speed | `102`=Auto, `80`=High, `60`=Med, `40`=Low | `0x80`=Auto, `0x01`=High, `0x02`=Med, `0x03`=Low | ✅ Yes, lookup table |
| Set temperature | body[2] bits[3:0] = temp−16 (+ bit 4 for +0.5°C) | byte 0x0A = direct °C | ✅ Yes, arithmetic |
| Indoor temp | body[11]: `(val−50) / 2` | byte 0x0B: `(raw−0x30) × 0.5` | ✅ Yes (1°C delta from offset difference — verify on hardware) |
| Swing | body[7] bits[3:0]; `0x03`=H, `0x0C`=V, `0x0F`=both | byte 0x14 bit 2 (on/off only) | ⚠️ Lossy (XYE has no H/V distinction) |
| Turbo | body[10] bit 1 | byte 0x14 bit 1 | ✅ Yes, 1:1 bit |
| ECO / sleep | body[9] bit 4 / body[10] bit 0 | byte 0x14 bit 0 (combined) | ⚠️ Lossy (XYE merges ECO+sleep into one bit) |
| Error code | body[16], numeric 0–33 | bytes 0x16–0x19, bitmask | ⚠️ No direct mapping |
| Unit address | None (point-to-point) | bytes 2–5 | ❌ Must supply fixed address for XYE direction |
| Power consumption | `0xC1` response, BCD kWh | Not available | ❌ No XYE equivalent |
| Capabilities | `0xB5` response, structured | Not available | ❌ No XYE equivalent |
| T2A / T2B coil temps | Not available | bytes 0x0C / 0x0D | ❌ No UART equivalent |
| Current draw | Not available | byte 0x0F | ❌ No UART equivalent |

### 10.5 Architectural conclusion

A **bidirectional translator** is feasible for the core control fields (power, mode,
temperature, fan speed, turbo). Edge cases:

- **Swing**: XYE only knows on/off, not horizontal vs. vertical.
- **ECO vs. Sleep**: XYE merges both into one flag — round-trip UART→XYE→UART loses the distinction.
- **Temperature offset discrepancy**: The 2-unit difference (offset 50 vs. 48 = 1°C delta in sensor encoding) should be verified against real hardware before building a translator.
- **XYE addressing**: Any frame sent onto the XYE bus requires a unit address (bytes 2–5). The translator must inject a configured address since the UART side carries none.

---

## 11. Summary

XYE and Midea UART are **two different protocols** on **two different physical interfaces**
of the same hardware platform. They run **in parallel** and are **not compatible** or interchangeable.

The Midea UART protocol communicates via the SmartKey/dongle port (TTL, 9600 bps) and is the
correct protocol for direct 1:1 control. XYE is only relevant for multi-unit RS-485 bus
installations (e.g. VRF with a central controller).

---

## References

- [protocol_uart.md](protocol_uart.md) — Midea UART reference (this project)
- [protocol_xye.md](protocol_xye.md) — XYE protocol reference (this project)
- XYE reverse engineering: https://codeberg.org/xye/xye
- ESPHome XYE: https://github.com/wtahler/esphome-mideaXYE-rs485
- HA Community XYE: https://community.home-assistant.io/t/midea-a-c-via-local-xye/857679
- dudanov/MideaUART: https://github.com/dudanov/MideaUART
- reneklootwijk/node-mideahvac: https://github.com/reneklootwijk/node-mideahvac
- Own hardware captures: HVAC-shark-dumps repository
