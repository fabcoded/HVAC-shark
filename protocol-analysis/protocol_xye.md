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

### 0.1 Temperature sensor encoding — **Confirmed** (Erlang formula, Sessions 4/5/6)

Three different offsets were claimed for the same sensor bytes (0x0B–0x0E). Own captures
across Sessions 4, 5, and 6 have resolved the dispute in favour of the Erlang formula:

**Confirmed formula: `temp_c = (raw - 40) / 2.0`** (codeberg Erlang emulator, offset 40)

| Source | Formula | Offset | Example: raw 0x50 = | Status |
|--------|---------|--------|---------------------|--------|
| codeberg/xye Erlang emulator (`xye.erl`) | `(raw - 40) / 2` | 40 | **20.0 °C** | **Confirmed** |
| codeberg/xye README | `(raw - 0x30) × 0.5` | 48 (0x30) | 16.0 °C | Wrong — off by 4 °C |
| esphome-mideaXYE-rs485 | `raw` (no conversion) | none | 80 °F | Wrong — °F interpretation |

**Evidence (three independent cross-checks):**

1. **Session 4 — R-T UART Indoor Temp vs XYE T1**: R-T UART 0xC0 response (offset-50
   encoding, well-confirmed) showed Indoor Temp = 13–14 °C. XYE T1 raw=0x42 → Erlang:
   13 °C ✓. README formula gives 9 °C (mismatch by 4 °C).

2. **Session 4 — R-T UART Outdoor Temp vs XYE T3**: R-T UART showed Outdoor Temp = 5.5 °C.
   XYE T3 raw=0x33 → Erlang: 5.5 °C ✓. README gives 1.5 °C (mismatch by 4 °C).

3. **Session 6 — Service menu ground truth**: Display PCB service menu read directly off
   hardware: T1 "indoor air" = 18 °C, T3 "coil outside" = 2 °C.
   XYE T1 raw=0x4C → Erlang: 18.0 °C ✓ (exact). XYE T3 raw=0x2C → Erlang: 2.0 °C ✓ (exact).

4. **Session 7 — Full SET_TEMP range**: Setpoint swept 16–30 °C in both Heat and Cool modes.
   All 15 values produced the expected T+0x40 byte (`0x50`–`0x5E`), no anomalies.

**Why ESPHome's °F interpretation persisted**: For winter outdoor temperatures, raw values
cluster around 0x30–0x35. Treated as °F that reads 8–12 °C, which is plausible for a mild
climate — the error was small enough not to be noticed. For indoor T1, raw ≈ 0x42 as °F
gives ~19 °C (believable for a heated room), masking the ~6 °C error.

**Additional finding — T1 = Follow-Me reference, not local sensor**: Sessions 5 and 6
confirm that T1 (byte 0x0B) tracks the KJR-12x wall-controller sensor, not the indoor
unit's own thermistor. When the KJR-12x was moved outside (~11 °C) T1 = 10–11 °C; when
indoors (18 °C) T1 = 18 °C. The display-board service menu labels this field
"tindoor air (followme)" — confirming it is the Follow-Me room-temperature reference.

**For comparison**: Midea UART uses offset 50 for 0xC0 status-response temperatures and
offset 30 for Group 1 (T1/T2). See [comparison_uart_vs_xye.md](comparison_uart_vs_xye.md).

### 0.2 Fan speed encoding — **Confirmed** (Erlang, Session 7)

| Value | Meaning | Source agreement |
|-------|---------|-----------------|
| `0x80` | Auto | All sources agree |
| `0x01` | High | All sources agree |
| `0x02` | Medium | All sources agree |
| `0x04` | Low | **Confirmed** — codeberg Erlang emulator + Session 7 hardware |

Session 7 fan speed sweep (Auto → Low → Mid → High) confirmed Low = `0x04`.
The codeberg README and ESPHome claim Low = `0x03` — this is incorrect on the
tested hardware (Midea extremeSaveBlue). The Erlang emulator value is correct.

