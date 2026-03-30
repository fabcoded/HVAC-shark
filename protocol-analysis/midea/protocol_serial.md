# Midea HVAC Serial Protocol — Command Reference

---

## 1. Scope

This document defines the **serial protocol** — the application-level command set
used between controllers and appliances in Midea HVAC systems. It covers message
types, command bodies, response formats, notifications, and initialization sequences.

The serial protocol is **transport-agnostic**: the same command bodies are carried
by multiple transport framings:

| Transport | Framing Document | Physical Path |
|-----------|-----------------|---------------|
| **UART** | [protocol_uart.md](protocol_uart.md) | Wi-Fi dongle ↔ mainboard (CN3) |
| **R/T (Adapterboard for XYE or HA/HB)** | [protocol_rt.md](protocol_rt.md) | Display board ↔ extension board (CN1 R/T pin) |

Each transport wraps the serial protocol body in its own header and integrity
bytes. The body payload (msg_type + body bytes) is byte-for-byte identical
regardless of transport.

### 1.1 Hardware Under Test

| Property | Value |
|----------|-------|
| Unit | Midea XtremeSaveBlue (Q11 platform) |
| Indoor model | MSAGBU-09HRFN8-QRD0GW |
| Capture tool | HVAC-shark ESP32 RS-485 sniffer (passive, receive-only) |
| Own captures | `HVAC-shark-dumps` repository (Sessions 1-9) |

### 1.2 Confidence Labels

| Label | Meaning |
|-------|---------|
| **Confirmed** | Multiple independent sources agree AND own captures validate |
| **Consistent** | One source + own captures agree, or 2+ sources agree without own data |
| **Hypothesis** | Single source only, no own validation |
| **Disputed** | Sources disagree with each other or with own captures |

### 1.3 Sources

| Source | Language | Coverage |
|--------|----------|----------|
| `dudanov/MideaUART` | C++ / Arduino | High |
| `chemelli74/midea-local` | Python | High |
| `reneklootwijk/node-mideahvac` | JavaScript | Medium |
| `mill1000/midea-msmart` | Python | High |
| Own hardware captures | — | Sessions 1-9 |

For full source descriptions, see [protocol_uart.md §2](protocol_uart.md).

---

## 2. Message Types and Dispatch

### 2.1 Known Serial Protocol Frames

Frames are identified by the combination of **msg_type** (frame byte 9) and
**body[0]** (first body byte). Some msg_types carry the command directly in
body[0]; others are dispatched by msg_type alone (body[0] is payload data,
not a command ID).

The **Captured** column shows approximate frame counts from own hardware
captures (Sessions 1-9, 37,579 total frames, Midea XtremeSaveBlue Q11,
valid CRC). **—** = not yet captured on own hardware.

#### Body[0]-dispatched frames (msg_type 0x02/0x03/0x04/0x05)

These msg_types multiplex several commands via body[0]:

| msg_type | body[0] | Name | Direction | Bus | Captured | Confidence | Section |
|----------|---------|------|-----------|-----|----------|------------|---------|
| `0x02` | `0x40` | Set Status | Dongle→AC | UART, R/T | ~192 | Confirmed | §3.2 |
| `0x02` | `0xB0` | Property Set (TLV) | Dongle→AC | UART | ~24 | Confirmed | §3.5 |
| `0x03` | `0xC0` | Status Response | AC→Dongle | UART, R/T | ~507 | Confirmed | §4.1 |
| `0x03` | `0xC1` | Extended (groups, power) | AC→Dongle | UART, R/T | ~758 | Confirmed | §4.2 |
| `0x03` | `0xB1` | Property Response | AC→Dongle | UART | ~76 | Confirmed | §3.5 |
| `0x03` | `0xB5` | Capabilities (TLV) | AC→Dongle ¹ | UART | ~34 | Confirmed | §3.4 |
| `0x03` | `0x93` | Extension Board Status | Bidir | R/T | ~704 | Confirmed | §3.3 |
| `0x02` | `0x93` | Extension Board Query | Disp→ExtBd | R/T | ~353 | Confirmed | §3.3 |
| `0x02` | `0x41` | Query (status/groups) | Dongle→AC | UART, R/T | ~1100 | Confirmed | §3.1 |
| `0x04` | `0xA1` | Heartbeat (Energy+Temps) | AC→Dongle | UART | ~55 | Confirmed | §5.1 |
| `0x04` | `0xA2` | Heartbeat (Device Params) | AC→Dongle | UART | ~80 | Confirmed | §5.3 |
| `0x04` | `0xA3` | Heartbeat (Device Params 2) | AC→Dongle | UART | ~63 | Confirmed | §5.3 |
| `0x04` | `0xA5` | Heartbeat (Outdoor Unit) | AC→Dongle | UART | ~50 | Confirmed | §5.3 |
| `0x04` | `0xA6` | Heartbeat (Network Info) | AC→Dongle | UART | ~48 | Confirmed | §5.3 |
| `0x05` | `0xA0` | Heartbeat ACK (C0-format) | AC→Dongle ¹ | UART | ~115 | Confirmed | §5.3 |

#### msg_type-dispatched frames (body[0] is payload, not command ID)

| msg_type | Name | Direction | Bus | Captured | Confidence | Section |
|----------|------|-----------|-----|----------|------------|---------|
| `0x07` | Device ID (SN query) | Bidir | UART | 3 | Confirmed | §5.5 |
| `0x0D` | Network Init / SoftAP | Dongle→AC | UART | ~14 | Confirmed | §5.4 |
| `0x63` | Network Status Report | Dongle→AC | UART | ~116 | Confirmed | §5.4 |
| `0x65` | RAC Serial Number | Bidir | UART | 2 | Confirmed | §5.6 |
| `0x64` | OTA / Key Trigger | AC→Dongle | UART | 2 | Observed | — |
| `0xA0` | Proprietary (unknown) | AC→Dongle | UART | 8 | Observed | — |

**¹ Echoed frames**: Heartbeat ACK (0xA0) and Capabilities (0xB5) appear on
**both** UART wires with identical raw bytes. The AC mainboard sends the frame
first (wifiOrange, fromACdisplay); the dongle retransmits the exact same bytes
~50ms later (wifiBrown, toACdisplay) as acknowledgment. All other heartbeat types
(A1-A6) are strictly one-directional (fromACdisplay only). Note: other frame types
(0x63, 0xB0/B1, 0x65) also appear on both wires but as request-response pairs with
**different bytes**. See [protocol_uart.md §4.3](protocol_uart.md) for full analysis.

#### Not yet captured on own hardware

These msg_types are documented from source code analysis (mill1000/midea-msmart
Finding 13) but have not been observed in own captures:

| msg_type | Name | Direction | Confidence |
|----------|------|-----------|------------|
| `0x06` | Status upload (cloud 0x40) | AC→Dongle | Consistent |
| `0x0A` | Error report (cloud 0x44) | AC→Dongle | Consistent |
| `0x0F` | Status transport (cloud 0x20) | AC→Dongle | Consistent |
| `0x11` | Status transport (=0x0F) | AC→Dongle | Consistent |
| `0x13` | Config data (6 bytes) | AC→Dongle | Consistent |
| `0x14` | Accepted (pair w/ 0x15) | AC→Dongle | Consistent |
| `0x15` | Accepted (triggers reboot) | AC→Dongle | Consistent |
| `0x16` | Device event (4-byte data) | Dongle→AC | Consistent |
| `0x61` | Time sync | Dongle→AC | Consistent |
| `0x68` | WiFi config (SSID/password) | AC→Dongle | Consistent |
| `0x6B` | Passthrough (echo) | AC→Dongle | Consistent |
| `0x81`–`0x85` | Mode check / config / ignored | AC→Dongle | Consistent |
| `0x87` | Version info (fixed response) | AC→Dongle | Consistent |
| `0x90` | Exception (reject LEN≤11) | AC→Dongle | Consistent |
| `0x9A` | WiFi version (cloud, not UART) | Dongle→Cloud | Consistent |

**Cloud forwarding** — the dongle forwards certain msg_types to the cloud:

| MSG_TYPE received | Cloud packet type | Description |
|-------------------|-------------------|-------------|
| 0x04, 0x06 | 0x40 | Status upload |
| 0x05, 0x0A | 0x44 | Error upload |
| 0x0F, 0x11 | 0x20 | Transport upload |

**Silently ignored** msg_types: `0x12`, `0x6A`, `0x6B` (echo), `0x71`, `0x81`, `0x84`, `0x90` (if LEN≤11).

Source: mill1000/midea-msmart Finding 13 (see `midea-msmart-mill1000.md`).

### 2.2 Response Dispatch

The dissector dispatches incoming frames in two stages: first by **msg_type**
(frame byte 9), then by **body[0]** for the multiplexed types. Priority is
msg_type first — if the msg_type has a dedicated handler, body[0] is treated
as payload data, not a command selector.

| msg_type | body[0] | Decoder | Section |
|----------|---------|---------|---------|
| `0x07` | *(any)* | Device Identification | §5.5 |
| `0x0D` | *(any)* | Network Init | §5.4 |
| `0x63` | *(any)* | Network Status | §5.4 |
| `0x65` | *(any)* | RAC Serial Number | §5.6 |
| `0x02` | `0x40` | Set Status command | §3.2 |
| `0x02` | `0x41` | Query command | §3.1 |
| `0x02` | `0x93` | Extension Board query | §3.3 |
| `0x02` | `0xB0` | Property Set (TLV) | §3.5 |
| `0x03` | `0xC0` | Status Response / Notification | §4.1 |
| `0x03` | `0xC1` | Extended Response (groups, power, ext state) | §4.2 |
| `0x03` | `0xB1` | Property Response (TLV) | §3.5 |
| `0x03` | `0xB5` | Capabilities Response (TLV) | §3.4 |
| `0x03` | `0x93` | Extension Board response | §3.3 |
| `0x04` | `0xA1` | Heartbeat — Energy + Temperatures | §5.1 |
| `0x04` | `0xA2` | Heartbeat — Device Params | §5.3 |
| `0x04` | `0xA3` | Heartbeat — Device Params 2 | §5.3 |
| `0x04` | `0xA5` | Heartbeat — Outdoor Unit | §5.3 |
| `0x04` | `0xA6` | Heartbeat — Network Info | §5.3 |
| `0x05` | `0xA0` | Handshake ACK (C0-format status) | §6 |

---

## 3. Commands (Dongle → Appliance)

### 3.1 Command 0x41 — Query Variants

The 0x41 command has multiple variants distinguished by **body[1]** (sub-command)
and **body[2]** (variant selector). Do not conflate with the 0x40 set command.

### Variant table

| body[1] | body[2] | body[3] | body[4] | Name | Expected response |
|---------|---------|---------|---------|------|-------------------|
| `0x81` | `0x00` | `0xFF` | `0x00` | **Status query** | `0xC0` status response |
| `0x81` | `0x00` | `0xFF` | `0x01` | **Follow Me temperature** (R/T only, `body[5]=T*2+50`) — see §3.1.1, §3.1.4.6 | `0xC0` status response |
| `0x81` | `0x01` | page ID | `0x00` | **Group dev-param query** (mill1000 Finding 11) | `0xC1` group page response |
| `0x21` | `0x01` | `0x44` | `0x00` | **Power usage query** (Group 4) | `0xC1` Group 4 power response (BCD) |
| `0x21` | varies | varies | optCmd | **Extended query** (mill1000 Finding 7, optCommand in body[4]) | `0xC1` extended state |
| `0x61` | `0x00` | `0xFF` | — | **Display toggle** | — |

### Body layout — note on bus path differences

**R/T bus captures (Session 1, ground truth):**
Body is **23 bytes** — body[4..21] are all `0x00`, body[22] = MSG_ID (sequence counter
added by the R/T bus extension board). The CRC-8 covers all 23 body bytes.

**Community sources (Wi-Fi UART path, not directly captured):**
Body documented as 22 bytes with body[4]=`0x03`, body[5]=`0xFF`, body[7]=`0x02`,
body[20]=`0x03`, body[21]=MSG_ID. These extra non-zero bytes may be specific to the
Wi-Fi UART path or to a different firmware generation.
**Disputed** — the R/T captures show all zeros in those positions. Do not assume
the Wi-Fi path uses the same values until captured directly.

#### 3.1.1 Status query (body[1]=sub-cmd 0x81, body[2]=variant 0x00) → Response: §4.1 (0xC0)

Triggers a full `0xC0` status response (§4.1). Captured on R/T bus in Session 1.

```
Body (23 bytes on R/T bus):
  [0]  0x41  command ID
  [1]  0x81  sub-command
  [2]  0x00  variant: status query
  [3]  0xFF
  [4..21]  0x00 (R/T bus; community sources show non-zero on Wi-Fi path — see above)
  [22] MSG_ID  sequence counter (R/T bus extra byte)
```

Captured frame (R/T bus, body shown, bytes 11..33 of 38-byte frame):
```
41 81 00 FF 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 36
```

**R/T Follow Me temperature variant**: When Follow Me is active, the R/T bus
repurposes `body[4]` to carry optCommand=0x01 (Follow Me temperature) within
the standard query frame. The frame structure is identical except
`body[4]=0x01` and `body[5]=T*2+50`. This is an R/T-specific variant — the
UART bus uses the extended format (`body[1]=0x21`) for optCommand, while the
R/T bus uses the standard format (`body[1]=0x81`). See §3.1.4.6 for encoding
details and §3.1.4.6 "Cross-bus comparison" table for differences between buses.

Captured frame (R/T bus, Session 7, Follow Me active at 24°C):
```
41 81 00 FF 01 62 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 XX
               ^^ body[4]=0x01 (optCommand: Follow Me temperature)
                  ^^ body[5]=0x62 → (98-50)/2 = 24.0°C
```

This variant is sent by the busadapter (busadapter → display) once per R/T
polling cycle while Follow Me is active. It stops during idle periods when
Follow Me is off but reappears briefly during operator actions (stale
temperature). See `analysis_follow_me_serial.md` §5 for full evidence.

#### 3.1.2 Capability page query (body[1]=sub-cmd 0x81, body[2]=variant 0x01, body[3]=pageID) → Response: §4.2 (0xC1 group pages)

Selects a config/capability page for the extension board or wall controller.
Triggers a `0xC1` group page response (not a `0xC0` status response).
Observed pages: `0x41`, `0x42`, `0x43`, `0x45`. Used in the R/T bus polling cycle.

**Cross-reference**: mill1000/midea-msmart (see `midea-msmart-mill1000.md`, Finding 11):
These group pages correspond to a group-based "device development parameter" system.
The response dispatches by `body[3] & 0x0F` as group number:
page 0x41 → Group 1 (base run info), page 0x42 → Group 2 (indoor device params),
page 0x43 → Group 3 (outdoor device params), page 0x44 → Group 4 (power),
page 0x45 → Group 5 (extended params). **Hypothesis** — field labels from single
source, not yet verified against own captures at field level.

```
Body (23 bytes on R/T bus):
  [0]  0x41  command ID
  [1]  0x81  sub-command
  [2]  0x01  variant: group page query
  [3]  page  page ID (0x41 / 0x42 / 0x43 / 0x45 observed)
  [4..21]  0x00
  [22] MSG_ID
```

Captured request frames (R/T bus):
```
Page 0x41:  41 81 01 41 00...00 9A
Page 0x42:  41 81 01 42 00...00 24
Page 0x43:  41 81 01 43 00...00 AC
```
Note: page 0x45 had 5 response frames in Session 1 but no corresponding `41 81 01 45`
request was found — possibly a spontaneous / pushed response. **Unknown.**

For group page response field details, see §4.2 (0xC1 Group Pages).

---

#### 3.1.3 Power usage query (body[1]=sub-cmd 0x21, body[2]=variant 0x01, body[3]=page 0x44) → Response: §4.2.4 (0xC1 Group 4 power)

Triggers a `0xC1` power BCD response. See §4.2.1 for response parsing.

```
Body (22 bytes, community sources):
  [0]  0x41   command ID
  [1]  0x21   sub-command: power/extended
  [2]  0x01
  [3]  0x44   power page marker
  [4..20]  0x00
  [21] 0x04
  [22] MSG_ID
```

#### 3.1.4 optCommand queries (body[4]=optCommand) — Follow Me, extended state, engineering modes

The optCommand mechanism selects query variants (Follow Me temperature push,
extended state query, engineering modes) via `body[4]`. It appears in two
frame formats depending on bus:

- **UART**: Extended query (`body[1]=0x21`, 24-byte frame) — documented in
  mill1000/midea-msmart Finding 7 and Finding 10 (see `midea-msmart-mill1000.md`)
- **R/T**: Standard query (`body[1]=0x81`, 38-byte frame) with `body[4]`
  repurposed — own captures, Sessions 4, 5, 7 (see §3.1.1 for hex example)

Confidence: optCommand 0x01 and 0x03 are **Consistent** (multi-source: mill1000/midea-msmart Finding 7 + own R/T captures). All other optCommand values are **Hypothesis** (single source within mill1000/midea-msmart Finding 7, not verified on hardware).

##### 3.1.4.1 UART extended frame layout (body[1]=sub-cmd 0x21, 24 bytes)

```
Offset  Value               Field
------  -----               -----
  0     0xAA                Start byte
  1     0x17                Length = 23 (counts bytes [1..23])
  2     0xAC                Appliance type
  3-8   0x00 x6             Reserved / device address
  9     0x03                msg_type = query
 10     0x41                body[0]: command ID
 11     sound<<6 | 0x21     body[1]: buzzer flag (bit 6) + sub-cmd 0x21
 12     0x00                body[2]
 13     0xFF                body[3]
 14     optCommand          body[4]: selects query variant (see table below)
 15     (varies)            body[5]: payload — depends on optCommand
 16     (varies)            body[6]: specKey — depends on optCommand
 17     (varies)            body[7]: queryStat — depends on optCommand
 18-20  0x00 x3             body[8-10]: reserved
 21     order               body[11]: frame sequence number (incrementing)
 22     CRC8                CRC-8/854 over body bytes [0..11]
 23     CHK                 Two's complement of sum of bytes [1..22]
```

