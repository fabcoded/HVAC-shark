# Midea HVAC Display–Mainboard Internal Bus Protocol

> **Source Status — Own Hardware Observations Only**
> This document is based exclusively on own hardware captures from the `HVAC-shark-dumps`
> repository (Midea XtremeSaveBlue display board, logic-analyser sessions). No external
> reference or official specification is known for this bus. All payload interpretations
> are marked as confirmed or hypothetical.

---

## 0. Bus Context

The `disp-mainboard_1` bus (BUS type `0x02` in the HVAC_shark v2 capture format) is the
internal serial link between the display PCB and the main control board inside the indoor
unit. It is physically separate from:

- the XYE / HAHB RS-485 bus (external wall-controller ↔ indoor unit)
- the UART bus (Wi-Fi module CN3 ↔ mainboard)
- the R/T bus (indoor unit ↔ outdoor unit extension board)

The display PCB appears to be the polling master; the mainboard is the responder.

**Capture sessions containing `disp-mainboard_1` data**: 1, 2, 4, 5, 6, 7, 8, 9.

---

## 1. Frame Structure

Every frame on this bus follows the same layout:

```
Offset   Size   Field         Value / Description
------   ----   -----         -------------------
  0       1     START         0xAA (always; excluded from checksum)
  1       1     TYPE          Frame type: 0x20 / 0x30 / 0x31 / 0x50 / 0xFF (see §3)
  2       1     LENGTH        Total frame length in bytes (includes bytes 0..N-1)
  3..N-2        PAYLOAD       Type-specific payload
  N-1     1     CHECKSUM      Additive checksum (see §2)
```

- The length field at byte[2] is the **total byte count** of the whole frame,
  including the `0xAA` start byte and the checksum byte itself.
- Verified across all 8 observed frame types, 50 samples each — 100 % match.

---

## 2. Checksum Algorithm

The checksum is the **Midea standard additive checksum**:

```
checksum = (256 - sum(frame[1:-1])) & 0xFF
```

- Byte[0] (`0xAA`) is **excluded** from the sum.
- The last byte of the frame (`frame[-1]`) is the checksum itself.
- Identical algorithm to the UART protocol (see `protocol_uart.md` §2).

### Verification (one example per frame type)

| Frame type      | Example frame (hex)                                                              | Declared len | Computed CK | Result |
|-----------------|----------------------------------------------------------------------------------|--------------|-------------|--------|
| AA 20 len=29    | `aa 20 1d 03 00 … 00 5f 61`                                                     | 29           | 0x61        | ✓      |
| AA 20 len=36    | `aa 20 24 03 4a 66 … 00 b9 82`                                                  | 36           | 0x82        | ✓      |
| AA 30 len=10    | `aa 30 0a 01 ff 03 00 50 54 1f`                                                  | 10           | 0x1F        | ✓      |
| AA 30 len=64    | `aa 30 40 c4 09 92 … 00 7c c3`                                                  | 64           | 0xC3        | ✓      |
| AA 31 len=32    | `aa 31 20 00 … 00 4b 64`                                                         | 32           | 0x64        | ✓      |
| AA 31 len=64    | `aa 31 40 00 4a 26 … 00 17 10`                                                  | 64           | 0x10        | ✓      |
| AA 50 len=21    | `aa 50 15 06 00 … 00 ab ea`                                                      | 21           | 0xEA        | ✓      |
| AA FF len=10    | `aa ff 0a 95 e7 0f 59 01 31 e1`                                                  | 10           | 0xE1        | ✓      |

---

## 3. Frame Type Inventory

Frame counts and session coverage across all 9 sessions in the dump set.

| Type  | Query len | Response len | Query count | Response count | Sessions        | Notes                          |
|-------|-----------|--------------|-------------|----------------|-----------------|-------------------------------|
| 0x20  | 29        | 36           | 6498        | 6501           | 1,2,4,5,6,7,8,9 | Most common pair; status poll  |
| 0x30  | 10        | 64           | 3208        | 3209           | 1,2,4,5,6,7,8,9 | Extended data response (64 B)  |
| 0x31  | 32        | 64           | 3208        | 3206           | 1,2,4,5,6,7,8,9 | Extended data response (64 B)  |
| 0x50  | 21        | 64           | 2           | 2              | 4, 9 only       | Rare; seen at session start    |
| 0xFF  | —         | —            | —           | 4 total        | 4, 9 only       | Role unclear; not a standard pair |