One-hot encoding: bit7=Auto, bit2=Low, bit1=Mid, bit0=High.

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

### 0.4 Command 0xC4 and 0xC6 — request-response patterns

The codeberg README documents only 4 commands: 0xC0 (Query), 0xC3 (Set), 0xCC (Lock),
0xCD (Unlock). However:

| Command | Source             | Frame pattern             | Notes |
|---------|--------------------|---------------------------|-------|
| 0xC0    | all three sources  | 16-byte request → 32-byte response | Well documented |
| 0xC3    | all three sources  | 16-byte request → 32-byte response | Well documented |
| 0xC4    | our dissector only | 32-byte frame seen        | Not in codeberg or ESPHome. Our dissector treats it as "Ext.Query" but the payload layout is unknown. May be a **32-byte request** (unlike the standard 16-byte), or a response to an unseen query. |
| 0xC6    | ESPHome + Session 3 captures | 16-byte request → 32-byte response | **Confirmed frame pattern** (Session 3). See §0.4a. |
| 0xCC    | codeberg           | 16-byte request → 32-byte response | Lock. Emulator responds with `0xC0 | 0x0C = 0xCC` in the response code. |
| 0xCD    | codeberg           | 16-byte request → 32-byte response | Unlock. Emulator responds with `0xC0 | 0x0D = 0xCD`. |

**Open question**: Are there 32-byte *requests* on XYE (not just responses)? The
current framing logic assumes byte[2]=0x80 always means slave→master (32-byte
response). If 0xC4 is a 32-byte master→slave command, this assumption breaks.

### 0.4a Command 0xC6 — Follow-Me — **Hypothesis** (own captures, Session 3)

Follow-Me is Midea's feature for using an external room temperature sensor (remote
control, phone, wall controller) as the AC setpoint reference.

**Observed pattern:** C6 never appears standalone. It always follows a C3 Set as
an atomic pair within ~60 ms:
```
C3 Set  (M→S 16b) → C3 Response (S→M 32b) → C6 (M→S 16b) → C6 Response (S→M 32b)
```

**C6 master request (16-byte) — observed:**
```
AA C6 00 00 00 00  00 00 00 00  46 17 00 39 A4 55
                   ↑  ↑  ↑  ↑
                  b6 b7 b8 b9 = 0x00  — no room temperature in payload
```
Bytes [6..9] are all zero in all three observed instances. The temperature is **not**
embedded in the C6 request. Instead it travels in the C3 byte[8] that immediately
precedes each C6.

**C6 slave response (32-byte) — observed:**
```
AA C6 00 00 00 00 05 00 02 30 0E 00 00 00 00 00  [oper] [fan] [setT]  BC D6 32 98 … [ctr] 55
                                                   ↑      ↑     ↑                     ↑
                                                  b16    b17   b18              rolling +1
```
- Bytes [16..18] echo the operating state (oper / fan / setT) from the preceding C3
- Byte [30] is a rolling counter incrementing +1 per frame — sequence number or CRC artifact

**Interpretation:** C6 is a Follow-Me handshake. It flags the preceding C3 as a
Follow-Me temperature push (room temperature, not a user-set command) and requests a
full state echo from the unit. This is analogous to the UART `body[8] bit 7 = 0x80`
enable flag in 0x40 Set — it activates the Follow-Me mode for that update cycle.

**UART parallel (from mill1000/Finding 10, Authoritative):**

| UART Follow-Me | XYE equivalent |
|----------------|----------------|
| `0x40` body[8]=0x80 enable flag | `C6` request (zero payload) |
| `0x41` body[4]=0x01, body[5]=T×2+50 | `C3` byte[8] = T + 0x40 |

The temperature encoding differs: UART uses `T × 2 + 50`; XYE uses `T + 0x40`.