**body[1] bit 6 — Buzzer control**: `body[1] = sound << 6 | 0x21`, where `sound` = 0 (silent)
or 1 (beep). This is one of three independent buzzer mechanisms:

| Path | Location | Value |
|------|----------|-------|
| 0x40 set command | body[1] bit 6 | BYTE_BUZZER_ON = 0x40 |
| Extended 0x41 | body[1] bit 6 | `sound << 6 \| 0x21` |
| Standard 0x41 | body[1] bit 6 | `0x81` or `0xC1` (bit 6 = buzzer) |
| 0xB0 property | property 0x1A, 0x00 | 0x00=off, 0x01=on |

**Own captures**: Buzzer bit 6 was **never set** on either bus — R/T body[1]=0x81
always (937 0x41 frames, 78 0x40 frames), UART body[1]=0x21 always (11 extended
frames). The room controller (KJR-120M) beeps locally.

##### 3.1.4.2 Comparison: Standard (body[1]=sub-cmd 0x81) vs Extended (body[1]=sub-cmd 0x21)

| Aspect | Standard 0x41 | Extended 0x41 |
|--------|---------------|---------------|
| Frame length | 35 bytes (0x23) | 24 bytes (0x17) |
| body[1] | 0x81 | 0x21 (+ buzzer bit 6) |
| body[4] | 0x00 or optCommand *** | optCommand (selects variant) |
| body[7] | 0x02 (fixed) | queryStat (when optCommand=0x03) |
| Response type | 0xC0 status | 0xC1 extended (sub-pages 0x01 + 0x02) |
| Body length | 22-23 bytes | 12 bytes |

*** **R/T bus exception**: On the R/T extension board bus, the standard 0x41
(`body[1]=0x81`) repurposes `body[4]` to carry the optCommand — specifically
`body[4]=0x01` with `body[5]=T*2+50` for Follow Me temperature. The extended
format (`body[1]=0x21`) was never observed on the R/T bus (Sessions 3–9).
See `analysis_follow_me_serial.md` §5 for evidence.

##### 3.1.4.3 optCommand table (body[4]=optCommand, body[5..9]=payload)

On the UART bus, optCommand values use the 24-byte extended frame (`body[1]=0x21`).
On the R/T bus, optCommand=0x01 (Follow Me temperature) was observed in the
standard 38-byte query (`body[1]=0x81`) — see §3.1.1. The payload encoding
(`body[5..9]`) is the same in both formats:

| optCommand | Purpose | body[5] | body[6] | body[7] | body[8] | body[9] | Confidence |
|------------|---------|---------|---------|---------|---------|---------|------------|
| 0x00 | Sync / normal extended query | 0xFF | 0x00 | 0x00 | 0x00 | 0x00 | Hypothesis |
| **0x01** | **Follow Me temperature** | `bodyTemp * 2 + 50` | 0x00 | 0x00 | 0x00 | 0x00 | **Consistent** |
| 0x02 | Special function key | 0xFF | specKey | 0x00 | 0x00 | 0x00 | Hypothesis |
| **0x03** | **Query extended state** | 0xFF | 0x00 | queryStat | 0x00 | 0x00 | **Consistent** |
| 0x04 | Installation position | 0xFF | 0x00 | 0x00 | instPos | 0x00 | Hypothesis |
| 0x05 | Engineering / test mode | 0xFF | 0x00 | 0x00 | 0x00 | testMode | Hypothesis |
| 0x06 | Max cool/heat freq limit | 0xFF | 0x00 | 0x00 | 0x00 | OR bit 7 | Hypothesis |

Note: optCommand 0x04 places its payload at **body[8]** (not body[7]). optCommand 0x05
uses **body[9]**. optCommand 0x06 OR's `(maxCoolHeat & 0x01) << 7` into body[9] bit 7.
Source: mill1000/midea-msmart Finding 7 (see `midea-msmart-mill1000.md`).
optCommand values 0x04-0x06 are single-source and unverified on hardware.

##### 3.1.4.4 Direct C1 sub-page query (body[1]=sub-page 0x01/0x02, 14 bytes) → Response: §4.3 (0xC1 extended state)

An alternative to optCommand=0x03 — a shorter **14-byte frame** that requests a specific
C1 sub-page directly by number:

```
Offset  Value           Field
  0     0xAA            Start
  1     0x0D            Length = 13 (14 bytes total)
  2     0xAC            Appliance type
  3-8   0x00 x6         Reserved
  9     0x03            msg_type
 10     0x41            body[0]: command
 11     0x01 or 0x02    body[1]: sub-page number (0x01 or 0x02)
 12     CRC8            CRC-8/854
 13     CHK             Checksum
```

This bypasses the optCommand/queryStat mechanism entirely. The response is the same
0xC1 sub-page as triggered by optCommand=0x03.

Source: mill1000/midea-msmart Finding 7 (see `midea-msmart-mill1000.md`). **Hypothesis**.

##### 3.1.4.5 queryStat values (body[7]=queryStat when body[4]=optCommand 0x03) → Response: §4.3 (0xC1 extended state)

| queryStat | Purpose | Response |
|-----------|---------|----------|
| 0x00 | Invalid | — |
| 0x01 | Exit query mode | — |
| 0x02 | Extended state query | 0xC1 sub-pages 0x01 + 0x02 (see §4.2.3, §4.2.4) |
| 0x03 | Outdoor-focused query | Unknown response format |

##### 3.1.4.6 Follow Me temperature (body[4]=optCommand 0x01, body[5]=bodyTemp T*2+50) → Response: §4.1 (0xC0)

When Follow Me is enabled (via 0x40 set command body[8] bit 7 = 1), the remote or
phone periodically sends its measured room temperature using optCommand=0x01.

**Temperature encoding**:
```
encoded  = bodyTemp_celsius * 2 + 50
bodyTemp = (encoded - 50) / 2

Range: 0-50 C (encoded 0x32-0x96)
```

**Worked example** (22 C, buzzer off, sequence=0):
```
AA 17 AC 00 00 00 00 00 00 03  41 21 00 FF 01 5E 00 00 00 00 00 00  <CRC> <CHK>
                                            ^^ optCommand=0x01 (Follow Me)
                                               ^^ 22*2+50 = 94 = 0x5E
```

**R/T bus variant** (own captures, Sessions 4, 5, 7 — confirmed): The R/T bus
uses the standard query format (`body[1]=0x81`, 38-byte frame) with `body[4]`
repurposed to carry optCommand=0x01. Same temperature encoding (`body[5]=T*2+50`)
as the UART extended format. See §3.1.1 for hex example and
`analysis_follow_me_serial.md` §5 for full cross-session verification.

**Cross-bus comparison — Follow Me temperature encoding**:

| Bus | Frame | Encoding | Example: 22 C |
|-----|-------|----------|---------------|
| UART extended 0x41 (`body[1]=0x21`) | 24-byte, body[4]=optCommand | `T * 2 + 50` | 0x5E (94) |
| R/T standard 0x41 (`body[1]=0x81`) | 38-byte, body[4]=optCommand | `T * 2 + 50` | 0x5E (94) |
| XYE C6 byte[11] | 16-byte command | direct Celsius | 0x16 (22) |
| XYE C3 byte[8] (setpoint context) | 16-byte command | `T + 0x40` | 0x56 (86) |
| R/T 0xC0 body[11] (readback) | 38-byte response | `(raw - 50) / 2` | 0x5E (94) |

The UART and XYE encodings differ. See `protocol_xye.md` §0.4a for the XYE Follow-Me mechanism.

##### 3.1.4.7 Follow Me enable / readback (body[8] bit 7 = Follow Me flag)

| Direction | Location | Bit | Field | Meaning |
|-----------|----------|-----|-------|---------|
| Command (0x40 set) | body[8] | bit 7 | Follow Me (bodySense) | 1 = enable Follow Me |
| Response (0xC0) | body[8] | bit 7 | Follow Me (bodySense) | 1 = Follow Me active |
| Response (0xC0) | body[9] | bit 7 | localBodySense | 1 = built-in occupancy sensor active. **Hypothesis** — OQ-17. Own captures: always 0x00 |

**Three body-sensing feature types** — the source code uses similar-sounding
names for three distinct features:

| Feature | Field name | Location | Function |
|---------|------------|----------|----------|
| **Follow Me** | `bodySense` | body[8] bit 7 (SET + RSP) | Overrides the unit's measured temperature with an external value sent via IR remote or serial interface (phone/controller). The unit uses this temperature for its control loop instead of its own thermistor. |
| **Local body sense** | `localBodySense` | body[9] bit 7 (RSP only) | Occupancy sensor — detects/tracks a person in the room. Exact behavior unknown (acts according to unit settings). Only on models with a built-in sensor. |
| **Wisdom Eye** | `wisdomEye` | body[9] bit 0 (SET) | Occupancy sensor — detects/tracks a person in the room. Exact behavior unknown. Only on models with a built-in sensor. |

Follow Me is a temperature override mechanism (documented in §3.1.4.6). The
other two are occupancy sensors — what the unit does when it detects/loses a
person is unknown from protocol data alone and depends on unit settings and
model. Our test unit (XtremeSave Blue) does not have a built-in occupancy
sensor.

##### 3.1.4.8 Hex template (optCommand=0x03, queryStat=0x02, extended state query)

```
AA 17 AC 00 00 00 00 00 00 03  41 21 00 FF 03 FF 00 02 00 00 00 NN  <CRC> <CHK>
                                            ^^ optCommand=0x03
                                                     ^^ queryStat=0x02
                                                              ^^ NN=sequence
```

**Dissector note**: The dissector recognizes `body[1]=0x21` and shows the raw `optCommand`
value but does not decode optCommand names, Follow Me temperature, or queryStat values.
Enhancement opportunity.

#### 3.1.5 Display toggle (body[1]=sub-cmd 0x61)

```python
display_toggle_body = [
    0x41, 0x61, 0x00, 0xFF, 0x02, 0x00, 0x02, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, RANDOM_BYTE,
    # CRC8 appended
]
```

---
                bit 7       Eco mode

 10      20     bit 0       Sleep mode
                bit 1       Turbo mode (another location)
                bit 2       Temperature unit (0=C, 1=F)
                bit 3       Catch cold
                bit 4       Night light
                bit 5       Peak elec
                bit 6       Dust full
                bit 7       Clean fan time

 11-14   21-24  (reserved, 0x00)

 15      25     bit 7       Natural fan
                bits [6:0]  0x00

 16-17   26-27  (reserved, 0x00)

 18      28     bits [4:0]  New temperature setpoint - 12 (alternative temp range 12-43C)

 19      29     bits [6:0]  Humidity setpoint (0-100)

 20      30     (reserved)

 21      31     bit 0       Set expand dot (0.5C flag)
                bits [6:1]  Set expand value
                bit 6       Double temp
                bit 7       Frost protection mode

 22      32     (reserved or padding)

 23      33     MSG_ID      Incrementing message counter

 24      34     CRC8        CRC-8 over body bytes

 25      35     CHECKSUM    Frame checksum
```

### Operating Modes (bits [7:5] of body byte 2):
```python
MODE_AUTO      = 1   # 0b001  (0x20 masked to bits[7:5])
MODE_COOL      = 2   # 0b010  (0x40)
MODE_DRY       = 3   # 0b011  (0x60)
MODE_HEAT      = 4   # 0b100  (0x80)
MODE_FAN_ONLY  = 5   # 0b101  (0xA0)
MODE_SMART_DRY = 6   # 0b110  (0xC0) — confirmed (BYTE_MODE_SMART_DRY)
```
All six values are confirmed consistent between `protocol_uart.md` existing sources
and mill1000/midea-msmart Finding 1 (see `midea-msmart-mill1000.md`).

### Fan Speed Values (body byte 3):
```python
FAN_AUTO   = 102  # 0x66 — Consistent (BYTE_FANSPEED_AUTO)
FAN_SILENT = 20   # 0x14 — Consistent (BYTE_FANSPEED_MUTE)
FAN_LOW    = 40   # 0x28 — Consistent (BYTE_FANSPEED_LOW)
FAN_MEDIUM = 60   # 0x3C — Consistent (BYTE_FANSPEED_MID)
FAN_HIGH   = 80   # 0x50 — Consistent (BYTE_FANSPEED_HIGH)
FAN_TURBO  = 100  # 0x64 — from existing sources; Lua does not list separately
```
Source: mill1000/midea-msmart Finding 2 (see `midea-msmart-mill1000.md`).

### Swing Mode (body byte 7, lower nibble):
```python
SWING_OFF        = 0b0000  # 0x00 — Consistent (BYTE_SWING_LR_OFF + BYTE_SWING_UD_OFF)
SWING_VERTICAL   = 0b1100  # 0x0C — Consistent (BYTE_SWING_UD_ON)
SWING_HORIZONTAL = 0b0011  # 0x03 — Consistent (BYTE_SWING_LR_ON)
SWING_BOTH       = 0b1111  # 0x0F — derived (both bits combined)
```
Bits [5:4] of byte 7 are set to `0x30` as a constant in the control command —
the swing nibbles are OR'd with 0x30: `byte[7] = swingLR | swingUD | 0x30`.

A secondary horizontal swing flag `BYTE_SWING_LR_UNDER_ON = 0x80` (for "under" units)
is documented at byte 7 bit 7. This is a feature variant not yet observed in own
captures — treat as Hypothesis.

Source: mill1000/midea-msmart Finding 3 (see `midea-msmart-mill1000.md`).

### Temperature Setting (dudanov's approach):
```python
def set_target_temp(body, temp_celsius):
    """Set target temperature with 0.5C resolution."""
    tmp = int(temp_celsius * 4) + 1
    integer = tmp // 4
    # New temperature field (byte 18 of body)
    body[18] = (integer - 12) & 0x1F
    # Legacy temperature field (byte 2 of body)
    integer_legacy = integer - 16
    if integer_legacy < 1 or integer_legacy > 14:
        integer_legacy = 1
    half_degree = (tmp & 2) << 3  # bit 4 = 0.5C flag
    body[2] = (body[2] & 0xE0) | half_degree | integer_legacy
```

#### 3.1.6 Lightweight parameter query (CMDTYPE_QUERY_PAR)

A shorter **17-byte frame** for parameter queries. Uses the same body[1]=0x21 sub-command
but with only 5 body bytes:

```
Offset  Value               Field
  0     0xAA                Start
  1     0x10                Length = 16 (17 bytes total)
  2     type                Appliance type (0xAC)
  3-7   0x00                Reserved
  8     0x02                (differs from standard 0x00)
  9     0x03                msg_type = query
 10     0x41                body[0]: command
 11     sound<<6 | 0x21     body[1]: buzzer + sub-cmd
 12     0x01                body[2]
 13     optCommand          body[3]: sub-operation
 14     order               body[4]: sequence number
 15     CRC8                CRC-8/854 over body[0..4]
 16     CHK                 Checksum
```

Note: byte[8] is 0x02 (not 0x00 as in standard frames).

Source: mill1000/midea-msmart Finding 14 (see `midea-msmart-mill1000.md`). **Hypothesis**.

**Unimplemented command types**: The following CMDTYPEs are defined in the app code but
have no frame builder — they are reserved for future features or device-specific variants:
CMDTYPE_SET_FILTER (100), CMDTYPE_GET_FILTER_RESULT (101), CMDTYPE_RESET_FILTER (102),
CMDTYPE_START_WEATHER_VOICE (200), CMDTYPE_SET_VOICE (201).
Source: mill1000/midea-msmart Finding 14 (see `midea-msmart-mill1000.md`).

---

### 3.2 Command 0x40 — Set Status → Response: §4.1 (0xC0)

### Body layout (offsets relative to body start = frame offset 10):

The body is 26 bytes (indices 0-25), making the full frame 36 bytes.

```
Body    Frame
Offset  Offset  Bits        Field
------  ------  ----        -----
  0      10     [7:0]       0x40 (command ID, always)

  1      11     bit 0       Power ON (1=on, 0=off)
                bit 1       Always 0x02 (must set)
                bit 2       Resume
                bit 3       Child sleep
                bit 4       Timer mode
                bit 5       Test2
                bit 6       Beep/buzzer (1=audible feedback)
                NOTE: NeoAcheron uses 0x42 mask for beep (bits 1+6)

  2      12     bits [3:0]  Target temperature - 16 (range 0-14 = 16-30C)
                bit 4       Temperature has 0.5C decimal
                bits [7:5]  Operating mode (see Mode enum below)

  3      13     bits [6:0]  Fan speed (see Fan enum below)
                bit 7       Timer set flag

  4      14     bit 7       On-timer enabled
                bits [6:2]  On-timer hours (0-31)
                bits [1:0]  On-timer minutes high (quarter-hours)

  5      15     bit 7       Off-timer enabled
                bits [6:2]  Off-timer hours (0-31)
                bits [1:0]  Off-timer minutes high (quarter-hours)

  6      16     bits [7:4]  On-timer minutes low
                bits [3:0]  Off-timer minutes low

  7      17     bits [1:0]  Left-right fan (swing horizontal, 0x03 = on)
                bits [3:2]  Up-down fan (swing vertical, 0x0C = on)
                bits [5:4]  Always 0x30
                (NeoAcheron: byte 0x11 & 0x0F = swing_mode)

  8      18     bits [1:0]  Cosy sleep mode (0-3)
                bit 2       Alarm sleep
                bit 3       Power save (powerSave)
                bit 4       Low frequency fan (farceWind / low wind)
                bit 5       Turbo mode (strong) (duplicate, also in byte 10)
                bit 6       Energy save (energySave)
                bit 7       Follow Me (bodySense) — confirmed, see §3.1.4.7; OQ-16 resolved

  9      19     bit 0       Wise eye / child sleep (NeoAcheron: childSleep)
                bit 1       Exchange air
                bit 2       Dry clean
                bit 3       PTC heater
                bit 4       PTC button / eco mode (NeoAcheron: eco_mode)
                bit 5       Clean up
                bit 6       Change cosy sleep
                bit 7       Eco mode (write position) — see §4.1 body[9] bit 4 for read position.
                            Source: mill1000/midea-msmart Finding 4. dudanov + midea-local agree.