---

## 4. Frame Type Details and Examples

### 4.1 Type 0x20 — Status Poll

The most frequent frame type. Likely the primary status poll from display to mainboard,
exchanged approximately once per second (matching the display update rate).

**Query (29 bytes):**
```
aa 20 1d 03 00 00 00 00 00 00 00 00 00 01 00 00 00 00 00 ff 00 00 00 00 00 00 00 5f 61
                                                                                  ^^ checksum
```

**Response (36 bytes):**
```
aa 20 24 03 4a 66 00 00 00 40 00 00 00 00 00 00 90 00 ff ff 00 00 00 00 00 00 00 00 00 00 00 00 00 00 b9 82
                ^^ byte[4]=0x4A=74 (=Tp °C direct, Session 6 ground truth: Tp=74°C)
```

**Observed payload notes:**
- Response byte[3] = 0x03 (same value as query byte[3] — possible echo/ID field)
- Response byte[4] = 0x4A = 74 decimal — matches service-menu Tp = 74 °C (Session 6).
  **Hypothesis [Unconfirmed]:** byte[4] carries compressor temperature in direct °C (same
  format as UART R/T body[14]).
- Response byte[9] = 0x40, byte[16] = 0x90 — purpose unknown.
- Query is mostly zeros except byte[3]=0x03 and byte[13]=0x01, byte[19]=0xFF.

---

### 4.2 Type 0x30 — Extended Query A

Second most frequent. Query is short (10 bytes); response is 64 bytes.

**Query (10 bytes):**
```
aa 30 0a 01 ff 03 00 50 54 1f
               ^^ byte[5]=0x03, byte[7]=0x50, byte[8]=0x54
```

**Response (64 bytes):**
```
aa 30 40 c4 09 92 09 4c 04 8e 03 25 00 00 01 01 ac 03 00 00 00 00 00 00 00 00 00 01 00 00
         ^^ byte[3]=0xC4
               ^^^^ bytes[4:6]=0x0992=2450
                         ^^^^ bytes[6:8]=0x094C=2380
                                   ^^^^ bytes[8:10]=0x048E=1166
                                             ^^^^ bytes[10:12]=0x0325=805
00 00 08 00 1b 72 af b3 00 01 0a df 00 00 50 00 00 00 00 00 00 00 00 00 00 00 00 00 7c c3
```

**Observed payload notes:**
- Response byte[3] = 0xC4 — matches the XYE `ExtQuery` command code (0xC4).
  **Hypothesis [Unconfirmed]:** The mainboard may echo the last XYE C4 response payload,
  or the `0xC4` may represent a different sub-type field on this bus.
- Response bytes[4:6] = 0x0992 = 2450 — if /10: 245.0 (plausible AC line voltage in 0.1 V).
  **Hypothesis [Unconfirmed]:** electrical measurements (voltage, current, frequency).
- Bytes[16:18] = 0xAC 0x03 — could be appliance type 0xAC (air conditioner) + version 0x03,
  consistent with UART framing conventions.

---

### 4.3 Type 0x31 — Extended Query B

Same count as 0x30; likely a companion query on the same polling cycle.

**Query (32 bytes):**
```
aa 31 20 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 4b 64
```
Query payload is entirely zero (except checksum). Standard request with no parameters.

**Response (64 bytes):**
```
aa 31 40 00 4a 26 1b 00 1b 00 00 00 00 33 07 00 b7 88 33 b1 1e 00 11 16 00 00 00 00 00 00
               ^^ byte[4]=0x4A=74
                     ^^ byte[5]=0x26=38
                           ^^ byte[6]=0x1B=27

00 00 00 00 ff 03 00 00 00 02 00 64 00 64 00 00 64 00 f0 00 00 00 00 00 00 00 00 00 00 00 17 10
```

**Observed payload notes:**
- Response byte[4] = 0x4A = 74 — again matches Session 6 Tp = 74 °C.
- Response byte[5] = 0x26 = 38; byte[6] = 0x1B = 27 — possible other temperature fields.
  Applying `(raw-40)/2` formula: 38 → -1 °C, 27 → -6.5 °C. Applying direct °C: 38, 27.
  Neither interpretation maps cleanly to known T1/T3/T4 values from Session 6
  (T1=18, T3=2, T4=4 °C). **Status: Unconfirmed.**