**Session 7 confirmation:** 81 C6 pairs observed (one per setpoint/mode/fan change).
C6 response payload is structurally identical to the C4 ExtQuery response (see §7a).
When Follow-Me was disabled via the KJR-12x menu, C6 pairs stopped immediately
(last C6 at t=762s, session continued to t=781s with no further C6 frames).
After Follow-Me disable, T1 (C0 byte[11]) changed from 24.0 °C to 20.5 °C — consistent
with T1 switching from the KJR-12x sensor to the indoor unit's own thermistor.

**Open question:** Does the KJR-12x room controller populate C6 bytes [6..9] with
a measured room temperature when an external sensor is wired? Not observed here — the
payload was always zero. ESPHome uses C6 for room temperature; the exact byte layout
of ESPHome's C6 frame is not confirmed against own captures.

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
 10     SET_TEMP          Target temperature: raw - 0x40 = °C (e.g. 0x56 = 22 °C) — Confirmed
 11     T1_INDOOR         Follow-Me reference temperature (room temp from KJR-12x) — formula (raw-40)/2 — Confirmed §0.1
 12     T2A_COIL_IN       Indoor coil inlet — formula (raw-40)/2 — Confirmed §0.1
 13     T2B_COIL_OUT      Indoor coil outlet — formula (raw-40)/2; 0x00 = not reported on this HW
 14     T3_OUTDOOR_COIL   Outdoor coil temperature — formula (raw-40)/2 — Confirmed §0.1
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
| `0xC4` | M→S / S→M      | Extended query | dissector + Sessions 6/7 | 16-byte request → 32-byte response. Response payload partially decoded — see §7a |
| `0xC6` | Master→Slave   | Follow-Me      | ESPHome         | 16-byte send of remote room temperature. Not in codeberg. Response pattern unknown (see §0.4) |
| `0xCC` | Master→Slave   | Lock           | codeberg        | 16-byte lock command, response echoes 0xCC       |
| `0xCD` | Master→Slave   | Unlock         | codeberg        | 16-byte unlock command, response echoes 0xCD     |

---

## 5. Operating Mode Encoding — **Confirmed** (Session 7)

Byte 0x08 in the slave response (and byte[6] in the 16-byte Set command):

| Value  | Mode      | Bit pattern      |
|--------|-----------|-------------------|
| `0x00` | Off       | `0000 0000`       |
| `0x81` | Fan only  | `1000 0001`       |
| `0x82` | Dry       | `1000 0010`       |
| `0x84` | Heat      | `1000 0100`       |
| `0x88` | Cool      | `1000 1000`       |
| `0x90` | Auto      | `1001 0000`       |

Bit 7 = power on. Bits [4:0] use one-hot encoding for the mode:
bit0=fan, bit1=dry, bit2=heat, bit3=cool, bit4=auto.

> Note: previous sources listed Auto as `0x80`. Session 7 confirmed Auto = `0x90`
> (bit4 set). `0x80` alone is power-on with no mode bits — not observed standalone.

---

## 6. Fan Speed Encoding — **Confirmed** (Session 7)

Byte 0x09 in the slave response (and byte[7] in the 16-byte Set command):

| Value  | Speed  | Bit pattern | Status |
|--------|--------|-------------|--------|
| `0x80` | Auto   | `1000 0000` | Confirmed |
| `0x01` | High   | `0000 0001` | Confirmed |
| `0x02` | Medium | `0000 0010` | Confirmed |
| `0x04` | Low    | `0000 0100` | **Confirmed** — Erlang correct, README/ESPHome wrong (see §0.2) |

One-hot encoding: bit7=auto, bit2=low, bit1=mid, bit0=high.

---

## 7. Temperature Encoding

### Target temperature (byte 0x0A) — **Confirmed** (Sessions 3/4/7, full range)
`temp_c = raw - 0x40` (e.g. raw 0x56 = 22 °C, 0x59 = 25 °C).

Session 7 confirmed every value from 16 °C (`0x50`) to 30 °C (`0x5E`) in both Heat
and Cool modes — no gaps, no exceptions. Setpoint limits on tested HW: 16–30 °C.