**Validated from captures (Sessions 1 and 8, UART bus):**

| Session | totalPowerConsume | curRealTimePower | Conditions |
|---------|-------------------|-----------------|------------|
| 1 (t≈9s) | **111.45 kWh** | **5 W** | Compressor off, standby |
| 1 (t≈35s) | **111.45 kWh** | **11 W** | Compressor off, standby |
| 8 (t≈42s) | **113.81 kWh** | **381.4 W** | Compressor running ~80 Hz, heat mode |

Cumulative increase Session 1→8: +2.36 kWh. curRealTimePower 381 W at 80 Hz heat is physically consistent.

```python
def bcd(b):
    """Midea 'BCD' decode: treats each nibble as decimal digit, incl. A-F."""
    return ((b >> 4) & 0xF) * 10 + (b & 0xF)

def parse_power_group4(body):
    """Decode C1 Group-4 power response. body[0]=0xC1, body[3]=0x44.
    Returns dict with totalPowerConsume (kWh) and curRealTimePower (kW).
    Source: mill1000/midea-msmart Finding 11 (see midea-msmart-mill1000.md); confirmed Sessions 1 and 8.
    """
    tcp = bcd(body[4])*10000 + bcd(body[5])*100 + bcd(body[6]) + bcd(body[7])/100
    trp = bcd(body[8])*10000 + bcd(body[9])*100 + bcd(body[10]) + bcd(body[11])/100
    crp = bcd(body[12])*10000 + bcd(body[13])*100 + bcd(body[14]) + bcd(body[15])/100
    rt  = bcd(body[16]) + bcd(body[17])/100 + bcd(body[18])/10000
    return {
        "totalPowerConsume_kWh": tcp,
        "totalRunPower_kWh":     trp,
        "curRunPower_kWh":       crp,
        "curRealTimePower_kW":   rt,
    }
```

> ⚠️ **Previous functions (`parse_power_usage`, `parse_power_usage_dudanov`) were wrong.**
> Both decoded body[15..18] — the `curRealTimePower` field — and misidentified it as
> cumulative kWh. The value "381.4 kWh" those functions produced is actually **381.4 W**
> instantaneous draw.

---

### 4.3 Response 0xC1 — Extended State (body[1]=0x01 or 0x02) ← Triggered by: §3.1.4.4 (direct C1 query), §3.1.4.5 (queryStat=0x02)

#### 4.3.1 Extended State Sub-page 0x01 — Sensor Temperatures, Fault Flags, Operating State

Source: mill1000/midea-msmart Finding 8 (see `midea-msmart-mill1000.md`). **Not present in dudanov/MideaUART, reneklootwijk/node-mideahvac,
or ESPHome.** All fields: **Hypothesis** — not verified against own captures.

Triggered by extended `0x41/0x21` query (mill1000/midea-msmart Finding 7, see `midea-msmart-mill1000.md`).

`body[1] = 0x01` identifies this sub-page. `srcBuf` = full UART frame; body[N] = srcBuf[N+10].

| body offset | Field | Encoding | Notes |
|-------------|-------|----------|-------|
| [1] | Sub-page selector | `0x01` fixed | — |
| [9..10] | T1 — indoor coil (evaporator) | 16-bit LE × 0.01 °C; negate if body[10]≥0x80 | — |
| [11..12] | T2 temperature | 16-bit LE × 0.01 °C | — |
| [13..14] | T3 — outdoor coil (condenser) | 16-bit LE × 0.01 °C | — |
| [15..16] | T4 — outdoor ambient (= tempOut) | 16-bit LE × 0.01 °C | — |
| [20] | Compressor current | byte × 0.25 A | — |
| [21] | Outdoor total current | byte × 0.25 A | — |
| [22] | Outdoor supply voltage | raw AD value | — |
| [23] | Indoor actual operating mode | raw | — |
| [24] | Indoor set fan speed — left fan | raw | — |
| [25] | Indoor set fan speed — right fan | raw | — |
| [26] | Indoor fault byte 1 | bit-packed | bit0=env sensor, bit1=pipe sensor, bit2=E2, bit3=DC fan stall, bit4=indoor-outdoor comm, bit5=smart-eye, bit6=display E2, bit7=RF module |
| [27] | Indoor fault byte 2 | bit-packed | refrigerant leak, dust sensor, humidity sensor, filter stall… |
| [28] | Indoor fault byte 3 | bit-packed | door fault, cold-air protection, voltage protection… |
| [29] | Freq-limit state byte 1 | bit-packed | evaporator low-temp limit/protect, condenser high-temp limit/protect… |
| [30] | Freq-limit state byte 2 | bit-packed | discharge high-temp, remote freq limit, E2 errors… |
| [32] | Load state | bit-packed | bit0=defrost, bit1=aux heat, bit2=horiz vane L, bit3=horiz vane R, bit4=vert vane L, bit5=vert vane R, bit6=indoor fan run, bit7=purifier |
| [33] | Outdoor temp query enable | bit0 | — |
| [35] | Outdoor fault byte 1 | bit-packed | bit0=E2(E51), bit1=T3 sensor(E52), bit2=T4 sensor(E53), bit3=discharge(E54), bit4=suction(E55), bit5=compressor top(P2), bit6=DC fan(E7), bit7=AC current sample |
| [36] | Outdoor fault byte 2 | bit-packed | MCU-driver comm, compressor current sample, start fault, phase-loss, zero-speed, sync fault, stall, lock |
| [37] | Outdoor fault byte 3 | bit-packed | detuning, overcurrent(P49), IPM(P0), undervoltage(P10), overvoltage(P11), DC-side voltage(P12), current protection(P81), low pressure |
| [38] | Outdoor fault byte 4 | bit-packed | discharge high-temp limit/protect(L2/P6), condenser high-temp limit/protect(L1), high/low pressure limit/protect |
| [39] | Outdoor fault byte 5 | bit-packed | voltage limit, current limit, PFC faults, 341 sync/MCE faults, 3-phase reverse |
| [40] | Outdoor AC fan state | bit-packed | bit0=low wind, bit1=mid wind, bit2=high wind, bit3=4-way valve |
| [41] | Outdoor DC fan actual speed | byte × 8 = RPM | — |
| [42] | EEV (electronic expansion valve) actual position | byte × 8 = steps | — |
| [43] | Outdoor suction (return air) temperature | raw AD | — |
| [44] | Outdoor DC bus voltage | raw AD | — |
| [45] | IPM module temperature | raw (°C direct?) | — |
| [70] | Left fan actual speed level | raw | — |
| [71] | Right fan actual speed level | raw | — |
| [72] | Down fan set speed | raw | — |
| [73] | Down fan actual speed level | raw | — |
| [77] | Error code | raw (0–33) | — |
| [78] | Board fault bits | bit-packed | bit0=indoor-display comm(Eb), bit1=compressor position(P4), bit2=display-relay board comm(Eb1) |

**Additional sub-page 0x01 fields** (validated 2026-03-28 from mill1000/midea-msmart Finding 8,
see `midea-msmart-mill1000.md`):

| body offset | Field | Encoding | Notes |
|-------------|-------|----------|-------|
| [2] | Device status flags | bit-packed | bit7=newWindMode, bit6=smartClean, bit5=sterilize, bit4=newWind, bit3=humidity, bit2=clean, bit1=runStatus, bit0=deviceSetRunStatus |
| [3] | Device status flags 2 | bit-packed | bit5=AC filter dirty, bit4=elecHeat, bit3=strong, bit2=dry, bit1=wetfilm, bit0=purifyFilter |
| [4] | Run status flags | bit-packed | bit1=runCurrentStatus, bit0=deviceCurrentRunStatus |
| [6] | Current run mode | bits[3:0] | Actual operating mode |
| [17] | Tp temperature | raw AD | Discharge pipe sensor |
| [18] | Compressor actual frequency | raw Hz | |
| [19] | Compressor target frequency | raw Hz | |
| [53-54] | Dry/heat cleanup timer | 16-bit LE | Minutes remaining |
| [55-56] | CO2 / TVOC value | 16-bit LE | |
| [57-58] | Dust / PM2.5 | 16-bit LE | |
| [59] | Mainboard humidity sensor | raw % | |
| [60-61] | Sterilize run time | 16-bit LE | |
| [62-63] | Wet film timer | 16-bit LE | |
| [64-65] | Purify filter timer | 16-bit LE | |
| [66] | Self-clean actual runtime | raw minutes | |
| [74] | Humidity setpoint | raw % | |
| [75-76] | Product code | 16-bit LE | Anti-tamper identifier |

**Cross-references to Group Pages (§3.1.2)**:

| Sub-page 0x01 field | Group page equivalent | Encoding difference |
|---------------------|-----------------------|---------------------|
| T1 body[9-10] (16-bit LE x 0.01 C) | Group 1 body[10] `(val-30)/2` | Sub-page: 0.01 C precision, signed. Group 1: 0.5 C steps, offset 30 |
| T2 body[11-12] | Group 1 body[11] `(val-30)/2` | Same difference |
| T3 body[13-14] | Group 1 body[12] `(val-50)/2` | Sub-page: 0.01 C. Group 1: offset 50 |
| T4 body[15-16] | Group 1 body[13] `(val-50)/2` | Sub-page: 0.01 C. Group 1: offset 50 |
| Indoor fault bytes [26-28] | Group 2 body[6-8] | Same bit layout |
| Outdoor DC fan speed [41] x8 RPM | Group 3 body[10] x8 RPM | Same encoding |
| EEV actual position [42] x8 steps | Group 3 body[11] x8 steps | Same encoding |
| IPM module temperature [45] | Group 3 body[14] | Same (raw C) |

**Temperature encoding asymmetry**: Sub-page 0x01 uses 16-bit LE x 0.01 C (high precision,
signed), while Group 1 uses single-byte with offset-30 (T1/T2) or offset-50 (T3/T4) divided by 2
(0.5 C steps). The 0xC0 status response (§4.1) uses yet another encoding: `(raw - 50) / 2` for
both indoor and outdoor. Three different encodings for the same physical sensors.

---

#### 4.3.2 Extended State Sub-page 0x02 — Status Flags, Timers, Power, Vane Angles, Compressor

Source: mill1000/midea-msmart Finding 8 (see `midea-msmart-mill1000.md`).
All fields: **Hypothesis** — not verified against own captures.

`body[1] = 0x02` identifies this sub-page.

| body offset | Field | Encoding | Notes |
|-------------|-------|----------|-------|
| [1] | Sub-page selector | `0x02` fixed | — |
| [2..3] | On-timer (minutes) | 16-bit LE | — |
| [4..5] | Off-timer (minutes) | 16-bit LE | — |
| [6] | Status flags A | bit-packed | bit7=body-sense, bit6=energy-save, bit5=strong, bit4=refarce-wind, bit3=power-save, bit2=cosy-sleep, bit0=ECO |
| [7] | Status flags B | bit-packed | bit7=dust, bit6=aux-heat-actual, bit5=dry-actual, bit4=fresh-air, bit3=smart-eye, bit2=natural-wind, bit1=peak-valley, bit0=night-light |
| [8] | Status flags C | bit-packed | bit7=anti-cold, bit6=child-kick, bit5=sleep(export), bit4=PMV, bit3=display on/off, bit2=self-clean, bit1=no-direct-wind, bit0=8-deg-heat(export) |
| [9] | Vane swing actual states 1 | bit-packed | bit5-3=UD vane swing (left), bit2=LR vane swing (left), bit1=top vane swing |
| [10] | Vane swing actual states 2 | bit-packed | bit1=UD vane swing (right), bit0=LR vane swing (right) |
| [11] | Current humidity (%) | raw | — |
| [12] | Temperature setpoint (compensated) | `(byte − 30) × 0.5` °C | — |
| [13..14] | Indoor fan runtime | 16-bit LE (minutes?) | — |
| [15] | Outdoor fan target speed | byte × 8 = RPM | — |
| [16] | EEV target position | byte × 8 = steps | — |
| [17] | Defrost step | 0=none, 1=start, 2=in progress, 3=ending | Key diagnostic |
| [18] | Outdoor fault extra | bit0=liquid return fault (P92) | — |
| [19] | Outdoor fault extra 2 | bit1=IGBT sensor fault, bit0=485 fault | — |
| [20] | Compressor current run time | seconds | — |
| [21..22] | Compressor cumulative run time | 16-bit LE hours | — |
| [24] | Max bus voltage (historical) | `byte + 60` V | — |
| [25] | Min bus voltage (historical) | `byte + 60` V | — |
| [26] | Max current (historical) | raw | — |
| [27] | Max T4 (historical) | raw AD | — |
| [28] | Min T4 (historical) | raw AD | — |
| [29] | Cumulative fault count | raw | — |
| [30] | Compressor flux | byte × 8 | — |
| [45] | Compressor start status | raw | — |
| [46] | Outdoor power factor | raw ÷ 256 | — |
| [47..48] | **Outdoor unit power** | 16-bit LE watts | Key energy field |
| [49] | UD vane cool upper limit | % | — |
| [50] | UD vane cool lower limit | % | — |
| [51] | UD vane heat upper limit | % | — |
| [52] | UD vane heat lower limit | % | — |
| [53] | UD vane current angle | % | — |
| [54] | LR vane upper limit | % | — |
| [55] | LR vane lower limit | % | — |
| [56] | LR vane current angle | % | — |
| [57] | Outdoor target compressor frequency | raw | — |
| [58] | Indoor target fan speed | % | — |

**Additional sub-page 0x02 fields** (validated 2026-03-28 from mill1000/midea-msmart Finding 8,
see `midea-msmart-mill1000.md`):

| body offset | Field | Encoding | Notes |
|-------------|-------|----------|-------|
| [23] | Freq-limit type 2 | raw | Reserved |
| [31] | Fan flux | byte x 8 | Fan motor magnetic flux |
| [32] | d-axis current | raw / 64 | FOC d-axis (signed) |
| [33] | q-axis current | raw / 64 | FOC q-axis (signed) |
| [34] | Compressor peak current | raw A | |
| [35] | PFC peak current | raw A | 0-255 A |
| [36] | Fan peak current | raw x 32 | |
| [37-38] | Torque adjust angle | 16-bit LE | Motor compensation |
| [39] | Torque adjust value | byte x 8 | |
| [40] | AD calibration voltage 1 | raw / 16 | ADC reference |
| [41] | AD calibration voltage 2 | raw / 16 | |
| [42] | d-axis voltage | raw / 16 | |
| [43] | q-axis voltage | raw / 16 | |
| [44] | PFC switch status | raw | |
| [59] | Top vane upper limit | % | Top louver (beyond UD/LR) |
| [60] | Top vane lower limit | % | |
| [61] | Top vane current angle | % | |
| [62] | Bottom vane cool upper limit | % | Conditional: only if response length > 71 |
| [63] | Bottom vane cool lower limit | % | Conditional |
| [64] | Bottom vane heat upper limit | % | Conditional |
| [65] | Bottom vane heat lower limit | % | Conditional |
| [66] | Bottom vane current angle | % | Conditional |
| [67] | Second humidity sensor | raw % | Lower humidity sensor |
| [68] | Extended status | bit-packed | bit7=strong, bit6=sterilize, bit5=newWind, bit4=humidity, bit3=clean, bits[2:0]=self-clean stage (0-6) |
| [69] | Wind-free and panel | bit-packed | bit7=R wind-free, bit6=L wind-free, bit5=UD swing R, bit4=LR swing R, bit3=panel protect, bit2=water tank empty, bit1=LR swing L, bit0=UD swing L |

**Cross-references to Group Pages (§3.1.2)**:

| Sub-page 0x02 field | Group page equivalent | Notes |
|---------------------|-----------------------|-------|
| Humidity [11] | Group 5 body[4] | Same (raw %) |
| Compensated setpoint [12] | Group 5 body[5] | Sub-page: `(byte-30)*0.5`. Group 5: raw (no formula documented) |
| Indoor fan runtime [13-14] | Group 5 body[6-7] | Both 16-bit LE |
| Outdoor fan target speed [15] x8 | Group 5 body[8] x8 | Same encoding |
| EEV target position [16] x8 | Group 5 body[9] x8 | Same encoding |
| Defrost step [17] | Group 5 body[10] | Same encoding (0-3) |
| Compressor run time [20] | Group 5 body[13] x64 s | Sub-page: seconds. Group 5: raw x64 seconds |
| Compressor cumul. time [21-22] | Group 5 body[14-15] | Both 16-bit LE hours |
| Max/min bus voltage [24-25] | Group 5 body[17-18] | Same (`raw + 60` V) |
| Max current, max/min T4, fault count [26-29] | Group 6 body[4-7] | Same encoding |
| Compressor flux [30] x8 | Group 6 body[8] x8 | Same encoding |
| Vane limits/angles [49-56] | Group 11 body[5-12] | Same (raw %) |
| Outdoor unit power [47-48] | *No group page equivalent* | Unique to sub-page 0x02 |

**Two query paths to the same diagnostic data**:

| Aspect | Group Pages (§3.1.2) | Extended State (§4.2.3/§4.2.4) |
|--------|----------------------|--------------------------------|
| Query | `0x41/0x81/0x01/<page>` | `0x41/0x21` with optCommand=0x03, queryStat=0x02 |
| Response | 0xC1, body[1]=0x21, one 10-byte group per page | 0xC1, body[1]=0x01/0x02, ~80 bytes per sub-page |
| Coverage | 8 groups x ~15 fields each | 2 sub-pages, ~80 fields total |
| Precision | Temperatures: 0.5 C steps | Temperatures: 0.01 C precision (16-bit) |
| Protocol era | "Classic" — older/standard interface | Extended — newer devices, single-source (mill1000/midea-msmart Finding 7) |
| Own captures | Groups 1-5 captured on R/T bus (Session 1) | **Not captured** — requires extended query |

---

### 3.3 Command 0x93 — Extension Board / Wall Controller Status → Response: §4.4 (0x93)

Observed on R/T bus (HA/HB via MFB-X, bidirectionalExtensionBoard) in Session 1.
Appears in both request and response direction. Not documented in any open-source
UART implementation — specific to the KJR/extension board bus path.
**Hypothesis — field meanings unknown.**

Requests use msg_type `0x03` (query) or `0x02` (set/ack). Responses use the same.

### Request body (23 bytes, R/T bus)

```
[0]   0x93  command ID
[1]   param1  — varies; 0x00 or 0x80 observed (bit 7 may be direction/type flag)
[2]   param2  — 0x80 in all requests
[3]   param3  — 0x84, 0x90, 0x04 observed
[4..21]  0x00
[22]  MSG_ID
```

Request variants captured:
```
Poll (msg_type=0x03):  93 00 80 84 00...00 17
Set  (msg_type=0x02):  93 80 80 84 00...00 B2
```

For response body format, see §4.4.

---

### 3.4 Command 0xB5 — Capabilities Query → Response: §4.5 (0xB5)

Two protocol generations exist for capability discovery. The device's `dataType` field
determines which format is used:
- **New protocol** (`dataType == 0x03`, msg_type = 0x03): TLV record structure (documented below)
- **Old protocol** (`dataType == 0x05`, msg_type = 0x05): Fixed-format cursor-based block (see end of section)

Source for old protocol: mill1000/midea-msmart Finding 9 (see `midea-msmart-mill1000.md`).

#### 3.4.1 New Protocol B5 (TLV format, msg_type=0x03)

### Request Body:
```python
# First capabilities query:
cap_query_1 = [0xB5, 0x01, 0x11]
# + CRC8 appended

# Second capabilities query (for additional capabilities):
cap_query_2 = [0xB5, 0x01, 0x01, 0x00]
# + CRC8 appended
```

### Full frame (reneklootwijk-style):
```python
cap_frame = bytearray([
    0xAA, 0x00, 0xAC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x03,
    0xB5, 0x01, 0x00,  # byte 12 = 0x00 for first query
    0x00, 0x00  # CRC + checksum
])
```

### B5 Response Parsing:

Response body[0] = `0xB5`. Structure:
```
body[1] = number of capability records
body[2..] = capability records
```

Each capability record:
```
Offset  Field
  0     Capability ID (low byte)
  1     Capability type: 0x00 = simple, 0x02 = extended
  2     Data length (N)
  3..   Data bytes (N bytes)
```

Record iteration: `i += 3 + data_length`

### Capability IDs:

**Type 0x00 (simple on/off, check byte 3 != 0):**
| ID     | Feature              |
|--------|----------------------|
| 0x15   | Indoor humidity      |
| 0x18   | Silky cool           |
| 0x30   | Smart eye            |
| 0x32   | Wind on me           |
| 0x33   | Wind of me           |
| 0x39   | Active clean         |
| 0x42   | One-key no wind      |
| 0x43   | Breeze control       |

**Type 0x02 (extended, value in byte 3+):**
| ID     | Feature                        | Values                                    |
|--------|--------------------------------|-------------------------------------------|
| 0x10   | Fan speed control              | **byte3 != 1 = supported** (byte3=1 means NOT supported) — Consistent: dudanov/node-mideahvac |
| 0x12   | Eco mode                       | 1 = eco, 2 = special eco                  |
| 0x13   | Frost protection               | byte3 != 0 = supported                    |
| 0x14   | Operating modes                | **0=cool+dry+auto(no heat), 1=all four, 2=heat+auto, 3=cool only** — Consistent: dudanov/node-mideahvac |
| 0x15   | Swing/fan direction            | 0=UD-only, 1=both, 2=neither, 3=LR-only — Consistent: dudanov/node-mideahvac |
| 0x16   | Power calculation              | 0-1=neither, 2=powerCal, 3=powerCal+Setting |
| 0x17   | Nest/filter check              | 0=neither, 1-2=nestCheck, 3=nestNeedChange, 4=both |
| 0x19   | Aux electric heating           | byte3 != 0 = supported                    |
| 0x1A   | Turbo mode                     | **0=cool-only, 1=both, 2=neither, 3=heat-only** — Consistent: dudanov/node-mideahvac |
| 0x1F   | Humidity control               | 0=neither, 1=auto, 2=auto+manual, 3=manual-only |
| 0x22   | Unit changeable (C/F)          | **byte3 == 0 = changeable** (inverted — val=0 means YES) — Consistent: dudanov/node-mideahvac |
| 0x24   | Light/LED control              | byte3 != 0 = supported                    |
| 0x25   | Temperature ranges             | 6 bytes: minCool, maxCool, minAuto, maxAuto, minHeat, maxHeat — **each byte × 0.5 = °C** — Consistent: dudanov/node-mideahvac |
| 0x2C   | Buzzer                         | byte3 != 0 = supported                    |

### dudanov Capability IDs (16-bit, includes type prefix):
```python
CAPABILITY_INDOOR_HUMIDITY         = 0x0015
CAPABILITY_SILKY_COOL              = 0x0018
CAPABILITY_SMART_EYE               = 0x0030
CAPABILITY_WIND_ON_ME              = 0x0032
CAPABILITY_WIND_OF_ME              = 0x0033
CAPABILITY_ACTIVE_CLEAN            = 0x0039
CAPABILITY_ONE_KEY_NO_WIND_ON_ME   = 0x0042
CAPABILITY_BREEZE_CONTROL          = 0x0043
CAPABILITY_FAN_SPEED_CONTROL       = 0x0210
CAPABILITY_PRESET_ECO              = 0x0212
CAPABILITY_PRESET_FREEZE_PROTECTION = 0x0213
CAPABILITY_MODES                   = 0x0214
CAPABILITY_SWING_MODES             = 0x0215
CAPABILITY_POWER                   = 0x0216
CAPABILITY_NEST                    = 0x0217
CAPABILITY_AUX_ELECTRIC_HEATING    = 0x0219
CAPABILITY_PRESET_TURBO            = 0x021A
CAPABILITY_HUMIDITY                = 0x021F
CAPABILITY_UNIT_CHANGEABLE         = 0x0222
CAPABILITY_LIGHT_CONTROL           = 0x0224
CAPABILITY_TEMPERATURES            = 0x0225
CAPABILITY_BUZZER                  = 0x022C
```

#### 3.4.2 Old Protocol B5 (Fixed format, msg_type=0x05)

Source: mill1000/midea-msmart Finding 9 (see `midea-msmart-mill1000.md`).
All fields: **Hypothesis** — single source, not verified against own captures.

Older devices respond with msg_type=0x05 and body[0]=0xB5. The response body uses a
fixed-format cursor-based layout rather than TLV records. A `cursor` pointer starts at
body[1] (property[0]):

| cursor+N | Field | Notes |
|----------|-------|-------|
| +5 | Power / mode / temp | Bit-packed, device-variant-specific |
| +7 | Fan speed | bits[6:0] |
| +8 | On-timer | Same encoding as 0xC0 |
| +9 | Off-timer | Same encoding as 0xC0 |
| +10 | Timer minutes | Same encoding as 0xC0 |
| +12 | Strong wind, sleep, power-saving | Various bits |
| +13 | PTC, secondary LR swing (under-unit) | |
| +14 | Natural wind | bit 6 (dataType=0x05 only) |
| +15 | Screen display, PMV | |
| +18 | No-wind-sense, prevent-straight-wind | |
| +19 | t2_heat threshold | See Finding 6 |
| +20 | tp_heat threshold | See Finding 6 |
| +21 | UD vane swing angle | bits[3:0] |
| +22 | Prevent super-cool (bit 6), fresh air (bit 7) | |
| +23 | Degerming | |
| +27 | Rewarming dry, PTC default rule, light sensitive | |
| +28 | Right fan wind speed | |
| +29-30 | Indoor CO2 | 16-bit LE |
| +31 | No-wind-sense L/R, moisturizing, linkage, linkage sync | |
| +36-41 | Fresh air mode, purifier mode, humidity | Only if body >= 33 bytes |
| +42 | Linkage fan speed | |
| +44 | Indoor temperature (integer) | |
| +45 | Indoor temperature (fractional, bits[3:0]) | |

**Extended B5 fields** (Finding 14d, cursor offsets for body >= 33 bytes):

| cursor+N | Field | Encoding |
|----------|-------|----------|
| +23 | degerming | bit 1 |
| +25 | aromatherapy (arom_old) | bit 7 |
| +27 | rewarming_dry (bit 1), ptc_default_rule (bit 5), light_sensitive (bits[7:6]) | |
| +31 | whirl_wind_right (bit 3), whirl_wind_left (bit 2) | |
| +31 | moisturizing (bit 7), linkage (bit 5), linkage_sync (bit 6) | |
| +36 | moisturizing_fan_speed | raw |
| +37 | fresh_air_mode (bits[3:0]), fresh_air_mode_two (bits[5:4]), purifier_mode (bit 6) | |
| +39 | inner_purifier_fan_speed | raw |
| +41 | five_dimension_mode (bits[1:0]), wind_no_linkage (bit 4) | |
| +42 | linkage_fan_speed | bits[6:0] |

Source: mill1000/midea-msmart Finding 14 (see `midea-msmart-mill1000.md`). **Hypothesis**.

**deviceSN8 variant temperature decoding** (Finding 14a): In old-protocol B5 responses
(dataType=0x05), the temperature field in body[1] uses different bit positions depending
on the device variant (identified by characters 13-17 of the serial number):

| Variant | Temperature bits | Half-degree bit | Models |
|---------|-----------------|-----------------|--------|
| CA models | `(body[1] & 0x7C) >> 2` + 12 | bit 1 | SN8: 11447, 11451, 11453, 11455, 11457, 11459, 11525, 11527, 11533, 11535 |
| All others | `(body[1] & 0x3E) >> 1` + 12 | bit 6 | Including Q11 (XtremeSaveBlue) |

Both variants produce the same range (12-43 C) but from different bit positions.

**Query frames**: Two pages sent sequentially:
- Page 1: `B5 01 00` (body[1]=0x01, body[2]=0x00)
- Page 2: `B5 01 01 01 21` (body[1]=0x01, body[2]=0x01, body[3]=0x01, body[4]=0x21)

**Dissector note**: The dissector does not currently distinguish old vs new B5 format
or deviceSN8 variants.

---

### 3.5 Command 0xB0/0xB1 — Property Protocol (newer devices) → Response: §4.6 (0xB1)

Source: mill1000/midea-msmart Finding 9 (see `midea-msmart-mill1000.md`).
All fields: **Hypothesis** — single source within mill1000/midea-msmart Finding 9, not verified against own captures.

A newer "property" protocol that supplements the 0x40/0x41 command set for features
not covered by the fixed-format body (indirect wind, breeze, fresh air, screen display).

#### Frame structure

**Property query** (0xB1, msg_type=0x03):
```
body[0] = 0xB1
body[1] = N_props (number of properties to query)
body[2..] = property IDs (2 bytes each: lo, hi)
```

**Property control** (0xB0, msg_type=0x02):
```
body[0] = 0xB0
body[1] = N_props
body[2..] = TLV entries: prop_id_lo, prop_id_hi, data_len, value_bytes...
```

**Response**: Same body[0] (0xB0 or 0xB1), TLV entries carry current values.

#### Known Property IDs

Property IDs are 2-byte little-endian (`lo, hi`):

| ID (lo, hi) | Name | data_len | Values / Notes |
|-------------|------|----------|----------------|
| 0x18, 0x00 | no_wind_sense | 1 or 2 | 2 bytes on specific device variants |
| 0x1A, 0x00 | tone / buzzer | 1 | 0x00=off, 0x01=on. Cross-ref: §3.1.4 buzzer mechanism #3 |
| 0x21, 0x00 | cool_hot_sense | 1 | |
| 0x26, 0x02 | auto_prevent_straight_wind | 1 | |
| 0x30, 0x00 | nobody_energy_save | 1 | |
| 0x32, 0x00 | wind_straight / wind_avoid | 1 | 0x01=straight, 0x02=avoid |
| 0x33, 0x00 | wind_avoid | 1 | |
| 0x34, 0x00 | intelligent_wind | 1 | |
| 0x39, 0x00 | self_clean | 1 | |
| 0x3A, 0x00 | child_prevent_cold_wind | 1 | |
| 0x3F, 0x00 | error_code_query | 1 | Query only |
| 0x41, 0x00 | mode_query | 1 | Query only |
| 0x42, 0x00 | prevent_straight_wind | 1 | Standard devices |
| 0x43, 0x00 | gentle_wind_sense | 1 | FA100 / flag variant |
| 0x47, 0x00 | high_temperature_monitor | 1 | |
| 0x48, 0x00 | rate_select | 1 | |
| 0x49, 0x00 | prevent_super_cool | 5 | value + 4 x 0xFF padding |
| 0x09, 0x00 | wind_swing_ud_angle | 1 | UD vane angle position |
| 0x0A, 0x00 | wind_swing_lr_angle | 1 | LR vane angle position |
| 0x0B, 0x02 | pm25_value | 3 | 16-bit LE PM2.5 concentration |
| 0x09, 0x04 | filter_level | 13 | Filter level + filter value |
| 0x15, 0x00 | indoor_humidity | 1 | Current indoor humidity % |
| 0x1B, 0x02 | little_angel | 1 | |
| 0x20, 0x00 | voice_control | 20 | Voice assistant control block |
| 0x24, 0x00 | volume_control | 4 | Volume level |
| 0x29, 0x00 | security | 1 | 0=off, 2→off, 3→on |
| 0x31, 0x00 | intelligent_control | 1 | |
| 0x44, 0x00 | face_register | 1 | Face recognition |
| 0x4A, 0x00 | water_washing | 4 | manual/auto/time/stage |
| 0x4B, 0x00 | fresh_air | 3 | switch/fan_speed/temp |
| 0x4C, 0x00 | extreme_wind | 2 | value + level |
| 0x4E, 0x00 | even_wind | 1 | |
| 0x4F, 0x00 | single_tuyere | 1 | Single outlet mode |
| 0x50, 0x00 | water_pump | 1 | |
| 0x51, 0x00 | parent_control | 5 | switch + temp up/down limits |
| 0x58, 0x00 | prevent_straight_wind_lr | 1 | LR-specific wind direction |
| 0x59, 0x00 | wind_around | 2 | value + ud mode |
| 0x67, 0x00 | jet_cool | 1 | |
| 0x8D, 0x00 | mito_cool | 1 | Temperature: `(raw - 50) / 2` |
| 0x8E, 0x00 | mito_heat | 1 | Temperature: `(raw - 50) / 2` |
| 0x8F, 0x00 | dr_time | 2 | minutes + hours |
| 0x90, 0x00 | cool_heat_amount | 11 | Contains t2_heat, tp_heat, k1-k4, strong wind speed/amount |
| 0x91, 0x00 | has_icheck | 1 | iCheck capability flag |
| 0x98, 0x00 | cvp | 1 | |
| 0xAA, 0x00 | new_wind_sense | 1 | |
| 0xAB, 0x00 | indoor_unit_code | var | 16-byte ASCII code + 4-byte version |
| 0xAC, 0x00 | outdoor_unit_code | var | 16-byte ASCII code + 4-byte version |
| 0xAD, 0x00 | comfort | 1 | |
| 0xE0, 0x00 | ieco_frame | 10 | frame/target_rate/wind_speeds/expansion_valve |
| 0xE3, 0x00 | ieco_switch | 2 | number + switch |
| 0x01, 0x02 | pre_cool_hot | 1 | Pre-cool/heat mode |
| 0x25, 0x02 | temperature_ranges | 7 | cool/auto/heat min+max (6 bytes) |
| 0x27, 0x02 | remote_control_lock | 2 | lock + control values |
| 0x28, 0x02 | operating_time | 3 | 24-bit LE total |
| 0x30, 0x02 | main_horizontal_guide_strip | 4 | 4 position values |
| 0x31, 0x02 | sup_horizontal_guide_strip | 4 | 4 supplementary positions |
| 0x34, 0x02 | body_check | 1 | |

Source: mill1000/midea-msmart Finding 9 (see `midea-msmart-mill1000.md`), validated
2026-03-28 against mill1000/midea-msmart Finding 9 source material. Property 0x90,0x00 (`cool_heat_amount`)
also contains t2_heat and tp_heat — an alternative location for the Finding 6 fields.

**Dissector note**: The dissector parses 0xB0/0xB1 frames generically as TLV but does not
decode property IDs by name. Enhancement opportunity.

---

## 4. Responses (Appliance → Dongle)

### 4.1 Response 0xC0 — Current AC Status ← Triggered by: §3.1.1 (0x41 status query), §3.2 (0x40 set), §3.1.4.6 (Follow Me temp)

The AC responds to 0x40 (set) and 0x41 (query) with a **0xC0** response.

**0xA0 variant**: msg_type `0x05` with body[0] = `0xA0` uses the same field layout
as `0xC0`. Purpose unknown — treat as Hypothesis.
Source: mill1000/midea-msmart Finding 9 (see `midea-msmart-mill1000.md`).