- byte[34] = 0xFF, byte[35] = 0x03 — could be a capability or status bitfield.
- byte[40] = 0x64 = 100; byte[42] = 0x64 = 100; byte[44] = 0x64 = 100 — repeated 0x64
  could be fan speed (100%), percentage values, or a fixed marker.

---

### 4.4 Type 0x50 — Rare Frame

Only 2 query + 2 response frames observed, in Sessions 4 and 9 only. Likely related to
initialisation or mode-change events at session start.

**Query (21 bytes):**
```
aa 50 15 06 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 ab ea
               ^^ byte[3]=0x06
```

**Response (64 bytes):**
```
aa 50 40 96 04 20 00 0c 18 41 00 0e 0d 0a 00 23 1e 10 1e 10 1e 10 00 05 00 00 00 00 00 00
         ^^ byte[3]=0x96
               ^^ byte[4]=0x04
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 da a0
```

No payload interpretation attempted given sparse sample count.

---

### 4.5 Type 0xFF — Anomalous / Rare

4 total occurrences in Sessions 4 and 9. May be a sync frame, error recovery frame, or
bus reset signal.

**Example (10 bytes):**
```
aa ff 0a 95 e7 0f 59 01 31 e1
```

---

## 5. Framing Integrity Summary

Confirmed across 50 samples of each dominant frame type:

| Property                | Algorithm                            | Match rate |
|-------------------------|--------------------------------------|-----------|
| Length field (byte[2])  | Total frame byte count               | 100%      |
| Checksum (last byte)    | `(256 - sum(frame[1:-1])) & 0xFF`    | 100%      |

No CRC-8 field was found. The single checksum byte is sufficient error detection on this
internal bus where the path is short and electrically clean.

---

## 6. Protocol Behaviour

Based on frame counts and pairing:

- **Polling cadence**: 0x20 frames appear at ~1 Hz (matches display refresh). 0x30 and 0x31
  frames appear at approximately 0.5 Hz (one of each per two 0x20 cycles).
- **Request-response**: Each query is immediately followed by its response. No observed
  broadcast or unsolicited responses.
- **Query lengths are fixed**: 0x20 query is always 29 bytes, 0x30 always 10 bytes, 0x31
  always 32 bytes.
- **Response lengths are fixed**: All three response types always return 36 or 64 bytes
  depending on type.

---

## 7. Relationship to Other Buses

| Bus          | Shares checksum algorithm? | Shares 0xAA start byte? | Known relationship        |
|--------------|---------------------------|------------------------|---------------------------|
| UART (Wi-Fi) | Yes — identical formula   | Yes                    | Separate physical bus      |
| R/T (outdoor)| Yes — identical formula   | Yes (requests)         | Separate physical bus      |
| XYE (RS-485) | No (XYE has no checksum)   | No (XYE uses 0x55)     | None                      |

The `0xC4` marker in the 0x30 response (§4.2) suggests the mainboard may internally relay
XYE ExtQuery data onto this bus, but this is unconfirmed.

---

## 8. Open Questions

1. **Exact payload semantics of 0x20**: Which fields carry setpoint, mode, fan speed?
   Byte[4] = Tp is the only byte with a ground-truth anchor (Session 6).
2. **Byte[3] in 0x30 response = 0xC4**: Coincidence with XYE command code, or deliberate
   forwarding of C4 data? Cross-referencing 0x30 response bytes with XYE C4 response bytes
   across sessions would resolve this.
3. **Temperatures in 0x31 response**: byte[5], byte[6] do not map cleanly to known sensor
   values — different formula, different sensor, or different encoding?
4. **0x50 frame purpose**: Only seen at session start (Sessions 4, 9). Initialisation
   handshake? Configuration exchange?
5. **No CRC-8**: Confirmed absent. Single additive checksum only.
6. **Direction identification**: All frames were captured on a single channel
   (`mainboard-cn1`). Query vs response labelling here is based on frame length pairing and
   timing inference; physical direction (display→board vs board→display) is not confirmed
   from capture data alone.
