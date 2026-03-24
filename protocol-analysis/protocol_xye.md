# Midea XYE Protocol Reference

> **Source Status — Community and Open-Source Only**
> Based on open-source repositories and community forum discussions.
> No official Midea specification is publicly available.
> Uncertainties are flagged explicitly. A discrepancy is only considered resolved after
> independent hardware verification.
>
> Sources: [codeberg.org/xye/xye](https://codeberg.org/xye/xye),
> [esphome-mideaXYE-rs485](https://github.com/wtahler/esphome-mideaXYE-rs485),
> [HA Community – Midea A/C via local XYE](https://community.home-assistant.io/t/midea-a-c-via-local-xye/857679)

For comparison with Midea UART, see [comparison_uart_vs_xye.md](comparison_uart_vs_xye.md).

---

## 0. Source Discrepancies — Known Conflicts Between References

The XYE protocol has no official specification. The three independent sources
disagree on several points. These conflicts are documented here so that
captures can be checked against each interpretation.

### 0.1 Temperature sensor encoding — **Disputed**

Three different offsets are claimed for the same sensor bytes (0x0B–0x0E):

| Source | Formula | Offset | Example: raw 0x50 = |
|--------|---------|--------|---------------------|
| codeberg/xye README | `(raw - 0x30) × 0.5` | 48 (0x30) | 16.0 °C |
| codeberg/xye Erlang emulator (`xye.erl`) | `(raw - 40) / 2` | 40 (0x28) | 20.0 °C |
| esphome-mideaXYE-rs485 | `raw` (no conversion) | none | 80 °F (raw byte = Fahrenheit) |

The README and the Erlang code **in the same repository** disagree: offset 48 vs 40.
The ESPHome implementation treats the raw byte as a Fahrenheit value with no offset
at all — this may be a simplification that happens to work for the author's US-market
unit, or it may indicate a different firmware variant.

**Impact**: A 4-unit offset difference (48 vs 40) means **2 °C** error in decoded
temperatures. Until own captures with known room temperature confirm one formula,
all three must be considered plausible.

**For comparison**: Midea UART uses offset 50 for status response temperatures and
offset 30 for Group 1 (T1/T2). See [comparison_uart_vs_xye.md](comparison_uart_vs_xye.md).

### 0.2 Fan speed encoding — **Disputed**

| Value | codeberg/xye README | codeberg/xye Erlang emulator | esphome-mideaXYE |
|-------|---------------------|------------------------------|------------------|
| 0x80  | Auto                | Auto                         | Auto             |
| 0x01  | High                | High                         | High             |
| 0x02  | Medium              | Medium                       | Medium           |
| 0x03  | Low                 | —                            | Low              |
| 0x04  | —                   | Low                          | —                |

The README says Low = 0x03, but the Erlang emulator encodes Low as 0x04. The ESPHome
implementation agrees with the README (0x03). This could be a bug in the emulator,
or it may reflect different hardware (the emulator was tested with a Midea CCM/01E
and a Mundo Clima unit — different firmware could use different values).

### 0.3 Response frame bytes 27–30 — **Disputed**

| Byte | codeberg/xye README | codeberg/xye Erlang emulator | Our dissector |
|------|---------------------|------------------------------|---------------|
| 0x1B | "????" (0x00)       | `L1` field (unknown purpose) | Unknown       |
| 0x1C | "????" (0x00)       | `L2` field                   | Unknown       |
| 0x1D | CRC (per README)    | `L3` field                   | —             |
| 0x1E | —                   | CRC (per emulator)           | CRC           |
| 0x1F | "prologue" 0x55     | 0x55                         | 0x55          |

The README places CRC at byte 0x0E (likely a copy-paste error from the 16-byte
command table — it shows 0x0E/0x0F for a 32-byte frame). The Erlang emulator places
CRC at byte 30 (0x1E) and adds three unknown fields L1/L2/L3 at bytes 27–29.
Our dissector currently uses byte 30 for CRC (matching the emulator).

### 0.4 Command 0xC4 and 0xC6 — request-response patterns — **Unknown**

The codeberg README documents only 4 commands: 0xC0 (Query), 0xC3 (Set), 0xCC (Lock),
0xCD (Unlock). However:

| Command | Source             | Frame pattern             | Notes |
|---------|--------------------|---------------------------|-------|
| 0xC0    | all three sources  | 16-byte request → 32-byte response | Well documented |
| 0xC3    | all three sources  | 16-byte request → 32-byte response | Well documented |
| 0xC4    | our dissector only | 32-byte frame seen        | Not in codeberg or ESPHome. Our dissector treats it as "Ext.Query" but the payload layout is unknown. May be a **32-byte request** (unlike the standard 16-byte), or a response to an unseen query. |
| 0xC6    | ESPHome + our dissector | 16-byte request → 32-byte response? | ESPHome uses it for "Follow-Me" (sending room temperature). The codeberg Erlang emulator does not handle it. Response structure unknown — may echo 0xC6 or respond with 0xC0. |
| 0xCC    | codeberg           | 16-byte request → 32-byte response | Lock. Emulator responds with `0xC0 | 0x0C = 0xCC` in the response code. |
| 0xCD    | codeberg           | 16-byte request → 32-byte response | Unlock. Emulator responds with `0xC0 | 0x0D = 0xCD`. |

**Open question**: Are there 32-byte *requests* on XYE (not just responses)? The
current framing logic assumes byte[2]=0x80 always means slave→master (32-byte
response). If 0xC4 is a 32-byte master→slave command, this assumption breaks.

### 0.5 Response code construction — **Hypothesis**

The codeberg Erlang emulator constructs response codes as `0xC0 | command_nibble`:
- Query (0xC0) → response 0xC0 (0xC0 | 0x00)
- Set (0xC3) → response 0xC3 (0xC0 | 0x03)
- Lock (0xCC) → response 0xCC (0xC0 | 0x0C)
- Unlock (0xCD) → response 0xCD (0xC0 | 0x0D)

This pattern is consistent but not explicitly stated in any source. If correct,
a 0xC4 request would produce a 0xC4 response, and a 0xC6 request would produce
a 0xC6 response.

---

## 1. Physical Layer

| Property       | Value                                   |
|----------------|-----------------------------------------|
| Interface      | RS-485 differential                     |
| Connector      | 3-terminal: X (A+), Y (B−), E (GND)    |
| Baud rate      | **4800 bps**                            |
| Data format    | 8N1                                     |
| Topology       | Multi-drop bus, up to 64 units          |
| Start byte     | `0xAA`                                  |
| End byte       | `0x55`                                  |
| Frame size     | Fixed: 16 bytes (command) or 32 bytes (response) |

---

## 2. Frame Structure

### 2.1 Master command (16 bytes)

```
Offset  Field             Value / Description
------  -----             -------------------
  0     PREAMBLE          0xAA
  1     COMMAND           0xC0=Query, 0xC3=Set, 0xCC=Lock, 0xCD=Unlock (all sources)
                            0xC4, 0xC6: see §0.4 — not all sources agree on existence/meaning
  2     DEST_ID           Target unit 0x00-0x3F; 0xFF=broadcast
  3     SRC_ID            Master address
  4     DIR_FLAG          0x80 = from master (all sources agree)
  5     SRC_ID_repeat     Same as byte 3
  6-12  PAYLOAD           7 bytes of command data
 13     CMD_CHECK         255 - command_byte (e.g. 0xC0 -> 0x3F)
 14     CRC               Two's complement checksum
 15     EPILOGUE          0x55
```

### 2.2 Slave status response (32 bytes)

```
Offset  Field             Description
------  -----             -----------
  0     PREAMBLE          0xAA
  1     RESPONSE_CODE     Same code as the query command (e.g. 0xC0)
  2     DIR_FLAG          0x80 = slave->master
  3     DEST_ID           Master address
  4     SRC_ID            Unit address
  5     SRC_ID_repeat     Same as byte 4
  6     MARKER            0x30 (fixed)
  7     CAPABILITIES      0x80=extended temp range, 0x10=swing capable
  8     OPERATING_MODE    Current operating mode (see section 4)
  9     FAN_SPEED         Fan speed (see section 5)
 10     SET_TEMP          Target temperature in deg C (direct value)
 11     T1_INDOOR         Offset formula disputed — see §0.1
 12     T2A_COIL_IN       Offset formula disputed — see §0.1
 13     T2B_COIL_OUT      Offset formula disputed — see §0.1
 14     T3_OUTDOOR_COIL   Offset formula disputed — see §0.1
 15     CURRENT           0-99 A (direct value)
 16     FREQUENCY         typically 0xFF
 17     TIMER_START       Bitmask
 18     TIMER_STOP        Bitmask
 19     RUN_STATUS        0x01 = compressor/unit running
 20     MODE_FLAGS        0x02=turbo, 0x01=ECO/sleep, 0x04=swing, 0x88=fan-only
 21     OP_FLAGS          0x04=pump running, 0x80=locked
 22     ERROR_1           Error/protection bitmask
 23     ERROR_2           Error/protection bitmask
 24     ERROR_3           Error/protection bitmask
 25     ERROR_4           Error/protection bitmask
 26     COMM_ERROR        0-2
 27     L1 / UNKNOWN      codeberg Erlang: separate field; README: 0x00 (see §0.3)
 28     L2 / UNKNOWN      codeberg Erlang: separate field; README: 0x00
 29     L3 / UNKNOWN      codeberg Erlang: separate field; README: CRC position (likely error)
 30     CRC               Two's complement checksum (per Erlang emulator + our dissector)
 31     EPILOGUE          0x55
```

---

## 3. Checksum Algorithm

XYE uses a single two's complement sum covering the entire frame, including the `0xAA` preamble and `0x55` epilogue (all bytes except the CRC byte itself):

```
CRC = (255 - (sum_of_all_bytes_except_CRC % 256) + 1) & 0xFF
```

---

## 4. Command Codes

| Code   | Direction      | Name           | Source          | Description                                      |
|--------|----------------|----------------|-----------------|--------------------------------------------------|
| `0xC0` | Master→Slave   | Query          | all three       | 16-byte request for current status               |
| `0xC0` | Slave→Master   | Status response| all three       | 32-byte response with full state                 |
| `0xC3` | Master→Slave   | Set parameters | all three       | 16-byte write of operating parameters            |
| `0xC3` | Slave→Master   | Set ack        | codeberg Erlang | 32-byte response echoing 0xC3 (see §0.5)        |
| `0xC4` | ?              | Extended query | dissector only  | 32-byte frame observed — direction and payload layout unknown (see §0.4) |
| `0xC6` | Master→Slave   | Follow-Me      | ESPHome         | 16-byte send of remote room temperature. Not in codeberg. Response pattern unknown (see §0.4) |
| `0xCC` | Master→Slave   | Lock           | codeberg        | 16-byte lock command, response echoes 0xCC       |
| `0xCD` | Master→Slave   | Unlock         | codeberg        | 16-byte unlock command, response echoes 0xCD     |

---

## 5. Operating Mode Encoding

Byte 0x08 in the slave response (and the corresponding payload byte in Set commands):

| Value  | Mode      |
|--------|-----------|
| `0x00` | Off       |
| `0x80` | Auto      |
| `0x88` | Cool      |
| `0x82` | Dry       |
| `0x84` | Heat      |
| `0x81` | Fan only  |

Bit 7 is always set when the unit is on. Bits [2:0] select the mode.

---

## 6. Fan Speed Encoding

Byte 0x09 in the slave response:

| Value  | Speed  |
|--------|--------|
| `0x80` | Auto   | All sources agree |
| `0x01` | High   | All sources agree |
| `0x02` | Medium | All sources agree |
| `0x03` | Low    | codeberg README + ESPHome — **Disputed**, see §0.2 |
| `0x04` | Low    | codeberg Erlang emulator — **Disputed**, see §0.2 |

---

## 7. Temperature Encoding

### Target temperature
Byte 0x0A: direct integer value in degrees C.

### Measured temperatures (sensor bytes 0x0B-0x0E)
All sensor bytes use an offset formula, but **the offset is disputed** (see §0.1):

```
codeberg README:    temp_c = (raw - 0x30) × 0.5    (offset 48)
codeberg Erlang:    temp_c = (raw - 40) / 2         (offset 40)
ESPHome:            temp_f = raw                     (no conversion, treated as °F)
```

The difference between offset 48 and 40 is **2 °C**. Until verified against
own captures with known room temperature, the offset must be considered uncertain.

| Offset | Sensor                      |
|--------|-----------------------------|
| 0x0B   | T1 — Indoor air temperature |
| 0x0C   | T2A — Coil inlet (evaporator inlet)  |
| 0x0D   | T2B — Coil outlet (evaporator outlet)|
| 0x0E   | T3 — Outdoor coil temperature        |

---

## 8. Status Flags (MODE_FLAGS byte 0x14, OP_FLAGS byte 0x15)

```
byte 0x13 (RUN_STATUS)
  bit 0   = unit running (compressor or fan active)

byte 0x14 (MODE_FLAGS)
  bit 0   = ECO / sleep mode
  bit 1   = Turbo / auxiliary heat
  bit 2   = Swing active

byte 0x15 (OP_FLAGS)
  bit 7   = unit locked (local remote disabled)
  bit 2   = pump running

bytes 0x16-0x19 (ERROR_1-4)
  Various error and protection bitmasks (unit-dependent)
```

---

## 9. Framing: Identifying XYE vs. Midea UART on a Shared Bus

Both XYE and Midea UART start with `0xAA`. Byte 1 unambiguously identifies the protocol because the valid value ranges never overlap:

| Byte 1        | Interpretation               | Protocol     |
|---------------|------------------------------|--------------|
| `0x0D`-`0x27` | LENGTH field (13-39)         | Midea UART   |
| `0xC0`, `0xC3`, `0xC4`, `0xC6`, `0xCC`, `0xCD` | COMMAND byte | XYE |

After identifying XYE, byte 2 determines frame size:

| Byte 2      | Meaning                  | Frame size |
|-------------|--------------------------|------------|
| `0x80`      | DIR_FLAG: slave->master  | 32 bytes   |
| `0x00-0x3F` | DEST_ID: master->slave   | 16 bytes   |

See [comparison_uart_vs_xye.md](comparison_uart_vs_xye.md) for dual-protocol router code.

---

## 10. XYE-Exclusive Features

These are available on XYE and have no equivalent on Midea UART:

- **Multi-unit addressing** — up to 64 units on one bus (DEST_ID / SRC_ID fields)
- **T2A / T2B coil temperatures** — evaporator inlet and outlet (bytes 0x0C / 0x0D)
- **Current draw** — byte 0x0F, direct Ampere value
- **Follow-Me** — room temperature from a remote sensor (cmd `0xC6`)
- **Static pressure control** — for ventilation/duct applications
- **Emergency heat** mode
- **Lock / Unlock** — disable/enable local remote control (`0xCC` / `0xCD`)

---

## 11. 0xCC Commercial AC — XYE Payload in UART Framing? **[Hypothesis]**

Midea device type 0xCC ("Commercial AC") uses the standard Midea UART frame structure
(0xAA + length + device type + msg_type + body + checksum) but its body content
closely mirrors XYE payload encoding. This section documents the byte-level evidence.

> Source: discoveries from mill1000/midea-msmart (Finding 11, `midea-msmart-mill1000.md`).
> The Lua files are cloud-side protocol scripts served via `/v2/luaEncryption/luaGet`.
> All field mappings below are **Hypothesis** — no own 0xCC captures exist.

### 11.1 Constructed demo packets — byte-level comparison

The 0xCC Lua contains complete frame builders. By tracing the code with example
inputs, we can construct full binary packets and compare them against XYE.

**Example scenario:** Set Cool mode, 24 °C, fan Auto, no timers, no special flags.

#### 0xCC Set command (traced from Lua)

The Lua builds a 24-byte body (indices 0-23), then wraps it in a UART frame with
10-byte header (0xAA + length + device type 0xCC + padding + msg_type 0x02):

```
Header (10 bytes):
  [0]  0xAA   preamble
  [1]  0x23   length (10 + 24 + 1 = 35)
  [2]  0xCC   device type
  [3]  0x00   (padding)
  [4]  0x00
  [5]  0x00
  [6]  0x00
  [7]  0x00
  [8]  0x00
  [9]  0x02   msg_type (control request)

Body (24 bytes, starting at frame offset 10):
  body[0]  = 0xC3   ← set command ID
  body[1]  = 0x88   ← power(0x80) | mode_cool(0x08)
  body[2]  = 0x80   ← fan auto
  body[3]  = 0x18   ← 24 °C (direct)
  body[4]  = 0x00   ← openTime/15 (no timer)
  body[5]  = 0x00   ← closeTime/15 (no timer)
  body[6]  = 0x00   ← eco|swing|exhaust|PTC flags (all off)
  body[7]  = 0xFF   ← fixed 0xFF
  body[8]  = 0x00   ← sleep|display|swingLR flags
  body[9]  = 0x00   ← swingLR position
  body[10] = 0x00   ← swingUD position
  body[11] = 0x00   ← temperature decimals
  body[12..21] = 0x00  (unused)
  body[22] = 0x??   ← random byte
  body[23] = 0x??   ← CRC-8/854 over body[0..22]

Tail:
  [34] = checksum   ← two's complement sum over frame[1..33]
```

#### XYE Set command (from codeberg/xye)

```
  [0]  0xAA   PREAMBLE
  [1]  0xC3   COMMAND (Set)
  [2]  0x00   DEST_ID (unit 0)
  [3]  0x00   SRC_ID (master 0)
  [4]  0x80   DIR_FLAG (master→slave)
  [5]  0x00   SRC_ID repeat
  [6]  0x88   Oper mode: Cool (0x80 power | 0x08 cool)
  [7]  0x80   Fan: Auto
  [8]  0x18   Set temp: 24 °C (direct)
  [9]  0x00   Mode flags (no turbo/eco/swing)
  [10] 0x00   Timer start (off)
  [11] 0x00   Timer stop (off)
  [12] 0x00   Unknown
  [13] 0x3C   CMD_CHECK (255 - 0xC3 = 0x3C)
  [14] 0x??   CRC (two's complement sum)
  [15] 0x55   EPILOGUE
```

#### Side-by-side payload alignment

```
                      0xCC body[]      XYE payload[6..12]
                      -----------      ------------------
Command ID:           body[0] = 0xC3   byte[1] = 0xC3      ← SAME value, different position
Power + Mode:         body[1] = 0x88   byte[6] = 0x88      ← IDENTICAL encoding
Fan speed:            body[2] = 0x80   byte[7] = 0x80      ← IDENTICAL (Auto)
Temperature:          body[3] = 0x18   byte[8] = 0x18      ← IDENTICAL
Timer on:             body[4] = 0x00   byte[10]= 0x00      ← same concept, 0xCC divides by 15
Timer off:            body[5] = 0x00   byte[11]= 0x00      ← same concept
Flags:                body[6] = flags  byte[9] = flags      ← similar bits, different position
Fixed 0xFF:           body[7] = 0xFF   —                    ← 0xCC only
Extended flags:       body[8..11]      —                    ← 0xCC only (swing pos, decimals)
```

**Key finding**: The 0xCC body bytes 1-3 (power+mode, fan, temp) are **bit-identical**
to XYE payload bytes 6-8. The same byte values produce the same meaning in both.
The only difference is framing:

- XYE puts the command (0xC3) in the **frame header** (byte 1) and payload starts at byte 6
- 0xCC puts the command in **body[0]** and payload starts at body[1], wrapped in Midea UART framing

### 11.2 Command code comparison

| Function      | XYE byte[1]    | 0xCC body[0]         | Match? |
|---------------|----------------|----------------------|--------|
| Set params    | **`0xC3`**     | **`0xC3`**           | **Identical** |
| Query status  | `0xC0`         | `0x01`               | Different |
| Status resp   | **`0xC0`**     | `0xC3` or `0x01`     | Different |
| Lock          | `0xCC`         | `0xB0`               | Different |

The set command **0xC3 is identical in XYE and 0xCC**. The 0xCC Lua header states
`0xC3 : 86X Controller`, suggesting this is the native command ID for the unit class.

### 11.3 Status response field comparison

```
                      0xCC body[]            XYE response[]
                      -----------            --------------
Command ID:           body[0] = 0xC3/0x01    byte[1] = 0xC0
Power+Mode:           body[1]                byte[8]          ← same encoding (0x80|mode)
Fan:                  body[2]                byte[9]          ← DIFFERENT (bitmask vs ordinal)
Set temp:             body[3]                byte[10]         ← direct °C in both
Indoor temp:          body[4]                byte[11]         ← XYE offset disputed (§0.1), 0xCC unknown
Evap entrance:        body[5]                byte[12] (T2A)   ← BOTH have this sensor
Evap exit:            body[6]                byte[13] (T2B)   ← BOTH have this sensor
Swing UD pos:         body[9]                —                ← 0xCC only
Timer on/off:         body[10..11]           byte[17..18]     ← different encoding
ECO flag:             body[13] bit 0         byte[20] bit 0   ← SAME bit
Swing UD flag:        body[13] bit 2         byte[20] bit 2   ← SAME bit
Exhaust:              body[13] bit 3         —                ← 0xCC only
Error:                body[15]+body[18]      byte[22..25]     ← different layout
```

**T2A/T2B (evaporator in/out)** are present in both XYE and 0xCC but absent in
the UART 0xAC standard status response. This shared sensor model is significant.

### 11.4 Mode encoding: XYE vs 0xCC vs UART 0xAC

| Mode  | XYE (whole byte)   | 0xCC (bits 4:0)     | UART 0xAC (bits 7:5) |
|-------|--------------------|---------------------|-----------------------|
| Auto  | 0x80 (bit7)        | 0x10 (bit4)         | 1 (001)               |
| Cool  | 0x88 (bit7+bit3)   | 0x08 (bit3)         | 2 (010)               |
| Dry   | 0x82 (bit7+bit1)   | 0x02 (bit1)         | 3 (011)               |
| Heat  | 0x84 (bit7+bit2)   | 0x04 (bit2)         | 4 (100)               |
| Fan   | 0x81 (bit7+bit0)   | 0x01 (bit0)         | 5 (101)               |

XYE and 0xCC use the **same bit positions** for mode selection (bits 3:0). XYE adds
bit 7 as a power-on flag in the same byte; 0xCC separates power into bit 7 but uses
bits 4:0 for mode. UART 0xAC uses an entirely different sequential encoding.

### 11.5 Fan speed: three encodings

| Speed  | XYE        | 0xCC bitmask        | UART 0xAC (decimal) |
|--------|------------|---------------------|---------------------|
| Auto   | 0x80       | 0x80                | 102                 |
| High   | 0x01       | 0x10                | 80                  |
| Medium | 0x02       | 0x08                | 60                  |
| Low    | 0x03       | 0x04                | 40                  |

Auto = 0x80 is shared between XYE and 0xCC. Beyond that, XYE uses ordinals (1/2/3)
while 0xCC uses a one-hot bitmask — neither matches UART's percentage-like values.

### 11.6 Interpretation — **Disputed / Open Questions**

Several hypotheses fit the evidence; none are confirmed:

**Hypothesis A — XYE is the ancestor:**
XYE is the oldest Midea inter-unit protocol (RS-485, 4800 baud, fixed frames). When
commercial units gained cloud connectivity, the 0xCC cloud Lua was written as a
XYE↔JSON translator, preserving the 0xC3 command ID and sensor model (T2A/T2B).
UART 0xAC was a later redesign for residential Wi-Fi dongles, which simplified the
encoding and dropped T2A/T2B.

**Hypothesis B — common internal ancestor:**
All three derive from a shared Midea-internal protocol specification. XYE and 0xCC
stayed closer to the original (bitmask modes, T2A/T2B sensors), while UART 0xAC
diverged further (sequential mode encoding, simplified sensor set).

**Hypothesis C — 0xCC is a thin wrapper around XYE:**
The 0xCC cloud Lua translates JSON→XYE-like body→UART frame. The indoor unit's
mainboard may speak XYE internally, and the Wi-Fi module for commercial units wraps
XYE payloads in Midea UART framing. This would explain why the 0xCC body structure
mirrors XYE payload more than it mirrors UART 0xAC body structure.

**What would resolve this:**
- Capture 0xCC UART traffic alongside XYE on the same commercial unit
- Compare whether the 0xCC UART body bytes match XYE payload bytes 1:1
- Check whether `indoorTemperature` in the 0xCC response uses XYE's offset
  or UART 0xAC's offset (50)

---

## References

- XYE reverse engineering: https://codeberg.org/xye/xye
- ESPHome XYE implementation: https://github.com/wtahler/esphome-mideaXYE-rs485
- HA Community XYE thread: https://community.home-assistant.io/t/midea-a-c-via-local-xye/857679
- Discoveries from mill1000/midea-msmart (`midea-msmart-mill1000.md`)
- georgezhao2010/midea_ac_lan — device type definitions (0xC3/0xCC/0xCD/0xCF)
- Midea UART reference: [protocol_uart.md](protocol_uart.md)
- UART vs. XYE comparison: [comparison_uart_vs_xye.md](comparison_uart_vs_xye.md)