**Multi-unit / new protocol detection**:
- `body[0] == 0xBC` or `0xBA` → multi-unit protocol variant
- `body[0] == 0xBF` → "new protocol" variant
These trigger alternate parsing paths. Not yet seen in own captures.
Source: mill1000/midea-msmart Finding 9 (see `midea-msmart-mill1000.md`).

Response data starts at frame offset 10. The response `data[0]` = `0xC0`.
All byte references below are **relative to body start** (body[0] = `0xC0`).

```
Body
Byte  Bits        Field                   Formula
----  ----        -----                   -------
 0    [7:0]       0xC0 (response ID)

 1    bit 0       Power ON                bool
      bit 2       Resume                  bool
      bit 4       Timer mode              uint8
      bit 5       Test2                   bool
      bit 7       In error                bool

 2    bits [3:0]  Temperature setpoint     value + 16 (Celsius)
      bit 4       Temperature decimal      +0.5C if set
      bits [7:5]  Operating mode           see Mode enum

 3    bits [6:0]  Fan speed               0-100, 101=fixed, 102=auto

 4    bit 7       On-timer enabled
      bits [6:2]  On-timer hours
      bits [1:0]  On-timer quarter high

 5    bit 7       Off-timer enabled
      bits [6:2]  Off-timer hours
      bits [1:0]  Off-timer quarter high

 6    bits [7:4]  On-timer minutes elapsed
      bits [3:0]  Off-timer minutes elapsed

 7    bits [1:0]  Left-right fan (horizontal swing)
      bits [3:2]  Up-down fan (vertical swing)
      (NeoAcheron: byte & 0x0F = swing_mode)

 8    bits [1:0]  Cosy sleep mode (0-3)
      bit 2       Alarm sleep
      bit 3       Power save (powerSave)
      bit 4       Low frequency fan (farceWind / low wind)
      bit 5       Turbo mode (strong)
      bit 6       Energy save (energySave)
      bit 7       Follow Me (bodySense) — see §3.1.4.7; OQ-16 resolved

 9    bit 0       Child sleep
      bit 1       Natural fan
      bit 2       Dry clean
      bits [4:3]  PTC heater (2-bit field, PTCValue = bits[4:3] combined; Finding 5)
      bit 4       Eco mode (read position in 0xC0 response)
                  NOTE: ECO has different bit positions for read vs write:
                  bit 4 here in the 0xC0 response (read), bit 7 in the 0x40 SET
                  command (write) — see §3.2 body[9]. Source: mill1000/midea-msmart
                  Findings 4–5 (see `midea-msmart-mill1000.md`).
      bit 5       Clean up / purifier
      bit 6       Self cosy sleep
      bit 7       localBodySense — built-in occupancy sensor active.
                  **Hypothesis** (mill1000/midea-msmart Finding 10b, OQ-17).
                  Own captures: always 0x00 (test unit has no occupancy sensor).
                  See §3.1.4.7 for the three body-sensing feature types.

10    bit 0       Sleep mode
      bit 1       Turbo mode (primary)
      bit 2       Temperature unit (0=C)
      bit 3       Exchange air
      bit 4       Night light
      bit 5       Catch cold
      bit 6       Peak elec
      bit 7       Cool fan

11    [7:0]       Indoor temperature       (value - 50) / 2.0  (Celsius)

12    [7:0]       Outdoor temperature      (value - 50) / 2.0  (Celsius)

13    bit 5       Dust full
      bits [4:0]  New temperature           value + 12 (if > 0, overrides byte 2 setpoint)

14    bits [6:4]  Light/display             0x70 = on (all 3 bits set) — **Disputed** (see Appendix A)
      bits [3:0]  PMV (predicted mean vote)  thermal comfort index, see table below

15    bits [3:0]  Indoor temp decimal (t1Dot, tenths of degree)
      bits [7:4]  Outdoor temp decimal (t4Dot, tenths of degree)

16    [7:0]       Error code (0-33)

17    (reserved)

18    (reserved)

19    bits [6:0]  Humidity setpoint (0-100)

20    (reserved)

21    bit 7       Frost protection mode
      bit 6       Double temp

22    bit 3       Silky cool (see note below)
```

**body[8] bit 7 — Follow Me active (bodySense)**: When set, indicates the unit is using
the remote/phone temperature as the room reference instead of its own sensor. See §3.1.4.6
for the Follow Me temperature push mechanism and §3.1.4.7 for the enable/readback table.
**Confirmed** — own R/T captures (Sessions 3–8) + mill1000/midea-msmart Finding 10.

**body[14] bits[3:0] — PMV (Predicted Mean Vote)**: A thermal comfort index based on the
ISO 7730 / ASHRAE 55 PMV scale. Encoding: `pmv = (bits[3:0]) * 0.5 - 3.5`.
Source: reneklootwijk/node-mideahvac. **Consistent** (node-mideahvac + mill1000/midea-msmart reference agree).

| Raw (bits[3:0]) | PMV value | Description |
|-----------------|-----------|-------------|
| 0 | 99 (off) | PMV disabled |
| 1 | -3.0 | Cold |
| 2 | -2.5 | Chill |
| 3 | -2.0 | Chill |
| 4 | -1.5 | Cool |
| 5 | -1.0 | Cool |
| 6 | -0.5 | Comfortable |
| 7 | 0.0 | Comfortable (neutral) |
| 8 | 0.5 | Comfortable |
| 9 | 1.0 | Slightly warm |
| 10 | 1.5 | Slightly warm |
| 11 | 2.0 | Warm |
| 12 | 2.5 | Warm |

Value 0 = "99" in node-mideahvac represents PMV disabled / not active.

**body[14] bits[6:4] — Display state**: **Disputed** between sources:
- This document + dissector: `bits[6:4] == 0x7` → display ON
- midea-local: `bits[6:4] != 0x7` → display ON (inverted logic), also gated on power ON

Requires hardware verification. See Appendix A.

**body[22] — Silky cool**: This byte only exists when the response body is at least 23 bytes.
Some firmware versions return shorter C0 bodies (22 bytes or fewer), omitting this field.
The capability flag `SILKY_COOL` (0x0018) in the B5 response (§3.4) indicates whether the
unit supports this feature. Silky cool is a gentle-cooling mode that reduces draft sensation.
**Hypothesis** — not tested on own hardware.

### Alternative temperature packing in 0xC0 response:

An alternative format flag may cause the setpoint temperature to be decoded
from body byte[1] instead of byte[2]:

- **Standard format** (byte[2]): `temp = (byte[2] & 0x0F) + 16`, `half = (byte[2] >> 4) & 0x01`
  — this is the format documented above and consistent with all other sources.
- **Alternative format A** (byte[1] bits[6:1]): `temp = (byte[1] >> 2) & 0x1F` (bits[6:2]) `+ 12`,
  `half = byte[1] & 0x01` (bit 0)
- **Alternative format B** (byte[1] bits[5:1]): `temp = (byte[1] >> 1) & 0x1F` (bits[5:1]) `+ 12`,
  `half = (byte[1] >> 6) & 0x01` (bit 6)

The trigger condition for selecting between formats is not fully understood.
**Hypothesis**: these are protocol version variants (older appliances may use the
byte[1] packing). Not yet observed in own captures — treat as Hypothesis.
Source: mill1000/midea-msmart (see `midea-msmart-mill1000.md`).

### Temperature Parsing with Decimal Precision:
```python
def parse_temperature(integer_byte, decimal_nibble, fahrenheits=False):
    """Parse indoor/outdoor temperature.
    integer_byte: body[11] or body[12]
    decimal_nibble: body[15] lower or upper nibble
    """
    integer = integer_byte - 50
    temp = integer / 2.0

    if not fahrenheits and decimal_nibble > 0:
        # Add decimal precision (tenths)
        if integer >= 0:
            temp = (integer // 2) + decimal_nibble * 0.1
        else:
            temp = (integer // 2) - decimal_nibble * 0.1

    if decimal_nibble >= 5:
        if integer >= 0:
            temp += 0.5
        else:
            temp -= 0.5

    return temp

indoor_temp  = parse_temperature(body[11], body[15] & 0x0F)
outdoor_temp = parse_temperature(body[12], (body[15] >> 4) & 0x0F)
```

### NeoAcheron Response Parsing (alternative offsets)
NeoAcheron strips a 0x32-byte (50-byte) network header, so their `data[0x01]` = our `body[1]`:
```
NeoAcheron    Our Body    Field
data[0x01]    body[1]     power, resume, timer, error
data[0x02]    body[2]     mode + temperature
data[0x03]    body[3]     fan speed
data[0x07]    body[7]     swing mode
data[0x08]    body[8]     cosy sleep, turbo2
data[0x09]    body[9]     eco, child sleep, etc.
data[0x0a]    body[10]    sleep, turbo, night light
data[0x0b]    body[11]    indoor temperature
data[0x0c]    body[12]    outdoor temperature
data[0x0d]    body[13]    humidity (& 0x7F)
```

---

### 4.2 Response 0xC1 — Extended (Group Pages, Power, Extended State) ← Triggered by: §3.1.2 (group page query), §3.1.3 (power query), §3.1.4.5 (extended state query)

`body[0] = 0xC1` covers multiple sub-types. **Dispatch by body[1]/body[2] first:**

| Priority | Condition | Sub-type | Triggered by |
|----------|-----------|----------|--------------|
| 1 | `body[1] == 0x21 and body[2] == 0x01` | Group page response (groups 1-5+, incl. power) | `0x41/0x81/0x01/page` or `0x41/0x21/0x01/page` query |
| 2 | `body[1] == 0x01` | Extended state sub-page 0x01 (sensors, faults) | Extended `0x41/0x21` query — mill1000/midea-msmart Finding 8 (see `midea-msmart-mill1000.md`) |
| 3 | `body[1] == 0x02` | Extended state sub-page 0x02 (flags, power, vanes) | Extended `0x41/0x21` query — mill1000/midea-msmart Finding 8 (see `midea-msmart-mill1000.md`) |
| — | other | Unknown | — |

Group page responses dispatch further by `body[3] & 0x0F` as group number (mill1000/midea-msmart Finding 11, see `midea-msmart-mill1000.md`).
Group 4 (`body[3]=0x44`) is the power usage page — previously handled as a separate
top-level sub-type, now unified under the group page dispatcher.

> Do not call all 0xC1 frames "Power Response" — this is incorrect for group-page and extended-state variants.

`0xC1` group page response common header (body[1]=`0x21`, body[2]=`0x01`, body[3]=page echo):
```
Page 0x41 response:  C1 21 01 41  [20 data bytes]
Page 0x42 response:  C1 21 01 42  [20 data bytes]
Page 0x43 response:  C1 21 01 03  [20 data bytes]  (body[3]=0x03, not 0x43 — see Group 3 note)
Page 0x45 response:  C1 21 01 45  [16 data bytes]
```

#### 4.2.1 Group 1 (body[3]=0x41) — Base Run Info (R/T bus) ← Triggered by: §3.1.2

Source: own Session 1 captures (15 frames, 13 unique bodies, R/T bus, 83-second window).
Field labels from mill1000/midea-msmart (see `midea-msmart-mill1000.md`, Finding 11).
**Session 6 service menu ground truth** confirms T1, T3, T4 formulas and Tp encoding.
Cross-session comparison (Sessions 3–8, 329 matched pairs vs XYE byte[22]) confirms Tp.

| Offset | Bytes | Observed values | Field | Encoding | Confidence |
|--------|-------|-----------------|-------|----------|------------|
| body[4] | 1 | 0x00, 0x0E, 0x17, 0x20, 0x29 | Compressor actual frequency | raw Hz | Hypothesis |
| body[5] | 1 | 0x00, 0x0F, 0x1C | Indoor target frequency | raw | Hypothesis |
| body[6] | 1 | 0x00 or 0x01 | Compressor current | raw (unit unclear) | Hypothesis |
| body[7] | 1 | 0x01 or 0x02 | Outdoor total current | raw × 4 | Hypothesis |
| body[8] | 1 | varies | Outdoor supply voltage | raw | Hypothesis |
| body[9] | 1 | varies | Indoor actual operating mode | raw | Hypothesis |
| body[10] | 1 | varies | T1 indoor coil temp | (val−30)/2 °C (offset 30) | **Confirmed S6** (raw=0x42→18°C) |
| body[11] | 1 | varies | T2 temp | (val−30)/2 °C (offset 30) | Hypothesis |
| body[12] | 1 | varies | T3 outdoor coil temp | (val−50)/2 °C (offset 50) | **Confirmed S6** (raw=0x36→2°C) |
| body[13] | 1 | varies | T4 outdoor ambient temp | (val−50)/2 °C (offset 50) | **Confirmed S6** (raw=0x3B→4.5°C≈4°C) |
| body[14] | 1 | 0x1C–0x1E (S1); 0x37–0x4A (S3–S8) | Discharge pipe temp (Tp) | **direct integer °C** | **Confirmed** — S6: raw=0x4A=74→74°C; cross-UART: 329 pairs mean diff −0.02°C |
| body[15] | 1 | 0x00 | Outdoor DC fan stator flux | raw | Hypothesis |
| body[16] | 1 | 0x00 | Outdoor voltage (duplicate?) | raw | Hypothesis |
| body[17] | 1 | 0x00 | Indoor fan stator flux | raw | Hypothesis |
| body[18..23] | 6 | 0x00 | Beyond Group 1 fields | — | Consistent |

**Previous interpretation corrected**: body[8..9] was previously read as a single
16-bit LE value (range 991–1515). Finding 11 shows these are **two separate single-byte
fields** (outdoor voltage + indoor operating mode). Similarly, body[10..13] (previously
"Unknown — all vary independently") are four individual temperature sensor readings
(T1–T4) with different offset encodings. body[14] (previously "slow counter") is
the discharge pipe temperature — the slow increment is consistent with thermal inertia.
Tp encoding is **direct integer °C**: the outdoor unit MCU applies ucPQTempTab (NTC
thermistor lookup) internally and transmits the result. The Session 1 low values
(28–30°C) reflect cold-start warm-up; Sessions 3–8 show 6–74°C under varying load.

---

#### 4.2.2 Group 2 (body[3]=0x42) — Indoor Device Params (R/T bus) ← Triggered by: §3.1.2

Source: own Session 1 captures, 15 frames, 6 unique bodies.
Field labels from mill1000/midea-msmart (see `midea-msmart-mill1000.md`, Finding 11).
All labels **Hypothesis** — single source, not verified at field level against own captures.

```
Example frames (body[0..25]):
count=7  C1 21 01 42  00 00 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 00 00 00  (sentinel)
count=4  C1 21 01 42  57 57 00 00 00 00 00 00 40 01 00 00 00 00 00 00 00 00 00 00  (18.5/18.5°C)
count=1  C1 21 01 42  57 4C 00 00 00 00 00 00 40 01 00 00 00 00 00 00 00 00 00 00  (18.5/13.0°C)
count=1  C1 21 01 42  57 56 00 00 00 00 00 00 40 01 00 00 00 00 00 00 00 00 00 00  (18.5/18.0°C)
count=1  C1 21 01 42  6B 62 00 00 00 00 00 00 40 01 00 00 00 00 00 00 00 00 00 00  (28.5/24.0°C)
count=1  C1 21 01 42  6B 6B 00 00 00 00 00 00 40 01 00 00 00 00 00 00 00 00 00 00  (28.5/28.5°C)
```

**Finding 11 field map (Group 2)** vs own captures — **mismatch**:

Group 2 expects: body[4]=indoor set fan speed (×8 RPM), body[5]=indoor actual fan speed (×8 RPM),
body[6..8]=indoor fault bytes, body[9..11]=freq-limit bytes, body[12..13]=load state bytes,
body[14]=E2 param version, body[15..19]=child/smart-eye detection.

Own captures show: body[4..5] = values 0x4C–0x6B consistent with `(val−50)/2` temperature
encoding (13–28.5 °C), body[12] = 0x40 flag. These values **do not match** Group 2 RPM
fields (×8 would give 608–856 RPM — plausible but the temperature interpretation also
fits). The sentinel pattern (body[4]=body[5]=0x00 in 7/15 frames) is unusual for fan speed.

**Status**: Finding 11 Group 2 labels applied provisionally. The R/T bus may use a
different field layout than the Wi-Fi path for page 0x42. **Disputed** — own captures
are ambiguous; needs dedicated testing with known fan speed changes.

Previous own-capture analysis (retained for reference):

| Offset | Bytes | Observed values | Own capture label | Confidence |
|--------|-------|-----------------|-------------------|------------|
| body[4] | 1 | 0x00 (sentinel) or 0x4C–0x6B | Temperature A: `(val−50)/2` °C; 0x00 = sensor unavailable | Hypothesis |
| body[5] | 1 | 0x00 (sentinel) or 0x4C–0x6B | Temperature B: `(val−50)/2` °C; 0x00 = sensor unavailable | Hypothesis |
| body[6..11] | 6 | 0x00 constant | Reserved / unused | Consistent |
| body[12] | 1 | 0x00 (sentinel) or 0x40 | Data-valid flag: 0x40 when temperature data present | Hypothesis |
| body[13] | 1 | 0x00 (sentinel) or 0x01 | Correlated with body[12]; meaning unknown | Hypothesis |
| body[14..23] | 10 | 0x00 constant | Reserved / unused | Consistent |

**Note**: `0x42/0x00` = `prevent_straight_wind` in the 0xB1 property protocol is a
**different bus protocol layer** — no direct field mapping to R/T bus group pages. **Disputed**.

---

#### 4.2.3 Group 3 (body[3]=0x43/0x03) — Outdoor Device Params (R/T bus) ← Triggered by: §3.1.2

Source: own Session 1 captures, 14 frames, 7 unique bodies. All responses have
body[3]=`0x03`, not `0x43` — the page ID is not echoed directly.
Field labels from mill1000/midea-msmart (see `midea-msmart-mill1000.md`, Finding 11).