| °C | 16 | 17 | 18 | 19 | 20 | 21 | 22 | 23 | 24 | 25 | 26 | 27 | 28 | 29 | 30 |
|----|----|----|----|----|----|----|----|----|----|----|----|----|----|----|-----|
| hex | 50 | 51 | 52 | 53 | 54 | 55 | 56 | 57 | 58 | 59 | 5A | 5B | 5C | 5D | 5E |

> Note: the codeberg README documents this as a "direct integer value", which would
> imply 0x56 = 86 °C. That is wrong. The actual hardware uses T + 0x40 encoding.

### Measured temperatures (sensor bytes 0x0B-0x0E) — **Confirmed** (Sessions 4/5/6)

**Confirmed formula: `temp_c = (raw - 40) / 2.0`** (codeberg Erlang emulator, offset 40).
See §0.1 for full evidence and why the README formula (offset 48) and ESPHome °F
interpretation are incorrect.

| Byte | Field | Notes |
|------|-------|-------|
| 0x0B | T1 — Follow-Me room temperature reference | Tracks KJR-12x sensor, not indoor unit's own thermistor (see §0.1) |
| 0x0C | T2A — Indoor coil inlet (evaporator/condenser inlet) | |
| 0x0D | T2B — Indoor coil outlet | 0x00 = not reported on this hardware |
| 0x0E | T3 — Outdoor coil temperature | |

T4 (outdoor ambient) is not present in the XYE 0xC0 response. It appears in the
C4 ExtQuery response (byte[21]) and is echoed in the R-T UART 0xC0 Outdoor Temp field.

### 7a. C4 / C6 Extended Response Layout (32 bytes) — **Confirmed** (Sessions 6/7)

C4 (ExtQuery) and C6 (FollowMe) slave responses share the same 32-byte payload
structure — identical except for byte[1] (command code) and byte[30] (CRC).

```
Offset  Field             Description
------  -----             -----------
  0     PREAMBLE          0xAA
  1     RESPONSE_CODE     0xC4 or 0xC6
  2-5   ADDRESS           00 00 00 00
  6-15  FLAGS             05 00 02 30 0E 00 00 00 00 00 (constant in all captures)
 16     OPERATING_MODE    Same encoding as C0 byte[8] (see §5)
 17     FAN_SPEED         Same encoding as C0 byte[9] (see §6)
 18     SET_TEMP          Same encoding as C0 byte[10]: raw - 0x40 = °C
 19     Tp                Compressor temperature: (raw-40)/2 = °C — Confirmed Session 6 (Tp=74°C, raw=0xBC)
 20     UNKNOWN           Constant 0xD6 (87°C if sensor formula) — identity unknown, possibly discharge line
 21     T4                Outdoor ambient: (raw-40)/2 = °C — Confirmed Session 6 (T4=4°C, raw=0x31)
 22     COIL_TRACK        Variable: tracks indoor coil temp, changes with mode (heat ~56°C, cool ~38°C)
 23-29  RESERVED          All zeros in all captures
 30     CRC               Two's complement checksum
 31     EPILOGUE          0x55
```

Session 7 confirmed: byte[19] (Tp) and byte[20] remain constant (`0xBC`, `0xD6`)
across all modes (Heat, Cool, Dry, Fan). Byte[21] (T4) drifts ±1°C with ambient.
Byte[22] varies significantly with operating mode — likely indoor coil temperature
from a different measurement point than C0 T2A.

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

## References

- XYE reverse engineering: https://codeberg.org/xye/xye
- ESPHome XYE implementation: https://github.com/wtahler/esphome-mideaXYE-rs485
- HA Community XYE thread: https://community.home-assistant.io/t/midea-a-c-via-local-xye/857679
- Discoveries from mill1000/midea-msmart (`midea-msmart-mill1000.md`)
- georgezhao2010/midea_ac_lan — device type definitions (0xC3/0xCC/0xCD/0xCF)
- Midea UART reference: [protocol_uart.md](protocol_uart.md)
- UART vs. XYE comparison: [comparison_uart_vs_xye.md](comparison_uart_vs_xye.md)