```
Example frames (body[0..25]):
count=5  C1 21 01 03  00 00 00 00 00 08 00 1B 72 AF B3 00 00 00 00 00 00 00 00 00  (sentinel temp)
count=2  C1 21 01 03  00 00 00 00 00 08 17 32 72 AC B3 00 39 00 00 00 00 00 00 00
count=2  C1 21 01 03  00 00 00 00 00 08 4C 3E 72 AC B3 00 39 00 00 00 00 00 00 00
count=2  C1 21 01 03  00 00 00 00 00 08 61 3C 72 AD B3 00 00 00 00 00 00 00 00 00
```

**body[3] anomaly explained**: body[3]=`0x03` → `0x03 & 0x0F = 3` = Group 3. The group
dispatch works correctly despite the non-echoed page ID. Finding 11 confirms the
dispatch uses `body[3] & 0x0F`, not the full byte.

**Finding 11 field map (Group 3)** vs own captures:

| Offset | Bytes | Observed | Finding 11 field | Encoding | Fit with captures | Confidence |
|--------|-------|----------|------------------|----------|-------------------|------------|
| body[4..8] | 5 | 0x00 constant | Outdoor device state 1-5 | 8-bit packed flags | Consistent (no outdoor faults) | Hypothesis |
| body[9] | 1 | 0x08 constant | Outdoor device state 6 | 8-bit packed flags | Consistent (bit3=4-way valve?) | Hypothesis |
| body[10] | 1 | 0x00/0x17/0x4C/0x61 | Outdoor DC fan speed | raw × 8 RPM → 0/184/608/776 RPM | Plausible | Hypothesis |
| body[11] | 1 | 0x1B–0x3E | EEV position | raw × 8 steps → 216–496 steps | Plausible | Hypothesis |
| body[12] | 1 | 0x72 constant | Outdoor return air temp | raw AD value (=114) | Plausible | Hypothesis |
| body[13] | 1 | 0xA9–0xB3 | Outdoor DC bus voltage | raw (169–179) | Plausible for DC bus | Hypothesis |
| body[14] | 1 | 0xB3 constant | IPM module temp | raw °C (=179?) | High for °C — **Disputed** | Disputed |
| body[15] | 1 | 0x00 | Outdoor load state | raw | Consistent (idle) | Hypothesis |
| body[16] | 1 | 0x00/0x39 | Outdoor target compressor freq | raw Hz (0/57) | Plausible | Hypothesis |
| body[17..23] | 7 | 0x00 | Beyond Group 3 fields | — | Consistent | — |

**Previous interpretation corrected**: body[10..11] were previously labeled as temperatures
using `(val−50)/2`. Finding 11 shows they are outdoor DC fan speed (×8 RPM) and EEV
position (×8 steps). body[12] (0x72=114) was "unknown constant" — now identified as outdoor
return air temperature (raw AD, not `(val-50)/2`). body[14] (0xB3=179) as IPM temperature
seems too high for °C — may be a raw AD value requiring a lookup table. **Disputed**.

**Note**: `0x43/0x00` = `gentle_wind_sense` / `prevent_straight_wind_flag` in 0xB1
property protocol is a **different bus protocol layer**. **Disputed**.

---

#### 4.2.4 Group 4 (body[3]=0x44) — Power Usage Response — BCD kWh ← Triggered by: §3.1.3

body[0] = `0xC1`, body[3] = `0x44`.

Four power fields, each BCD-encoded. `bcd(b) = ((b >> 4) & 0xF) * 10 + (b & 0xF)`.

| body offset | Field | Formula | Unit | Notes |
|-------------|-------|---------|------|-------|
| [4..7] | totalPowerConsume | `bcd[4]×10000 + bcd[5]×100 + bcd[6] + bcd[7]/100` | kWh | Cumulative lifetime energy |
| [8..11] | totalRunPower | same 4-byte pattern | kWh | All zeros in own captures |
| [12..15] | curRunPower | same 4-byte pattern | kWh | All zeros in own captures |
| [16..18] | curRealTimePower | `bcd[16] + bcd[17]/100 + bcd[18]/10000` | kW | Instantaneous draw |

Note: nibbles > 9 (e.g. 0xA=10, 0xD=13, 0xF=15) appear in the data and are treated
as their hex integer value by `bcd()` — effectively hexadecimal digit encoding, not strict BCD.

---

#### 4.2.5 Group 5 (body[3]=0x45) — Extended Params (R/T bus) ← Triggered by: §3.1.2

Source: own Session 1 captures, 5 frames, 5 unique bodies. No corresponding
`41 81 01 45` request found — possible spontaneous/pushed response.
Field labels from mill1000/midea-msmart (see `midea-msmart-mill1000.md`, Finding 11).

```
Example frames (body[0..22], 23 bytes total):
count=1  C1 21 01 45  00 4A 26 1B 00 1B 00 00 00 00 33 07 00 B7 88 00 04 79 6B
count=1  C1 21 01 45  00 4A 26 1B 00 1B 00 00 00 00 33 07 00 B7 88 00 DF 0E FB
count=1  C1 21 01 45  00 52 26 1B 00 1B 00 00 00 00 33 07 00 B7 88 00 25 08 B3
count=1  C1 21 01 45  00 50 26 1B 61 3E 00 00 00 00 33 07 00 B7 88 00 4D 7A 97
count=1  C1 21 01 45  00 50 26 1B 61 3E 00 00 00 00 33 07 00 B7 88 00 9E CF F1
```

**Finding 11 field map (Group 5)** vs own captures:

| Offset | Bytes | Observed | Finding 11 field | Encoding | Fit with captures | Confidence |
|--------|-------|----------|------------------|----------|-------------------|------------|
| body[4] | 1 | 0x00 | Humidity | raw % | Consistent (0% = sensor idle?) | Hypothesis |
| body[5] | 1 | 0x4A/0x50/0x52 | Compensated temp setpoint (Tsc) | raw | 74/80/82 — plausible raw Tsc | Hypothesis |
| body[6] | 1 | 0x26 | Indoor fan runtime (lo) | 16-bit LE with body[7] | 0x1B26 = 6950 min ≈ 116 h | Hypothesis |
| body[7] | 1 | 0x1B | Indoor fan runtime (hi) | | — | Hypothesis |
| body[8] | 1 | 0x00/0x61 | Outdoor fan target speed | raw ×8 → 0/776 RPM | Plausible | Hypothesis |
| body[9] | 1 | 0x1B/0x3E | EEV target angle | raw ×8 → 216/496 steps | Plausible (correlated with body[8]) | Hypothesis |
| body[10] | 1 | 0x00 | Defrost step | 0=none | Consistent | Hypothesis |
| body[11] | 1 | 0x00 | Outdoor state 7 (reserved) | raw | Consistent | Hypothesis |
| body[12] | 1 | 0x00 | Outdoor state 8 (reserved) | raw | Consistent | Hypothesis |
| body[13] | 1 | 0x00 | Compressor run time | raw ×64 s | Consistent (idle) | Hypothesis |
| body[14] | 1 | 0x33 | Compressor cumul. time (lo) | 16-bit LE with body[15] | 0x0733 = 1843 h | Hypothesis |
| body[15] | 1 | 0x07 | Compressor cumul. time (hi) | | — | Hypothesis |
| body[16] | 1 | 0x00 | Freq-limit type 2 | raw | Consistent | Hypothesis |
| body[17] | 1 | 0xB7 | Max bus voltage | raw + 60 → 243 V | Plausible (≈240V mains) | Hypothesis |
| body[18] | 1 | 0x88 | Min bus voltage | raw + 60 → 196 V | Plausible (sag during startup) | Hypothesis |
| body[19] | 1 | 0x00 | Beyond Group 5 fields | — | — | — |
| body[20..22] | 3 | Varies | Frame tail (CRC/checksum area) | not protocol data | Hypothesis |

**Previous unknowns now decoded**: The constant pattern `26 1B ... 33 07 00 B7 88` is
actually: indoor fan runtime = 6950 min, compressor cumulative runtime = 1843 h,
max voltage = 243V, min voltage = 196V — all plausible historical counters for a unit
in service. body[5] (0x4A–0x52) previously guessed as temperature is actually the
compensated setpoint (Tsc) — a raw internal value, not `(val-50)/2`.

#### 4.2.6 Group 0 (body[3]=0x40) — Power-On / Run Time Counters

Source: mill1000/midea-msmart Finding 11 (see `midea-msmart-mill1000.md`).
**Not observed in own captures.** All fields: **Hypothesis**.

`body[3] & 0x0F == 0`. Response contains three sets of day/hour/minute/second counters.

| body[] | Field | Encoding | Notes |
|--------|-------|----------|-------|
| [4-5] | Power-on days | 16-bit BE | Time since last power-on |
| [6] | Power-on hours | raw | |
| [7] | Power-on minutes | raw | |
| [8] | Power-on seconds | raw | |
| [9-10] | Total worked days | 16-bit BE | Cumulative lifetime |
| [11] | Total worked hours | raw | |
| [12] | Total worked minutes | raw | |
| [13] | Total worked seconds | raw | |
| [14-15] | Current worked days | 16-bit BE | Current session |
| [16] | Current worked hours | raw | |
| [17] | Current worked minutes | raw | |
| [18] | Current worked seconds | raw | |

**Cross-reference**: The A1 heartbeat (§5.2) also carries `curWorkedDay/Hour/Min` at
body[9-12], but those fields are not implemented on Q11 (always zero). Group 0 may
provide the same data via the group page path.

**Note**: Days use **16-bit big-endian** byte order — verify whether this is consistent
with the 16-bit **little-endian** used in Group 5 (indoor fan runtime, compressor time).

---

#### 4.2.7 Group 6 (body[3]=0x46) — Extended Diagnostics

Source: mill1000/midea-msmart Finding 11 (see `midea-msmart-mill1000.md`).
**Not observed in own captures.** All fields: **Hypothesis**.

`body[3] & 0x0F == 6`. Contains historical peak values and motor control diagnostics.

| body[] | Field | Encoding | Notes |
|--------|-------|----------|-------|
| [4] | Max current (historical) | raw | Peak compressor current |
| [5] | Max T4 temp (historical) | raw | Peak outdoor ambient |
| [6] | Min T4 temp (historical) | raw | Lowest outdoor ambient |
| [7] | Cumulative fault count | raw | Lifetime fault counter |
| [8] | Compressor flux | raw x 8 | Stator magnetic flux |
| [9] | Fan flux | raw x 8 | Fan motor magnetic flux |
| [10] | d-axis current | raw x 64 | FOC d-axis component |
| [11] | q-axis current | raw x 64 | FOC q-axis component |
| [12] | Compressor peak current | raw | |
| [13] | PFC peak current | raw | Power factor correction |
| [14] | Fan peak current | raw | |
| [15-16] | Torque adjust angle | 16-bit LE | Motor torque compensation |
| [17] | Torque adjust value | raw x 8 | |
| [18] | AD calibration voltage 1 | raw x 16 | ADC reference calibration |

**Cross-reference**: Fields [4]-[7] (max current, max/min T4, fault count) overlap with
Extended State sub-page 0x02 (§4.3.2) body[26]-[29]. Same data, different query path.

---

#### 4.2.8 Group 11 (body[3]=0x4B) — Louver / Vane Angles

Source: mill1000/midea-msmart Finding 11 (see `midea-msmart-mill1000.md`).
**Not observed in own captures.** All fields: **Hypothesis**.

`body[3] & 0x0F == 11` (0x0B). Contains vane/louver swing states and angle limits.

| body[] | Field | Encoding | Notes |
|--------|-------|----------|-------|
| [4] bits[1:0] | UD vane swing state | 2-bit | Up-down swing active |
| [4] bits[3:2] | LR vane swing state | 2-bit | Left-right swing active |
| [4] bits[5:4] | Top vane swing state | 2-bit | Top louver swing active |
| [5] | UD vane cool upper limit | raw % | |
| [6] | UD vane cool lower limit | raw % | |
| [7] | UD vane heat upper limit | raw % | |
| [8] | UD vane heat lower limit | raw % | |
| [9] | UD vane current angle | raw % | Actual position |
| [10] | LR vane upper limit | raw % | |
| [11] | LR vane lower limit | raw % | |
| [12] | LR vane current angle | raw % | Actual position |
| [13] | Top vane upper limit | raw % | |
| [14] | Top vane lower limit | raw % | |
| [15] | Top vane current angle | raw % | Actual position |

**Cross-reference**: Vane angle fields overlap with Extended State sub-page 0x02 (§4.3.2)
body[49]-[56] (UD/LR vane cool/heat limits and current angles). Group 11 adds top vane
fields not present in sub-page 0x02.

**Dissector note**: The dissector's `group_page_names` table already lists Group 11 as
"Wind Blade Control" but no field-level parsing is implemented.

---

### 4.4 Response 0x93 — Extension Board Status (30 bytes, R/T bus) ← Triggered by: §3.3 (0x93 request)

```
[0]   0x93
[1]   0x00
[2]   0x00
[3]   0x84 / 0x94 / 0x00  (varies — possibly a status code)
[4..8]   0x00
[9]   0x10
[10]  0x30
[11]  0x05
[12]  0x00
[13]  0x02
[14]  0x30
[15]  0x0E
[16]  0x00
[17]  0xBC  (constant across all responses)
[18]  0xD6  (constant)
[19]  0x60 / 0x64  (varies slightly)
[20..23]  0x00
[24..27]  0x80 0x80 0x80 0x80  (4-zone status? all 0x80 = nominal?)
[28..29]  0x00
```

Captured responses:
```
55 BC 28 AC ... C1 21 01 41 00 00 00 00 00 10 30 05 00 02 30 0E 00 BC D6 60 00 00 00 00 80 80 80 80 00 00
```

Field meanings are **Unknown**. The four `0x80` bytes at body[24..27] are consistent
across captures and may represent per-zone operating status.

---

## 5. Notifications (Mainboard → Dongle, unsolicited)

### 5.1 Notification Types

| Body type | msg_type | Name | Decode status |
|---|---|---|---|
| `0xA0` | `0x05` | Heartbeat ACK | **Confirmed** — C0-format body (identical field layout to 0xC0, see section 6) |
| `0xA1` | `0x04` | Heartbeat energy/temps | **Confirmed** — full decode, see below |
| `0xA2` | `0x04` | Heartbeat device params | **Unknown** — not decoded in mill1000/midea-msmart (see `midea-msmart-mill1000.md`) |
| `0xA3` | `0x04` | Heartbeat device params 2 | **Unknown** — not decoded in mill1000/midea-msmart (see `midea-msmart-mill1000.md`) |
| `0xA5` | `0x04` | Heartbeat outdoor unit | **Unknown** — not decoded in mill1000/midea-msmart (see `midea-msmart-mill1000.md`) |
| `0xA6` | `0x04` | Heartbeat network info | **Unknown** — not decoded in mill1000/midea-msmart (see `midea-msmart-mill1000.md`) |
| `0xBB` | — | XBB sub-protocol | Used by newer "SN8" units; completely different encoding |
| `0xB0/0xB1` | `0x02/0x03` | TLV set/response | Tag-value pairs for indirect wind, breeze, fresh air, screen display |

---

### 5.2 Heartbeat 0xA1 — Energy and Temperatures (confirmed)

**Sources**: mill1000/midea-msmart Finding 12 (see midea-msmart-mill1000.md).
**Cross-validated** against Session 9 frame `AA 2B AC 00 00 00 00 00 02 04 A1 00 01 0D 8B 00 00 00 00 00 00 00 00 68 3A 00 00 00 24 00 00 00 00 00 00 00 00 00 00 00 00 00 00 9F F0 94`.

| body[] | Reference field name (Q14) | Reference field name (Q11) | Formula | Status |
|--------|--------------|---------------|---------|--------|
| `[0]` | cmd_id | — | — | — |
| `[1..4]` | `totalPowerConsume` | (not decoded) | BCD kWh: `bcd[1]×10000 + bcd[2]×100 + bcd[3] + bcd[4]/100` | **Confirmed** |
| `[5..8]` | `totalRunPower` | (not decoded) | BCD kWh (same) | Consistent — always 0 on Q11 |
| `[9..12]` | `curWorkedDay/Hour/Min` | days/hours/mins | 16-bit BE days + byte hours + byte mins | **Not implemented on Q11** — always 0 |
| `[13]` | `t1Temp` | `indoorTemperatureValue` | `(raw−50)/2`, skip 0x00/0xFF | **Confirmed** |
| `[14]` | `t4Temp` | `outdoorTemperatureValue` | `(raw−50)/2`, skip 0x00/0xFF | **Confirmed** |
| `[15..16]` | `pm25Value` | (not decoded) | 16-bit BE µg/m³ | Consistent — always 0 on Q11 |
| `[17]` | `curHum` | (not decoded) | integer % | Consistent — always 0 on Q11 |
| `[18]` | (skipped Q14) | `smallIndoor`[3:0]/`smallOutdoor`[7:4] | nibble | **Unknown on Q11** — values random |
| `[19]` | `lightAdValue` | (not decoded) | raw ADC | Consistent — always 0 on Q11 |

**Cross-validation (55 frames, Sessions 1-9):**

- `totalPowerConsume` unit is **kWh** (not Watts). Verified by exact match with C1 Group4 `totalPowerConsume` in Sessions 1 (111.45 kWh) and 8 (113.81 kWh). Cross-session trend 111.37 → 113.91 kWh monotonically increasing — consistent with a lifetime cumulative energy counter.
- `currentWorkTime[9..12]` is **not implemented on Q11** — all 55 A1 frames contain `00 00 00 00`, including Session 7 (756 s duration). The field is documented in mill1000/midea-msmart Finding 12 (see midea-msmart-mill1000.md) but Q11 firmware does not populate it.
- `byte[18]` is **not a reliable fractional temperature** on Q11. Values cycle through `0x00, 0x04, 0x94, 0x83, 0x90, 0x10...` in frames where T1/T4 are constant. True meaning unknown.
- `T1/T4` readings are physically plausible in all sessions. Session 9 correctly shows `T4 = 0xFF` (N/A) at t = 22 s post-boot, recovering to 4.5 °C by t = 43 s.

### 5.3 Heartbeat 0xA0 — Status Echo

msg_type=0x05, body[0]=0xA0. Uses the same field layout as the 0xC0 status response
(§4.1). Acts as a periodic status push from the mainboard without a preceding query.
**Confirmed** — consistent across mill1000/midea-msmart Finding 9 (see `midea-msmart-mill1000.md`).

---

### 5.4 Heartbeats 0xA2, 0xA3, 0xA5, 0xA6 — Unknown

All use msg_type=0x04. Present in own captures but **no source decodes them**:
- **0xA2**: Heartbeat device params — field structure **Unknown**
- **0xA3**: Heartbeat device params 2 — field structure **Unknown**
- **0xA5**: Heartbeat outdoor unit — field structure **Unknown**
- **0xA6**: Heartbeat network info — field structure **Unknown**

Source: mill1000/midea-msmart (see `midea-msmart-mill1000.md`) —
confirmed absent from all Findings. Not in dudanov, midea-local, or any other open-source
implementation examined.

**Dongle handling**: The dongle forwards all msg_type=0x04 frames opaquely to the cloud
without inspecting the body (Finding 13). Own captures show A5 and A6 contain non-zero
data (unlike A2/A3 which are all zeros). See `uart_examples.md` for captured frames.

---

### 5.5 Network Status (msg_type=0x63 / 0x0D)

- **0x63**: AC polls dongle for network status. Dongle responds with a 20-byte body.
- **0x0D**: Network initialization — sent by dongle at boot (see §6.1).

**MSG 0x63 response body** (20 bytes, entirely built by dongle):

Source: mill1000/midea-msmart Finding 13 (see `midea-msmart-mill1000.md`). **Consistent**.

| body[] | Field | Values |
|--------|-------|--------|
| [0] | Connection status | 0x00=not connected, 0x01=connected |
| [1] | WiFi state | 0=off, 1=connected, 3=SoftAP |
| [2] | WiFi mode | raw |
| [3..6] | IP address | 4 bytes, **little-endian** byte order (see below) |
| [7] | Fixed | 0xFF |
| [8] | Signal strength | 0=error, 1=none, 2=fair, 3=good, 4=excellent, 7=auto |
| [9..15] | DHCP/DNS data | 7 bytes from network subsystem |
| [16] | Connection detail | 0=none, 1=WiFi off+DHCP, 2=connected no IP, 3=fully connected |

**IP address byte order — Confirmed (Session 7):**
The IP is stored in **little-endian** (LSB first). Example from own capture:
```
body[3..6] = 04 B3 A8 C0
             ↓  ↓  ↓  ↓
IP:        192.168.179.4   (read bytes[6].bytes[5].bytes[4].bytes[3])
```
This is the dongle's actual local IP on the WiFi network (192.168.179.x subnet).
Reading as big-endian would give `4.179.168.192` — not a valid local address.

---

### 5.6 Device Identification (msg_type=0x07)

On startup, the dongle sends a device identification query (body = `{0x00}`, LEN=11).
The AC responds with msg_type=0x07 containing the serial number (up to 32 bytes ASCII).

**Side effect** (Finding 13): The dongle reads frame header fields from the response —
frame[2] (TYPE), frame[7] (PROTO), frame[8] (SUB) — and stores them. All future
outgoing frames built by the dongle use these values in their headers.

If no response: dongle generates fallback SN from WiFi MAC address:
`000000P0000000Q1<MAC_HEX>0000`.

Source: mill1000/midea-msmart Finding 13 (see `midea-msmart-mill1000.md`). **Consistent**.

---

### 5.7 RAC Serial (msg_type=0x65)

Alternative SN query for multi-split / VRF systems where the RAC controller responds
instead of the main AC unit. Body = 20 bytes zeros, LEN=30.

The dongle tries MSG 0x07 first; if no response, tries 0x65. A pending 0x07 also accepts
a 0x65 response and vice versa. Same SN fallback if neither responds.

Source: mill1000/midea-msmart Finding 13 (see `midea-msmart-mill1000.md`). **Consistent**.

---

### 5.8 0xBB Sub-Protocol (SN8 / newer devices)

A completely different body encoding used by newer "SN8" generation devices. Temperature
precision at 1/100 C rather than 0.5 C steps. **Not Covered** — requires dedicated analysis.
Primary reference: `chemelli74/midea-local`.

---

## 6. Handshake and Initialization

### 6.1 Boot Sequence

The dongle performs the following startup sequence when powered on:

1. **Model query** (MSG 0xA0): Dongle sends msg_type=0xA0, frame length=30, body=zeros.
   AC responds with `body[2] = sub_type_low`, `body[3] = sub_type_high`.
   Model number = `body[2] | (body[3] << 8)`. For AC (0xAC): model = 0xACAC = 44204.
   Timeout: 300 ms, 6 retries.

2. **Serial number query** (MSG 0x07): Dongle sends msg_type=0x07, body=`{0x00}`, LEN=11.
   AC responds with SN in body (up to 32 bytes ASCII).
   **Side effect**: Dongle reads frame[2] (TYPE), frame[7] (PROTO), frame[8] (SUB) from
   the response header and stores them — all future outgoing frames use these values.
   If no response: fallback SN from WiFi MAC: `000000P0000000Q1<MAC_HEX>0000`.

3. **RAC serial query** (MSG 0x65): Alternative to MSG 0x07 for multi-split/VRF systems.
   Dongle tries 0x07 first; if no response, tries 0x65. A pending 0x07 also accepts a
   0x65 response and vice versa. Same SN fallback if neither responds.

4. **Network init** (MSG 0x0D): Dongle announces its presence on the UART bus.
   body[4..7] = dongle's current local IP address. Also sent on WiFi pairing mode entry.

5. **Capabilities query** (CMD 0xB5): Dongle queries device capabilities.
   B5 response determines which features are available (see §3.4).

6. **Initial status query** (CMD 0x41): First status poll.

7. **Network status** (MSG 0x63): Dongle reports network state to AC every ~2 minutes.

**Restart trigger** (MSG 0x0F / 0x11): If the dongle receives MSG 0x0F or 0x11 with
`body[0] == 0x80 AND body[1] == 0x40`, it sends MSG 0x16 to the AC
(body = {0x02, 0x02, 0x00, 0x00}) and then restarts itself.

**Version info** (MSG 0x87 / 0xC1 from AC): Both trigger the same 9-byte hardcoded
response from the dongle (version type, hardware/firmware version, protocol version).

Source: mill1000/midea-msmart Finding 13 (see `midea-msmart-mill1000.md`). **Consistent**.

### 6.2 Frame Processing

1. **Start detection**: Wait for 0xAA byte, then read `length` byte to know total frame size
2. **Frame reading**: Read `length + 1` total bytes (0xAA + length bytes)
3. **Validation**: Verify CRC8 and checksum before processing
4. **Polling**: Dongle sends periodic 0x41 status queries (~30 s interval); AC responds with 0xC0

### 6.3 Appliance Types

The Midea UART protocol supports multiple appliance types, identified by byte[2] of the
frame. The AC type (0xAC) is the focus of this document.

| Type (hex) | Name | Notes |
|------------|------|-------|
| 0x13 | Light | |
| 0x26 | Bathroom Master | |
| 0x34 | Sink Dishwasher | |
| 0x40 | Multi-Split Controller | |
| 0xA1 | Dehumidifier | |
| **0xAC** | **Air Conditioner** | **This document** |
| 0xB0 | Microwave | |
| 0xB1 | Oven | |
| 0xB3 | Dishwasher | |
| 0xB4 | Fridge | |
| 0xBF | Humidifier | |
| 0xC3 | Heat Pump WiFi Controller | |
| 0xCA | Fridge (alt) | |
| 0xCC | MDV WiFi Controller | VRF control |
| 0xCF | Heat Pump | |
| 0xDA | Water Heater | |
| 0xDB | Heat Pump Water Heater | |
| 0xE1 | Dishwasher (alt) | |
| 0xE2 | Washer | |
| 0xE3 | Dryer | |
| 0xE8 | Electric Water Heater | |
| 0xEA | Electric Rice Cooker | |
| 0xED | Water Drinking Appliance | |
| 0xFA | Fan | |
| 0xFB | Electric Heater | |
| 0xFC | Air Purifier | |
| 0xFD | Humidifier (alt) | |

Source: mill1000/midea-msmart Finding 13 (see `midea-msmart-mill1000.md`). **Consistent**.

---

## 7. Frame Examples

### Query status (full 34-byte frame):
```
AA 21 AC 8D 00 00 00 00 00 03
41 81 00 FF 03 FF 00 02 00 00
00 00 00 00 00 00 00 00 00 00
03 XX YY ZZ
```
Where XX = msg_id, YY = CRC8, ZZ = checksum

### Set power ON, mode=cool, temp=24C, fan=auto (full 36-byte frame):
```
AA 23 AC 8F 00 00 00 00 00 02
40 43 48 66 00 00 00 30 00 00
00 00 00 00 00 00 00 00 00 00
00 00 00 XX YY ZZ
```
Byte 11: 0x43 = beep(0x40) | always(0x02) | power(0x01)
Byte 12: 0x48 = cool(2<<5) | (24-16=8)
Byte 13: 0x66 = fan_auto(102)
XX = msg_id, YY = CRC8, ZZ = checksum

For a comprehensive collection of **26 annotated frame examples** covering every observed
MSG_TYPE and body[0] combination from own captures, see [uart_examples.md](uart_examples.md).
Examples include: set commands, property TLV, all heartbeat types (A1-A6), B5 capabilities,
boot sequence (0x07, 0x65, 0xA0, 0x0D), network status, and group page responses.

---

## 8. Cross-Bus Data Flow

### 8.1 Bus Data Rates

| Bus | Baud | Encoding | ms/byte | 38-byte frame TX |
|-----|------|----------|---------|-----------------|
| Display↔Mainboard (CN1) | 9600 | 8N1 | 1.04 ms | ~40 ms |
| UART wifi dongle (CN3) | 9600 | 8N1 | 1.04 ms | ~40 ms |
| R/T pin (CN1) | **2400** | 8N1 | 4.17 ms | **~158 ms** |
| HA/HB RS-485 | **48000** | 8N1 nibble-pair | 0.21 ms | ~8 ms (physical) |

R/T at 2400 baud is 4× slower than UART — a 38-byte R/T frame takes **158 ms**
to transmit. This must be accounted for when correlating timestamps across buses:
the timestamp marks the first byte, but the last byte arrives ~158 ms later.

HA/HB uses nibble-pair encoding (2 physical bytes per logical byte, XOR 0xFF),
so the effective logical data rate is ~2400 bytes/s — matching R/T throughput.

### 8.2 Mode Field: User Setting vs Actual Sub-Mode

The "Mode" field in C0 Status and 0x40 Set commands carries the **user-requested**
mode (e.g., Auto), not the mainboard's actual operating sub-mode (e.g., Heat).
In Auto mode, the mainboard independently selects the active sub-mode based on
temperature conditions.

To determine the real operating mode, read the display-mainboard internal bus
or the C1 Group 1 "indoor operating mode" field.

For device-specific observations (relay timing, polling rates, cross-bus mode
mismatch examples), see [device_xtremesaveblue.md](device_xtremesaveblue.md).

---

## Appendix A — Cross-Source Consistency

Sources compared: `dudanov/MideaUART` (C++), `chemelli74/midea-local` (Python), `NeoAcheron/midea-ac-py` (Python), `reneklootwijk/node-mideahvac` (JS).

---

### A.1 Confirmed Matches (all sources agree)

| Field | Value | Notes |
|---|---|---|
| Start byte | `0xAA` | Universal |
| Appliance type | `0xAC` | Universal |
| SYNC byte | `LENGTH ^ APPLIANCE_TYPE` | Universal |
| CRC-8 table | identical 256-entry table | All sources carry the same table verbatim |
| Checksum formula | `(256 - sum(frame[1:])) & 0xFF` | Universal |
| Fan speed values | AUTO=102, SILENT=20, LOW=40, MED=60, HIGH=80, TURBO=100 | Universal |
| Mode encoding | bits[7:5] of body[2]; 1=Auto,2=Cool,3=Dry,4=Heat,5=Fan | Universal |
| Swing nibble | body[7] lower nibble; OFF=0, V=0x0C, H=0x03, BOTH=0x0F | Universal |
| ECO in SET (0x40) | body[9] bit 7 (0x80) | dudanov + midea-local agree |
| Turbo in SET/response | body[8] bit 5 AND body[10] bit 1 (both locations active) | dudanov + midea-local agree |
| Frost protection | body[21] bit 7 (0x80) | All agree |
| Indoor temp | body[11]: `(val - 50) / 2.0` | All agree |
| Outdoor temp | body[12]: `(val - 50) / 2.0` | All agree |
| New temp field | body[13] bits[4:0]: `val + 12` if > 0, overrides byte 2 | dudanov + our doc agree |
| Capabilities frame | record structure: ID(1B) + type(1B) + len(1B) + data | All agree |
| Capability IDs 0x0212–0x022C | values match across all sources | |

---

### A.2 Conflicts and Deviations

#### ⚠️ ECO mode — C0 response body[9]: BIT MISMATCH

| Source | Bit mask | Notes |
|---|---|---|
| This document (section 6) | `0x10` (bit 4) | Correctly documented |
| **`response.py` in this project** | `0x80` (bit 7) | **WRONG — confirmed bug** |
| `dudanov/MideaUART` | `0x10` (bit 4) | `m_getValue(9, 16)` where 16=0x10 |
| `midea-local` | `0x10` (bit 4) | `body[9] & 0x10` |

**The response parser reads bit 7 but the correct bit is bit 4. This causes ECO mode to never be detected from a real AC response. Requires hardware verification before fixing.**

Note: SET command (0x40) correctly uses bit 7 (0x80) for ECO — the protocol uses different bit positions for set vs. response.

---

#### ✅ CAPABILITY_MODES (0x0214) — **Consistent** (dudanov and node-mideahvac agree)

Source: dudanov/MideaUART `Capabilities.cpp` and reneklootwijk/node-mideahvac `B5.js` — both
contain identical switch-case logic. **This document's earlier table was wrong.**

| Value | Correct interpretation (both sources agree) |
|---|---|
| 0 | cool=yes, dry=yes, auto=yes, heat=**no** |
| 1 | all four modes (cool, heat, dry, auto) |
| 2 | heat=yes, auto=yes, cool=**no**, dry=**no** |
| 3 | cool=yes only (heat=no, dry=no, auto=no) |
| 4–9 | heat variants (reneklootwijk/node-mideahvac only) — not yet documented here |

---

#### ✅ CAPABILITY_TURBO (0x021A) — **Consistent** (dudanov and node-mideahvac agree)

Source: dudanov/MideaUART and reneklootwijk/node-mideahvac — identical switch-case logic.
**This document's earlier table was wrong.**

| Value | turboCool | turboHeat |
|---|---|---|
| 0 | true | false |
| 1 | true | true |
| 2 | false | false |
| 3 | false | true |

---

#### ✅ CAPABILITY_FAN_SPEED_CONTROL (0x0210) — **Consistent** (dudanov and node-mideahvac agree)

| Source | Interpretation |
|---|---|
| dudanov/MideaUART | `val != 1` → supported |
| reneklootwijk/node-mideahvac | `val != 1` → supported |

Both sources agree: `val=1` means NOT supported. This document previously documented `val != 0`
— **that was wrong.** Corrected.

---

#### ✅ CAPABILITY_UNIT_CHANGEABLE (0x0222) — **Consistent** (dudanov and node-mideahvac agree)

| Source | Interpretation |
|---|---|
| dudanov/MideaUART | `!val` → changeable (val=0 means changeable) |
| reneklootwijk/node-mideahvac | `val === 0` → changeable |

Both sources agree: `val=0` means unit IS changeable. This document previously documented
the inverse — **that was wrong.** Corrected.

---

#### ✅ CAPABILITY_TEMPERATURES (0x0225) — **Consistent** (dudanov and node-mideahvac agree)

| Source | Encoding |
|---|---|
| dudanov/MideaUART | raw × 0.5 = °C |
| reneklootwijk/node-mideahvac | raw / 2 = °C |

Both sources agree: raw bytes must be multiplied by 0.5 to get °C. This document previously
documented raw = direct °C — **that was wrong.** Corrected. A raw value of 32 = 16°C.

---

#### ⚠️ Display state — C0 response body[14]: inverted interpretation

| Source | ON condition |
|---|---|
| This document | `body[14] & 0x70 == 0x70` (bits[6:4] all set) |
| midea-local | `(body[14] >> 4 & 0x7) != 0x07` (bits[6:4] NOT all set) AND power is on |

These are directly contradictory. midea-local also gates display state on power status.

---

#### ℹ️ Fan speed — hardware variants

`dudanov/MideaUART` contains the following comment in `StatusData.cpp`:

> *"some ACs return 30 for LOW and 50 for MEDIUM. Note though, in appMode, this device still uses 40/60"*

Not all units consistently return the documented fan speed values. Parsers should handle 30→40 and 50→60 substitution defensively.

---

#### ℹ️ Query command body[4:5] — minor variant

| Source | body[4] | body[5] |
|---|---|---|
| dudanov / NeoAcheron | `0x03` | `0xFF` |
| midea-local | `0x00` | `0x00` |

Functional impact unknown — the AC likely ignores these bytes in a query. Both variants appear to work in practice.

---

#### ℹ️ Power query body length — significant variant

| Source | Body length | Notes |
|---|---|---|
| dudanov | 23 bytes | Full padding to 0x00 |
| midea-local | 6 bytes | `[0x41, 0x21, 0x01, 0x44, 0x00, 0x01]` — truncated |

Functional impact unknown. Both variants are in active use.

---

#### ℹ️ C1 power response — subbody type discrimination

midea-local distinguishes body[3] as a subbody type discriminator:
- `0x44`: total energy consumption at body[4:8], current consumption at body[12:16], realtime power at body[16:19]
- `0x40`: not yet documented

This document only covers the `0x44` format (bytes 16–18 BCD). Additionally, midea-local implements three parsing methods (BCD, binary, raw integer) and treats the format as device-dependent. The single-format BCD approach in section 7 may not work on all units.

---

#### ℹ️ Display toggle command — body[1] variant

| Source | body[1] | body[1] meaning |
|---|---|---|
| dudanov | `0x61` | fixed sub-command |
| midea-local | `0x02` or `0x42` | base + optional prompt_tone bit |

Different sub-command bytes. Both are in active use across different device generations.

---


## Appendix B — Source Stability and Coverage

> **Note on analysis method:** The comparisons, conflict detections, and stability estimates below
> were produced primarily through automated AI-assisted analysis of the referenced open-source
> repositories. They represent a best-effort interpretation and may contain errors or misreadings.
> The authors of the referenced projects are not affiliated with this analysis — their work is
> referenced here purely as a documentation basis and is greatly appreciated.
> All findings marked `CONFLICT` or `BUG` require independent hardware verification before
> acting on them.

---

### B.1 Source Stability Estimates

Ratings reflect breadth of protocol coverage, implementation quality, cross-source agreement,
and apparent maintenance activity. Scale: `0` (limited) → `+++` (comprehensive).
The goal is to identify which sources are most suitable as a protocol reference.

```yaml
sources:

  dudanov/MideaUART:
    language: C++
    stability: +++
    protocol_ref_value: high
    notes: >
      Strongly typed, well-structured, widely deployed in ESPHome ecosystem.
      Good for low-level frame and capability detail. Actively maintained.

  chemelli74/midea-local:
    language: Python
    stability: +++
    protocol_ref_value: high
    notes: >
      Most complete coverage of all sources. Handles multiple device generations,
      sub-protocols (XBB, B0/B1), and edge cases. Best single reference for
      newer devices and full feature set.

  reneklootwijk/node-mideahvac:
    language: JavaScript
    stability: ++
    protocol_ref_value: medium
    notes: >
      Good documentation and reasonable coverage. Useful cross-check for
      command construction. Moderate maintenance activity.

  NeoAcheron/midea-ac-py:
    language: Python
    stability: +
    protocol_ref_value: low-medium
    notes: >
      Functional but older. Field offsets appear shifted due to a network-layer
      header being included in its frame model — care needed when cross-referencing.

  reneklootwijk/midea-uart:
    language: C++
    stability: +
    protocol_ref_value: low-medium
    notes: >
      ESP8266 focused. Useful for low-level framing detail but limited in scope.
      Overlaps significantly with dudanov.

  yitsushi/midea-air-condition:
    language: Ruby
    stability: 0
    protocol_ref_value: low
    notes: >
      Niche language. Limited cross-validation possible. Likely unmaintained.
      Only useful as a basic consistency check.
```

---

### B.2 Findings Summary

Status key:
- `BUG` — confirmed implementation error in this project
- `CONFLICT` — sources disagree; hardware verification required
- `VARIANT` — known hardware or firmware variation; handle defensively
- `INCOMPLETE` — partially documented; known gaps
- `NOT_COVERED` — feature confirmed to exist but not documented here

```yaml
findings:

  - id: 1
    topic: ECO bit in C0 response
    doc_ref: "Section 6, body[9]"
    code_ref: "response.py:131"
    status: BUG
    sources_agree: [dudanov, midea-local]
    detail: >
      response.py uses 0x80 (bit 7); correct value is 0x10 (bit 4).
      ECO mode is never detected from real AC responses as a result.
      The SET command (0x40) correctly uses bit 7 — the protocol intentionally
      uses different bit positions for set vs. response. Verify on hardware before fixing.

  - id: 2
    topic: CAPABILITY_MODES (0x0214) encoding
    doc_ref: "Section 12.2"
    status: RESOLVED
    sources_agree: [dudanov, node-mideahvac]
    detail: >
      Previously marked CONFLICT. dudanov/MideaUART and reneklootwijk/node-mideahvac
      agree on identical switch-case logic. This document's table was wrong.
      Correct: 0=cool+dry+auto(no heat), 1=all four, 2=heat+auto, 3=cool only.
      Section 8 table and 12.2 conflict block updated accordingly.

  - id: 3
    topic: CAPABILITY_TURBO (0x021A) value mapping
    doc_ref: "Section 12.2"
    status: RESOLVED
    sources_agree: [dudanov, node-mideahvac]
    detail: >
      Previously marked CONFLICT. Both sources agree.
      Correct: 0=cool-only, 1=both, 2=neither, 3=heat-only.
      This document's earlier table was wrong. Section 8 and 12.2 updated.

  - id: 4
    topic: CAPABILITY_FAN_SPEED_CONTROL (0x0210) logic
    doc_ref: "Section 12.2"
    status: RESOLVED
    sources_agree: [dudanov, node-mideahvac]
    detail: >
      Previously marked CONFLICT. Both sources agree: val != 1 → supported.
      This document previously said val != 0 — that was wrong. Corrected.

  - id: 5
    topic: CAPABILITY_UNIT_CHANGEABLE (0x0222) logic
    doc_ref: "Section 12.2"
    status: RESOLVED
    sources_agree: [dudanov, node-mideahvac]
    detail: >
      Previously marked CONFLICT. Both sources agree: val=0 → changeable (!val).
      This document previously said the inverse — that was wrong. Corrected.

  - id: 6
    topic: CAPABILITY_TEMPERATURES (0x0225) scaling
    doc_ref: "Section 12.2"
    status: RESOLVED
    sources_agree: [dudanov, node-mideahvac]
    detail: >
      Previously marked CONFLICT. Both sources agree: raw × 0.5 = °C.
      This document previously said raw = direct °C — that was wrong. Corrected.
      A raw value of 32 = 16°C, not 32°C.

  - id: 7
    topic: Display state — C0 body[14] bits[6:4]
    doc_ref: "Section 6"
    status: CONFLICT
    sources_disagree: [this_doc, midea-local]
    detail: >
      this_doc:    bits[6:4] == 0x7 → display ON.
      midea-local: bits[6:4] != 0x7 → display ON (inverted), also gated on power ON.

  - id: 8
    topic: Fan speed hardware variants (30/50 instead of 40/60)
    doc_ref: "Section 4, Section 6"
    status: VARIANT
    source: dudanov
    detail: >
      Some units return 30 for LOW and 50 for MEDIUM in responses.
      Commands should still use 40/60. Defensive remapping recommended in parser.

  - id: 9
    topic: Query command body[4:5]
    doc_ref: "Section 4"
    status: VARIANT
    sources: [dudanov/NeoAcheron → 0x03/0xFF, midea-local → 0x00/0x00]
    detail: >
      Functional impact unknown. AC likely ignores these bytes in a query frame.

  - id: 10
    topic: Power query body length
    doc_ref: "Section 4"
    status: VARIANT
    sources: [dudanov → 23 bytes, midea-local → 6 bytes]
    detail: Both are in active use. Shorter form may be safer for compatibility.

  - id: 11
    topic: C1 power response — subbody type discrimination
    doc_ref: "Section 7"
    status: INCOMPLETE
    detail: >
      Only subbody type 0x44 is documented here. Type 0x40 exists but is undocumented.
      midea-local implements three separate parsing methods (BCD, binary, raw integer)
      depending on device type. Single-format BCD will not work on all units.

  - id: 12
    topic: Display toggle command body[1]
    doc_ref: "Section 4"
    status: VARIANT
    sources: [dudanov → 0x61, midea-local → 0x02/0x42]
    detail: Corresponds to different device generations. Both observed in the field.

  - id: 13
    topic: XBB sub-protocol (SN8 / newer units)
    doc_ref: "Section 12.3"
    status: NOT_COVERED
    detail: >
      Entirely different body encoding for newer devices. Temperature at 1/100°C precision.
      Requires dedicated analysis; midea-local is the primary reference.

  - id: 14
    topic: B0/B1 new-protocol (tag-value pairs)
    doc_ref: "Section 12.3"
    status: NOT_COVERED
    detail: >
      Used for indirect wind, breeze, fresh air, screen display on newer units.
      Requires dedicated analysis; midea-local is the primary reference.
```

---

## Appendix C — NeoAcheron Command Construction (Python reference)

### Base command template (30 bytes):
```python
base_cmd = bytearray([
    0xAA,  # [0x00] start byte
    0x23,  # [0x01] length (recalculated in finalize)
    0xAC,  # [0x02] appliance type
    0x00,  # [0x03]
    0x00,  # [0x04]
    0x00,  # [0x05]
    0x00,  # [0x06]
    0x00,  # [0x07]
    0x03,  # [0x08] protocol
    0x02,  # [0x09] msg type (0x02 = command to appliance)
    0x40,  # [0x0A] command type (0x40 = set)
    0x81,  # [0x0B] control byte (see below)
    0x00,  # [0x0C] mode + temp
    0xFF,  # [0x0D] fan speed
    0x03,  # [0x0E]
    0xFF,  # [0x0F]
    0x00,  # [0x10]
    0x30,  # [0x11] swing mode (0x30 = base value)
    0x00,  # [0x12]
    0x00,  # [0x13] eco mode (0xFF = on)
    0x00,  # [0x14] turbo mode (0x02 = on)
    0x00,  # [0x15]
    0x00,  # [0x16]
    0x00,  # [0x17]
    0x00,  # [0x18]
    0x00,  # [0x19]
    0x00,  # [0x1A]
    0x00,  # [0x1B]
    0x03,  # [0x1C]
    0xCC,  # [0x1D] CRC8 (recalculated)
])
```

### NeoAcheron set_command properties (frame-absolute offsets):
```python
# Power:     frame[0x0B] bit 0
# Beep:      frame[0x0B] & 0x42 (bits 1 and 6)
# Mode:      frame[0x0C] bits [7:5]
# Temp:      frame[0x0C] bits [4:0] (bit4=0.5, bits[3:0]=temp&0xF | (temp<<4)&0x10)
# Fan:       frame[0x0D] = speed value
# Swing:     frame[0x11] bits [3:0]
# Eco:       frame[0x13] = 0xFF (on) or 0x00 (off)
# Turbo:     frame[0x14] = 0x02 (on) or 0x00 (off)
```

### Finalize command:
```python
def finalize(cmd):
    cmd[0x1D] = crc8(cmd[16:])   # CRC over bytes 16 onward
    cmd[0x01] = len(cmd)          # length field
    return cmd
```

---

## Appendix D — Open Questions

Consolidated list of unresolved items from throughout this document:

| ID | Topic | Section | Status | Notes |
|----|-------|---------|--------|-------|
| OQ-01 | ~~PMV mode value meanings~~ | §4.1 | **Resolved** | Full PMV table added (-3.0 to +2.5, 13 values) from reneklootwijk/node-mideahvac + mill1000/midea-msmart reference |
| OQ-02 | Alternative temp packing trigger | §4.1 | Hypothesis | Trigger condition for byte[1] vs byte[2] format unknown |
| OQ-03 | ~~Silky cool frame-length conditional~~ | §4.1 | **Resolved** | Documented: body[22] only present if body >= 23 bytes; B5 SILKY_COOL (0x0018) capability flag |
| OQ-04 | A2/A3/A5/A6 heartbeat body structures | §5.4 | Unknown | Present in captures, no source decodes them |
| OQ-05 | 0xBB sub-protocol (SN8 / newer units) | §5.8 | Not Covered | Entirely different encoding; midea-local is primary ref |
| OQ-06 | ECO bit read/write position | §4.1 / §3.2 | Documented | Response bit 4 vs command bit 7 — confirmed intentionally different positions (Finding 4) |
| OQ-07 | Display ON bit inversion | §4.1 | Disputed | This doc says bits==0x7=ON; midea-local says bits!=0x7=ON. Needs hardware test |
| OQ-08 | Group 2 captures vs Finding 11 field mismatch | §3.1.2 | Disputed | Own R/T captures show temps where Finding 11 expects RPM |
| OQ-09 | Extension board 0x93 field meanings | §3.3 | Unknown | All payload fields unidentified |
| OQ-10 | C1 power subbody type 0x40 | §4.2.1 | Not Covered | Only 0x44 format documented; 0x40 exists but undocumented |
| OQ-11 | Display toggle body[1] variant | §3.1.5 | Variant | dudanov=0x61, midea-local=0x02/0x42; device generation dependent |
| OQ-12 | ~~Section 5.1.4 extended query~~ | §3.1.4 | **Resolved** | Fully expanded: frame layout, optCommand table, Follow Me encoding, queryStat values |
| OQ-13 | ~~B0/B1 property protocol~~ | §3.5 | **Resolved** | Expanded to 53 property IDs from mill1000/midea-msmart reference validation |
| OQ-14 | Group 0 byte order (16-bit BE vs LE) | §3.1.2 | Unknown | Group 0 uses 16-bit BE for days; Group 5 uses 16-bit LE — inconsistency needs verification |
| OQ-15 | Old B5 fixed-format field details | §3.4.2 | Hypothesis | Cursor-based field map from single source; not verified |
| OQ-16 | Follow Me body[8] bit 7 — Lua vs mill1000/midea-msmart | §3.1.4.7 | **Confirmed** | Own R/T captures (Sessions 3–8) confirm body[8] bit 7 = Follow Me (bodySense). mill1000/midea-msmart Finding 10 is correct. See `analysis_follow_me_serial.md` §8 |
| OQ-17 | localBodySense — occupancy sensor | §3.1.4.7 | **Hypothesis** | mill1000/midea-msmart Finding 10b: body[9] bit 7 = localBodySense (built-in occupancy sensor). Source confirmed in reference code response parser. Own captures: always 0x00 (test unit has no occupancy sensor). Previously mislabeled as ECO in §4.1 — corrected |
| OQ-18 | 0xA0 alternative temp encoding | §5.3 | Hypothesis | mill1000/midea-msmart Finding 7: alternative temp formula `((body[1] & 0x3E) >> 1) + 12` with half-degree in bit 6. Trigger: dataType=0x05, body[0]=0xA0. Not verified on hardware |
| OQ-19 | 20 new MSG_TYPEs unverified | §2.1 | Consistent | Firmware-verified but not captured on own hardware |
| OQ-20 | Python msmart: no A1 heartbeat | — | Gap | Python library does not parse A1 (0xA1) heartbeat frames |
| OQ-21 | deviceSN8 variant temperature decoding | §3.4.2 | Hypothesis | CA models use different bit positions in B5 temp field. Needs testing across model families (Finding 14a) |
| OQ-22 | Smart Dry mode field | §4.1 | Hypothesis | smartDryValue (body[13] or [19], 7-bit, 30-101%) only in DRY/SMART_DRY mode. Not captured (Finding 14b) |
| OQ-23 | Comfort sleep curve format | §3.2 | Hypothesis | comma-separated hex string; exact encoding undocumented (Finding 14c) |
| OQ-24 | 0xCC dehumidifier command set | — | Out of scope | Different body[0] values (0xC3, 0xB0, 0xE0, 0x01, 0xD0). Same frame structure (Finding 14g) |
| OQ-25 | MSG 0x0F/0x11 restart trigger | §6.1 | Consistent | body[0]=0x80, body[1]=0x40 triggers dongle restart. Not captured (Finding 13d) |

---

## Appendix E — Sources Requiring Deeper Analysis

Items discovered during documentation that could not be resolved and require
dedicated deep-dive into specific source code or additional capture sessions.

| ID | Topic | Source(s) to investigate | Analysis needed |
|----|-------|------------------------|-----------------|
| DA-01 | 0xBB sub-protocol field map | `chemelli74/midea-local` | Code review of XBB parser; ~500 lines |
| DA-02 | B0/B1 property ID complete list | `chemelli74/midea-local` | Code review of property handlers |
| DA-03 | Alternative temp packing trigger | `mill1000/midea-msmart` | Trace format flag detection logic |
| DA-04 | ~~PMV mode value definitions~~ | **Resolved** — found in reneklootwijk/node-mideahvac + mill1000/midea-msmart reference | Encoding: `(bits[3:0]) * 0.5 - 3.5` |
| DA-05 | A2/A3/A5/A6 body structures | Own captures + future source releases | Capture session with WiFi module paired to trigger these |
| DA-06 | Older JS driver review | mill1000/midea-msmart (see `midea-msmart-mill1000.md`) | ~50 KB, dated 2018-07-03. Review for older protocol variants |
| DA-07 | 0xCC dehumidifier protocol files | mill1000/midea-msmart (see `midea-msmart-mill1000.md`) | May share UART framing. 2983 + 988 lines |
| DA-08 | UI component protocol assumptions | mill1000/midea-msmart (see `midea-msmart-mill1000.md`) | May contain implicit protocol assumptions |
| DA-09 | ~~0xA0 response alternative temp~~ | **Documented** in OQ-18 | Encoding: `((info[1] & 0x3E) >> 1) + 12`, trigger: dataType=0x05 |
| DA-10 | ~~B0/B1 complete property list~~ | **Resolved** — 53 IDs extracted from mill1000/midea-msmart reference | See §3.5 |
| DA-11 | deviceSN8 variant mapping | Own captures from different Midea models | Which SN8 values map to which AC product lines? |
| DA-12 | Comfort sleep curve format | mill1000/midea-msmart (see `midea-msmart-mill1000.md`) | Comma-separated hex string — trace how it's applied to temperature setpoints |
