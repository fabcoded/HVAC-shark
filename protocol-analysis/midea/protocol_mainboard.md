# Midea HVAC Display–Mainboard Internal Bus Protocol

> **Source Status — Own Hardware Observations Only**
> This document is based exclusively on own hardware captures from the `HVAC-shark-dumps`
> repository (Midea XtremeSaveBlue display board, logic-analyser sessions). No external
> reference or official specification is known for this bus.
>
> **Hypothesis-driven format**: Payload field assignments derived from cross-session
> correlation are marked as **[H-nn]** hypotheses. Each hypothesis requires independent
> verification in a dedicated verification session. Facts confirmed by framing analysis
> (checksums, frame structure) are marked **[Confirmed]**.

---

## 0. Bus Context

The `disp-mainboard_1` bus (BUS type `0x02` in the HVAC_shark v2 capture format) is the
internal serial link between the display PCB and the main control board inside the indoor
unit. It is physically separate from:

- the XYE / HAHB RS-485 bus (external wall-controller ↔ indoor unit)
- the UART bus (Wi-Fi module CN3 ↔ mainboard)
- the R/T bus (indoor unit ↔ outdoor unit extension board)

**Physical wiring** (CN1 connector on display board):
- **Grey wire**: display → mainboard (TXD) — referred to as "Grey" direction
- **Blue wire**: mainboard → display (RXD) — referred to as "Blue" direction

The display PCB is the polling master; the mainboard is the responder. **[Confirmed]**

**Capture sessions containing `disp-mainboard_1` data**: 1, 2, 4, 5, 6, 7, 8, 9.

---

## 1. Frame Structure

**[Confirmed]** Every frame on this bus follows the same layout:

```
Offset   Size   Field         Value / Description
------   ----   -----         -------------------
  0       1     START         0xAA (always)
  1       1     TYPE          Frame type: 0x20 / 0x30 / 0x31 / 0x50 / 0xFF (see §3)
  2       1     LENGTH        Total frame length in bytes (includes bytes 0..N-1)
  3..N-3        PAYLOAD       Type-specific payload
  N-2     1     CRC8          CRC-8/MAXIM over bytes[0..N-3] (see §2.1)
  N-1     1     CHECKSUM      Additive checksum (see §2.2)
```

- The length field at byte[2] is the **total byte count** of the whole frame,
  including the `0xAA` start byte and the checksum byte itself.

---

## 2. Integrity Checks

### 2.1 CRC-8/MAXIM  **[Confirmed]**

The second-to-last byte is a **CRC-8/MAXIM** (also known as CRC-8/Dallas, DOW CRC):

| Parameter      | Value              |
|----------------|--------------------|
| Polynomial     | 0x31 (normal form) |
| Reflected poly | 0x8C               |
| Init value     | 0x00               |
| RefIn / RefOut | true / true        |
| XorOut         | 0x00               |
| Byte range     | `frame[0 .. -3]` (start byte through end of payload, exclusive of CRC and checksum) |

**Verification**: Tested against **25,832 frames** across 8 sessions — **100% match**.

This is the **same CRC-8 polynomial** used by the UART bus (both use the CRC-8/MAXIM table).
The byte range differs: mainboard CRC covers bytes[0..N-3] including the 0xAA start byte,
while UART CRC covers a different span (see `protocol_uart.md`).

### 2.2 Additive Checksum  **[Confirmed]**

The last byte is the **Midea standard additive checksum**:

```
checksum = (256 - sum(frame[1:-1])) & 0xFF
```

- Byte[0] (`0xAA`) is **excluded** from the sum.
- Identical algorithm to the UART protocol (see `protocol_uart.md` §2).

**Verification**: 100% match across all 25,832 frames.

### 2.3 Verification Examples (one per frame type)

| Frame type      | Example frame (hex)                                                              | CRC8 | CK   | Result |
|-----------------|----------------------------------------------------------------------------------|------|------|--------|
| AA 20 len=36    | `aa 20 24 03 4a 66 … 00 b9 82`                                                  | 0xB9 | 0x82 | ✓      |
| AA 20 len=29    | `aa 20 1d 03 00 … 00 5f 61`                                                     | 0x5F | 0x61 | ✓      |
| AA 30 len=10    | `aa 30 0a 01 ff 03 00 50 54 1f`                                                  | 0x54 | 0x1F | ✓      |
| AA 30 len=64    | `aa 30 40 c4 09 92 … 00 7c c3`                                                  | 0x7C | 0xC3 | ✓      |
| AA 31 len=32    | `aa 31 20 00 … 00 4b 64`                                                         | 0x4B | 0x64 | ✓      |
| AA 31 len=64    | `aa 31 40 00 4a 26 … 00 17 10`                                                  | 0x17 | 0x10 | ✓      |
| AA 50 len=21    | `aa 50 15 06 00 … 00 ab ea`                                                      | 0xAB | 0xEA | ✓      |
| AA FF len=10    | `aa ff 0a 95 e7 0f 59 01 31 e1`                                                  | 0x31 | 0xE1 | ✓      |

---

## 3. Frame Type Inventory

Frame counts and session coverage across all captured sessions.

| Type  | Grey (req) len | Blue (rsp) len | Grey count | Blue count | Sessions         | Purpose                         |
|-------|----------------|----------------|------------|------------|------------------|---------------------------------|
| 0x20  | 36             | 29             | 6498       | 6501       | 1,2,4,5,6,7,8,9 | Main control/status exchange    |
| 0x30  | 10             | 64             | 3208       | 3209       | 1,2,4,5,6,7,8,9 | Sensor telemetry data           |
| 0x31  | 32             | 64             | 3208       | 3206       | 1,2,4,5,6,7,8,9 | Configuration/identification    |
| 0x50  | 21             | 64             | 2          | 2          | 4, 9 only        | Boot initialisation (boot only) |
| 0xFF  | 10             | 10             | 2          | 2          | 4, 9 only        | Bus sync handshake (boot only)  |

---

## 4. Polling Cycle  **[Confirmed]**

The display board polls the mainboard in a fixed alternating pattern:

```
Grey→Blue: AA20  (status exchange)
Grey→Blue: AA30  (sensor telemetry)
Grey→Blue: AA20  (status exchange)
Grey→Blue: AA31  (config/identification)
(repeat)
```

- **Full cycle period**: ~530 ms
- **AA20 interval**: ~265 ms (twice per cycle)
- **AA30 and AA31**: alternate in the "B" slot, each appearing once per full cycle (~530 ms)
- Request-response is strictly synchronous: each Grey request is immediately followed by
  its Blue response before the next request.

---

## 5. Type 0x20 — Main Control/Status Exchange

### 5.1 Grey Request (Display → Mainboard, 36 bytes)

This is the primary control frame sent by the display board to the mainboard.

```
Offset  Field              Hypothesis   Encoding
------  -----              ----------   --------
  0     START              [Confirmed]  0xAA
  1     FRAME_TYPE         [Confirmed]  0x20
  2     LENGTH             [Confirmed]  0x24 (= 36)
  3     MODE               [H-01 VERIFIED]  0=Cool, 1=Dry, 2=Fan, 3=Heat, 4=Auto
  4     SET_TEMP           [H-02 VERIFIED]  temp_C × 2 + 30  (e.g. 21°C → 0x48)
  5     FAN_SPEED          [H-03 VERIFIED]  102=Auto, 100=Turbo, 80=High, 60=Med, 40=Low, 20=Silent
  6–8   (unknown)                            Always 0x00 in observed sessions
  9     FLAGS              [H-04 PARTIAL]   bit6=power, bit4=H-swing, bit2=V-swing
 10–15  (unknown)                       Always 0x00 in observed sessions
 16     COUNTER            [H-05]       Upper nibble increments by 0x20 per frame (0x00→0xE0, wraps)
 17     (unknown)                       Always 0x00
 18–19  (unknown)                       Always 0xFF 0xFF
 20     (unknown)                       Always 0x00
 21     VANE_POS           [H-06]       upper nibble=H-vane, lower nibble=V-vane
                                        values 1,3,5,7,9 = 5 positions each direction
 22–33  (unknown)                       Always 0x00 in observed sessions
 34     CRC8               [Confirmed]  CRC-8/MAXIM
 35     CHECKSUM           [Confirmed]  Additive checksum
```

### 5.2 Blue Response (Mainboard → Display, 29 bytes)

The mainboard's status report back to the display.

```
Offset  Field              Hypothesis   Encoding
------  -----              ----------   --------
  0     START              [Confirmed]  0xAA
  1     FRAME_TYPE         [Confirmed]  0x20
  2     LENGTH             [Confirmed]  0x1D (= 29)
  3     MODE               [H-07 VERIFIED]  Same index encoding as Grey byte[3],
                                          plus mode=5 = "initializing" (see §12)
  4     (unknown)                         Varies — possibly sensor reading
  5     ACTUAL_FAN         [H-08 VERIFIED]  Actual indoor blower speed (see §13)
  6–12  (unknown)                         Varies
 13     (status flag)      [H-09]        Always 0x01 in observed sessions
 14–18  (unknown)                        Varies
 19     READY              [H-10]       0xFF = system ready, 0x00 at boot
 20–26  (unknown)                        Varies
 27     CRC8               [Confirmed]  CRC-8/MAXIM
 28     CHECKSUM           [Confirmed]  Additive checksum
```

---

## 6. Type 0x30 — Sensor Telemetry

### 6.1 Grey Request (10 bytes)

Short fixed query — no parameters observed to vary across sessions.

```
aa 30 0a 01 ff 03 00 50 [CRC] [CK]
```

### 6.2 Blue Response (64 bytes)

Contains continuously varying sensor data. Hundreds of unique frames per session indicate
real-time telemetry.

**Decoded fields**:

```
Offset  Field              Status                  Encoding
------  -----              ------                  --------
  3     SUB_TYPE           [H-11]                  0xC4 — matches XYE ExtQuery command code
  4     OUTDOOR_TEMP       [CROSS-BUS VALIDATED]   raw / 2.0 °C
  6     (unknown)          [T? candidate]          Range 2–20, varies across sessions
 11     (discharge temp?)  [T? candidate]          0 when cold, 40–88 in heating — likely direct °C
 16     APPLIANCE_TYPE     [H-13]                  0xAC = air conditioner (UART convention)
 17     PROTOCOL_VER       [H-13]                  0x03
 19     (compressor?)      [T? candidate]          0 when compressor off, 0–145 during operation
 45     (heat-related?)    [T? candidate]          0 when idle, peaks to 59 during sustained heating
```

**byte[4] — Outdoor Temperature** [CROSS-BUS VALIDATED]:
Cross-bus validated against R/T C0 outdoor temperature (488 time-matched pairs within ±0.5 s,
avg_diff = 0.88 °C, 93.8% within 2 °C). The encoding `raw / 2.0` is unique to the mainboard
bus — the UART and R/T buses use `(raw - 50) / 2.0` for the same physical sensor.

| Session | Raw range | Decoded range    | R/T reference | Avg diff |
|---------|-----------|-----------------|---------------|----------|
| 4       | 11        | 5.5 °C          | 5.5 °C        | 0.0 °C   |
| 7       | 8–11      | 4.0–5.5 °C      | 3.5–5.0 °C    | 0.88 °C  |
| 8       | 8         | 4.0 °C          | 4.0 °C        | 0.0 °C   |
| 9       | 9         | 4.5 °C          | 4.5 °C        | 0.0 °C   |

**Indoor temperature not identified**: No byte in the AA30 response reliably matches
R/T or UART indoor temperature readings across all sessions.

**Former H-12 (bytes[4:6] = voltage) superseded**: byte[4] alone is outdoor temperature;
byte[5] is a separate field (not yet decoded).

#### Temperature Candidates [T?]

Statistical analysis across Sessions 4, 7, 8, 9 identified four bytes with temperature-like
behavior. None could be cross-bus validated because no UART A1 heartbeat data (which carries
coil and pipe temperatures) was available in any session.

**byte[11] — Compressor discharge pipe temperature?** (strongest candidate)

Behaviour matches compressor discharge pipe temp (Tp in UART A1 heartbeat): zero/low when
compressor is off, rises to 60–80+ during sustained heating. Encoding candidate: `direct °C`.

| Session | Context                | Raw range | Mean | Behaviour |
|---------|------------------------|-----------|------|-----------|
| 4       | Cold boot → Heat       | 0–19      | 11.0 | Rising from cold start |
| 7       | Active heating (long)  | 40–88     | 58.0 | Varies with compressor load |
| 8       | Sustained heating      | 68–83     | 77.0 | High, stable — hot discharge |
| 9       | Brief run, mode cycling| 0–41      | 26.2 | Low, compressor barely ran |

**byte[6] — Unknown temperature?**

Small values (2–20), varies across sessions. Cross-session means increase with heating
activity (S4: 5.1, S7: 8.6, S8: 17.6) but do not track any known reference temperature.

**byte[19] — Compressor-related metric?**

Zero when compressor is off (S4 startup, S9 cycling), rises to 97–145 during sustained
operation (S8). May be compressor current, superheat, or secondary sensor. Too high for
most temperature encodings unless scaled.

**byte[45] — Heat-related metric?**

Near zero in most sessions (mean 2–4), jumps to mean=43.7 in Session 8 (sustained heating).
Could be a secondary coil temperature or accumulated runtime/energy counter.

**Other patterns**:
- Bytes[16:18] = 0xAC 0x03 — 0xAC = air conditioner appliance type in UART convention.
  **[H-13]** These bytes carry appliance type and protocol version.

**Example (64 bytes)**:
```
aa 30 40 c4 09 92 09 4c 04 8e 03 25 00 00 01 01 ac 03 00 00 00 00 00 00 00 00 00 01 00 00
00 00 08 00 1b 72 af b3 00 01 0a df 00 00 50 00 00 00 00 00 00 00 00 00 00 00 00 00 7c c3
```

---

## 7. Type 0x31 — Configuration/Identification

### 7.1 Grey Request (32 bytes)

Fixed all-zeros payload — a parameter-less status query.

```
aa 31 20 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [CRC] [CK]
```

### 7.2 Blue Response (64 bytes)

**Decoded fields**:

```
Offset  Field              Status                  Encoding
------  -----              ------                  --------
  4     SETPOINT_ECHO      [H-14]                  (raw - 30) / 2.0 °C  (same as AA20 Grey byte[4])
  5     STORED_OUTDOOR     [CROSS-BUS CANDIDATE]   (raw - 40) / 2.0 °C
```

**byte[5] — Stored Outdoor Temperature** [CROSS-BUS CANDIDATE]:
Cross-bus matched against R/T C0 outdoor temperature (487 time-matched pairs within ±0.5 s,
avg_diff = 0.93 °C). Value is **constant within each session**, suggesting a stored/config
value rather than a live sensor reading.

| Session | Raw | Decoded      | R/T reference | Diff   |
|---------|-----|-------------|---------------|--------|
| 4       | 51  | 5.5 °C      | 5.5 °C        | 0.0 °C |
| 7       | 49  | 4.5 °C      | 3.5–5.0 °C    | ~0.7 °C|
| 8       | 47  | 3.5 °C      | 4.0 °C        | 0.5 °C |
| 9       | 49  | 4.5 °C      | 4.5 °C        | 0.0 °C |

**Other fields**:
- byte[34] = 0xFF, byte[35] = 0x03 — possibly capability or status bitfield.
- bytes[40,42,44] = 0x64 = 100 — repeated value; possibly percentage or fixed marker.

**Example (64 bytes)**:
```
aa 31 40 00 4a 26 1b 00 1b 00 00 00 00 33 07 00 b7 88 33 b1 1e 00 11 16 00 00 00 00 00 00
00 00 00 00 ff 03 00 00 00 02 00 64 00 64 00 00 64 00 f0 00 00 00 00 00 00 00 00 00 00 00 17 10
```

---

## 8. Boot-Only Frame Types

Both type 0x50 and 0xFF were observed **only** in Sessions 4 and 9, which are the only
sessions that captured a cold-boot (power-on from mains-off state).

### 8.1 Type 0xFF — Bus Sync Handshake  **[H-15]**

Appears at t < 1 s after power-on. Identical payload in both directions (Grey and Blue).
Hypothesis: a link-layer handshake confirming bus readiness.

```
aa ff 0a 95 e7 0f 59 01 [CRC] [CK]
```

The payload was byte-identical between Sessions 4 and 9.

### 8.2 Type 0x50 — Boot Initialisation Exchange  **[H-16]**

Appears once per boot at t ≈ 0.93 s. 21-byte request, 64-byte response.

**Request**:
```
aa 50 15 06 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 [CRC] [CK]
```

**Response** (64 bytes):
```
aa 50 40 96 04 20 00 0c 18 41 00 0e 0d 0a 00 23 1e 10 1e 10 1e 10 00 05 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 da a0
```

Hypothesis: contains non-volatile configuration data (firmware version, hardware config).
The response was byte-identical between Sessions 4 and 9, consistent with a fixed
hardware/firmware identification block.

---

## 9. Cross-Bus Correlation Summary

Correlations established between the mainboard bus and UART / R/T buses:

| Property               | Mainboard (disp-MB)              | UART / R/T                        | Match? |
|------------------------|----------------------------------|------------------------------------|--------|
| Start byte             | 0xAA                             | 0xAA                               | Yes    |
| Additive checksum      | `(256-sum(frame[1:-1]))&0xFF`    | Same                               | Yes    |
| CRC algorithm          | CRC-8/MAXIM (poly 0x31 reflected)| Same CRC-8/MAXIM polynomial        | Yes — same table, different byte range |
| Mode encoding          | Simple index (0–4)               | Bitfield in C0 body[2] bits[7:5]   | No — different scheme |
| Setpoint encoding      | `temp_C × 2 + 30`               | Same formula                       | Yes    |
| Outdoor temp encoding  | AA30[4]: `raw / 2.0`            | UART/R/T: `(raw - 50) / 2.0`      | No — different encoding, same sensor |
| Fan speed values       | 102/100/80/60/40/20              | Same                               | Yes    |
| Swing flag style       | bit4=H-swing, bit2=V-swing      | Similar bit-position convention    | Similar |
| Vane position values   | 1,3,5,7,9 (5 steps)             | Same 5-step scale                  | Yes    |

---

## 10. Hypothesis Register

All hypotheses derived from cross-session correlation analysis (Sessions 4, 7, 8, 9).
Each requires independent verification in a dedicated test session.

| ID    | Frame     | Byte(s) | Claim                                                           | Evidence basis                          | Status       |
|-------|-----------|---------|-----------------------------------------------------------------|-----------------------------------------|--------------|
| H-01  | 0x20 Grey | [3]     | Mode index: 0=Cool, 1=Dry, 2=Fan, 3=Heat, 4=Auto              | R/T C0 cross-correlation S4/S7/S8/S9   | **VERIFIED** (79 pairs, 100% match, all 5 modes confirmed) |
| H-02  | 0x20 Grey | [4]     | Setpoint: `temp_C × 2 + 30`                                    | R/T C0 cross-correlation S4/S7/S8/S9   | **VERIFIED** (42 pairs, 39 exact / 3 inter-bus delay at 1°C) |
| H-03  | 0x20 Grey | [5]     | Fan speed: 102=Auto, 100=Turbo, 80=High, 60=Med, 40=Low, 20=Silent | R/T C0 cross-correlation S4/S7/S8/S9 | **VERIFIED** (89 pairs, 100% match) |
| H-04  | 0x20 Grey | [9]     | Flags: bit6=power, bit4=H-swing, bit2=V-swing                  | S8 swing test phases                   | **PARTIAL** (194 pairs, 100% match, but only swing=off tested; swing=on needs coverage) |
| H-05  | 0x20 Grey | [16]    | Upper nibble = frame counter (increments 0x20/frame, wraps)    | Sequence analysis S4/S7                 | Unverified   |
| H-06  | 0x20 Grey | [21]    | Vane position: hi-nib=H-vane, lo-nib=V-vane (1,3,5,7,9)       | S8 Phase 3 fixed vane sweep             | Unverified   |
| H-07  | 0x20 Blue | [3]     | Mode echo: same index encoding as Grey byte[3], plus mode=5 = initializing | R/T C0 cross-correlation + boot analysis S4/S9 | **VERIFIED** (74/79 steady-state match; 5 "failures" are mode=5 init state at boot — see §12) |
| H-08  | 0x20 Blue | [5]     | Actual indoor blower speed (not requested, but actual)          | S7 manual fan sweep + power-off + Auto analysis | **VERIFIED** (see §13 — matches request when running; 0=stopped, 1=idle, 23/103=heat-specific) |
| H-09  | 0x20 Blue | [13]    | Status flag, always 0x01                                        | All sessions                            | Unverified   |
| H-10  | 0x20 Blue | [19]    | Ready flag: 0xFF=ready, 0x00=booting                            | S9 cold-boot sequence                   | Unverified   |
| H-11  | 0x30 Blue | [3]     | 0xC4 sub-type = relayed XYE ExtQuery data                       | Matches XYE C4 command code             | Unverified   |
| H-12  | 0x30 Blue | [4]     | ~~AC line voltage~~ → **Outdoor temp: `raw / 2.0` °C**          | 488 cross-bus pairs, avg_diff=0.88°C    | **CROSS-BUS VALIDATED** |
| H-13  | 0x30 Blue | [16:18] | Appliance type (0xAC) + protocol version (0x03)                 | Matches UART convention                 | Unverified   |
| H-14  | 0x31 Blue | [4]     | Setpoint echo using `temp_C × 2 + 30`                           | Correlates with AA20 byte[4]            | Unverified   |
| H-15  | 0xFF      | all     | Bus sync handshake at power-on (identical both directions)      | S4/S9 cold-boot only, identical payload | Unverified   |
| H-16  | 0x50      | all     | Boot init: non-volatile config/firmware ID block                | S4/S9 identical, boot-only occurrence   | Unverified   |
| T-01  | 0x30 Blue | [11]    | Compressor discharge pipe temp (Tp), direct °C                  | 0 when cold, 40–88 in heating; matches Tp behaviour | **CANDIDATE** — needs UART A1 |
| T-02  | 0x30 Blue | [6]     | Unknown temperature, range 2–20                                 | Varies across sessions, no ref match    | **CANDIDATE** — needs UART A1 |
| T-03  | 0x30 Blue | [19]    | Compressor-related metric, 0 when off, up to 145                | Correlates with compressor activity     | **CANDIDATE** — needs UART A1 |
| T-04  | 0x30 Blue | [45]    | Heat-related, 0 when idle, peaks to 59                          | High only in sustained heating (S8)     | **CANDIDATE** — needs UART A1 |
| T-05  | 0x31 Blue | [5]     | Stored outdoor temp, `(raw - 40) / 2.0` °C                     | 487 cross-bus pairs, avg_diff=0.93°C    | **CROSS-BUS CANDIDATE** |

### Automated Validation Results

Validation script: `validate_mainboard_hypotheses.py`
Method: For each steady-state R/T C0 frame (value unchanged from neighboring frames),
find the nearest mainboard AA20 frame within 0.5 s and compare field values.
Sessions used: 4, 7, 8, 9 (total: 4819 MB Grey, 4819 MB Blue, 289 R/T C0 frames).

| ID    | Field            | Pairs | Match | Fail | Status           | Notes |
|-------|------------------|-------|-------|------|------------------|-------|
| H-01  | Mode             | 79    | 79    | 0    | **VERIFIED**     | All 5 modes confirmed (Cool/Dry/Fan/Heat/Auto) |
| H-02  | Setpoint temp    | 42    | 39    | 3    | **VERIFIED**     | 3 failures are inter-bus propagation delay (exactly 1°C, 4.2%) |
| H-03  | Fan speed        | 89    | 89    | 0    | **VERIFIED**     | Includes RT=101 (within 2% of 102=Auto) |
| H-04  | Swing flags      | 194   | 194   | 0    | **PARTIAL**      | 100% match but only swing=off/off tested |
| H-07  | Mode echo (Blue) | 79    | 74    | 5    | **VERIFIED**     | 5 "failures" are mode=5 init state at boot (see §12) |
| H-08  | Actual fan       | 226   | 82    | 144  | **VERIFIED**     | 144 "fails" are fan=0 during Heat warm-up (correct: fan stopped). See §13 |

**H-02 failure analysis**: 3 mismatches at t=77-84s in Session 7 — the R/T bus reports 24°C
while the mainboard already shows 25°C. The encoding formula is correct; the discrepancy is
inter-bus propagation delay during the Session 7 temperature sweep. Both buses use the same
`temp_C × 2 + 30` formula when they agree (39/42 pairs, exact match).

**H-07 resolution**: MB Blue byte[3] can report mode value **5** during system startup.
This is NOT defrost — it is an **initialization state** (see §12 for full analysis).
R/T C1 frames in Sessions 4 and 9 have only 24 body bytes (too short for the defrost
flag at body[32]), and no UART C1 extended status frames were present during mode=5 periods.
The mode=5 state was observed across two different requested modes (Heat in S4, Fan in S9),
confirming it is mode-independent.

**H-08 re-verified**: MB Blue byte[5] IS the actual indoor blower speed — the initial
rejection was caused by comparing against the R/T C0 _requested_ fan speed. The actual
speed differs from the request when the system is transitioning or in Heat warm-up.
See §13 for full analysis.

### Verification Plan (remaining unverified hypotheses)

To verify the remaining hypotheses, a dedicated session should:

1. **Mode sweep** (H-01, H-07): Cycle through each mode individually with pauses
   (>5 s per mode) in order: Cool → Dry → Fan → Heat → Auto, confirming byte[3]
   changes to 0,1,2,3,4 respectively.
2. **Temperature sweep** (H-02, H-14): Set a known temperature (e.g. 16°C),
   confirm byte[4] = 62 (`16×2+30`), then step to 30°C, confirm byte[4] = 90.
3. **Fan sweep** (H-03, H-08): Set each fan speed with pauses, verify Grey byte[5]
   and Blue byte[5] values.
4. **Swing test** (H-04): Toggle H-swing on/off, V-swing on/off, confirm byte[9] bits.
5. **Vane position test** (H-06): Set each of the 5 vertical and 5 horizontal positions,
   verify byte[21] nibble values.
6. **Power on/off** (H-04 bit6, H-10): Power cycle via remote, observe byte[9] bit6
   and Blue byte[19] transition.
7. **Cold boot** (H-15, H-16): Power-cycle from mains to confirm 0xFF and 0x50 frames.

### Temperature Candidate Validation Plan (T-01 through T-05)

The existing sessions cannot resolve T-01 through T-04 because no UART A1 heartbeat
data was captured. The UART A1 heartbeat provides the reference temperatures needed:

| UART A1 field | Sensor                  | Encoding       | Candidate to test against |
|---------------|-------------------------|----------------|---------------------------|
| body[10] (T1) | Indoor coil             | (raw-30)/2     | T-02 (byte[6]?)           |
| body[12] (T3) | Outdoor coil            | (raw-50)/2     | T-02, T-04                |
| body[13] (T4) | Outdoor ambient         | (raw-50)/2     | already covered by H-12   |
| body[14] (Tp) | Compressor discharge    | direct °C      | **T-01 (byte[11])**       |

#### Prerequisites

1. **WiFi module connected and paired**: The UART A1 heartbeat is generated by the
   mainboard→WiFi link. Without the WiFi module on CN3, no UART A1 frames are produced.
   Ensure the msmart-ng or similar polling agent is running so the mainboard sends periodic
   A1 heartbeat responses.

2. **All 4 buses captured simultaneously**: HVAC-shark must sniff disp-mainboard (bus 0x02),
   UART (bus 0x01), R/T (bus 0x03), and optionally XYE. The key is having UART A1 and
   MB AA30 in the same capture for time-matched correlation.

#### Session Protocol

**Phase 1 — Cold start baseline** (validates T-01, T-03 zero-state)
- Power off at mains for ≥10 min (all temperatures equalize to ambient)
- Start capture, restore mains power
- Wait 60 s — during this period all temperatures should read near ambient
- **Expected**: AA30 byte[11] ≈ room temperature, Tp ≈ room temperature
- **Validates**: T-01 encoding (direct °C vs offset formula) and zero-state behaviour

**Phase 2 — Heat ramp-up** (validates T-01, T-03, T-04 dynamic tracking)
- Set to Heat mode, 30°C setpoint, Auto fan
- Let compressor run for ≥10 min (discharge temp should rise to 50–90°C)
- **Expected**: AA30 byte[11] rises in sync with UART A1 Tp
- **Cross-check T-01**: Time-matched pairs of AA30 byte[11] vs UART A1 body[14],
  test encodings: `direct °C`, `r/2`, `(r-30)/2`, `(r-50)/2`
- **Cross-check T-02**: AA30 byte[6] vs UART A1 T1 (indoor coil) and T3 (outdoor coil)
- **Cross-check T-03**: AA30 byte[19] vs UART A1 Tp and compressor current (if available)
- **Cross-check T-04**: AA30 byte[45] vs all UART A1 temps

**Phase 3 — Steady state** (validates all candidates at thermal equilibrium)
- Continue heating for another 5 min at steady state
- All temperatures should be relatively stable — good for encoding formula verification
- Record service menu T1–T4 readings as independent ground truth

**Phase 4 — Cool-down / mode change** (validates T-01 decreasing behaviour)
- Switch to Fan mode (compressor off, indoor fan continues)
- Let system run for ≥5 min — discharge temp should fall, coil temps equalize
- **Expected**: AA30 byte[11] decreases toward ambient
- **Validates**: T-01 tracks both rising and falling discharge temperature

**Phase 5 — Cool mode** (validates candidates under reversed thermal flow)
- Switch to Cool mode, 16°C setpoint (if outdoor temp allows cooling)
- Run ≥5 min — outdoor coil should be hot, indoor coil cold
- **Validates**: T-02 encoding under reversed polarity, distinguishes indoor vs outdoor coil

#### Acceptance Criteria

| Candidate | Pass criteria | Minimum pairs |
|-----------|---------------|---------------|
| T-01      | avg_diff < 2°C vs UART A1 Tp across Phases 1–4 | 200 |
| T-02      | avg_diff < 2°C vs any UART A1 temp (T1/T3/T4) | 100 |
| T-03      | Consistent correlation with compressor state AND ≥1 UART A1 field | 100 |
| T-04      | avg_diff < 2°C vs any UART A1 temp | 100 |
| T-05      | avg_diff < 1°C vs R/T outdoor across ≥3 different outdoor temps | 50 |

**T-05 (AA31 byte[5] stored outdoor)** requires captures at different outdoor temperatures
(e.g. winter vs spring) since the value is constant within sessions. The existing 4-session
data already shows avg_diff = 0.93°C across a narrow 3.5–5.5°C outdoor range. A session at
≥15°C outdoor would provide the needed diversity.

---

## 11. Mode Index Mapping Detail

**[H-01 VERIFIED]** The mainboard uses a **simple integer index** for operating mode,
unlike the UART/R/T bitfield encoding:

| Mainboard byte[3] | Mode  | UART mode_bits | UART/R/T C0 body[2] bits[7:5] | Verified pairs |
|--------------------|-------|----------------|-------------------------------|----------------|
| 0                  | Cool  | 2              | 010                           | 40             |
| 1                  | Dry   | 3              | 011                           | 7              |
| 2                  | Fan   | 5              | 101                           | 4              |
| 3                  | Heat  | 4              | 100                           | 27             |
| 4                  | Auto  | 1              | 001                           | 1              |

Validation method: For each steady-state R/T C0 frame (value unchanged from neighbors),
find the nearest mainboard AA20 Grey frame within 0.5 s. 79 pairs across Sessions 4, 7, 8,
and 9 — **100% match rate**.

---

## 12. Blue Response Mode=5 — Initialization State  **[Confirmed]**

The MB Blue response byte[3] can report **mode=5**, a value outside the Grey request
range (0–4). Investigation across Sessions 4 and 9 confirms this is a **startup/initialization
state**, not defrost or any other operating mode.

### Evidence

**Session 4** (cold boot into Heat):

| Period          | Duration | Grey byte[3] | Blue byte[3] | Blue byte[5] |
|-----------------|----------|--------------|--------------|--------------|
| t = 15.6–39.5 s | ~24 s    | 3 (Heat)     | **5 (init)** | 0            |
| t = 39.5 s →    | ~55 s    | 3 (Heat)     | 3 (Heat)     | varies       |

**Session 9** (cold boot, rapid mode cycling):

| Period          | Duration | Grey byte[3] | Blue byte[3] | Blue byte[5] |
|-----------------|----------|--------------|--------------|--------------|
| t = 11.0–19.5 s | ~8.5 s   | 2 (Fan)      | **5 (init)** | 0            |
| t = 19.5–23.4 s | ~4 s     | 2 (Fan)      | 2 (Fan)      | varies       |
| t = 23.4–25.0 s | ~1.6 s   | 1 (Dry)      | 1 (Dry)      | varies       |
| t = 25.0 s →    | ~58 s    | 3 (Heat)     | 3 (Heat)     | varies       |

### Key observations

1. Mode=5 appears **only at session start** (first Blue frame in both S4 and S9).
2. It is **mode-independent**: S4 requested Heat (Grey=3), S9 requested Fan (Grey=2) — both
   got Blue=5 during initialization.
3. Sessions 7 and 8 have **zero** mode=5 frames — these captures started after the
   initialization window had already closed.
4. Blue byte[5] = 0 during mode=5 in all cases (vs. variable during normal operation).
5. The transition from mode=5 → confirmed mode coincides with the mainboard completing
   startup. Session 4: 24 s init, Session 9: 8.5 s init (different due to prior thermal state?).

### Defrost investigation

The hypothesis that mode=5 = defrost was tested and **rejected**:

- R/T C1 frames during mode=5 periods have body_len=24 — too short to contain the load
  state / defrost flag (at body[32], requiring body_len ≥ 33).
- No UART C1 extended status frames exist in Sessions 4 or 9 during the mode=5 window.
- Mode=5 appears during both Heat (S4) and Fan (S9) — defrost is only meaningful in Heat.

### Updated mode table

| Mainboard byte[3] | Meaning      | Direction        |
|--------------------|-------------|------------------|
| 0                  | Cool         | Grey + Blue      |
| 1                  | Dry          | Grey + Blue      |
| 2                  | Fan          | Grey + Blue      |
| 3                  | Heat         | Grey + Blue      |
| 4                  | Auto         | Grey + Blue      |
| 5                  | Initializing | **Blue only**    |

---

## 13. Blue byte[5] — Actual Indoor Blower Speed  **[H-08 VERIFIED]**

Blue byte[5] reports the **actual indoor blower speed** as determined by the mainboard,
not the requested fan speed. It uses the same numeric encoding as the Grey request
(20/40/60/80/100) but adds additional values for non-standard states.

### Value table

| Blue byte[5] | Meaning                          | Observed in modes | Notes |
|---------------|----------------------------------|-------------------|-------|
| 0             | Fan stopped                      | Heat, Init        | Compressor off or system off |
| 1             | Fan idle / standby               | Cool, Dry, Fan    | Minimal air circulation |
| 20            | Silent speed                     | Cool, Fan, Heat   | Transition / ramp-up |
| 23 (0x17)     | Heat warm-up low speed           | **Heat only**     | Prevents cold-air blow during warm-up |
| 40            | Low speed                        | Cool, Fan, Heat   | Matches Grey fan=40 when running |
| 60            | Medium speed                     | Cool, Fan         | Matches Grey fan=60 when running |
| 80            | High speed                       | Cool, Dry, Fan, Heat | Matches Grey fan=80 when running |
| 100 (0x64)    | Maximum speed                    | Cool, Fan         | Auto-selected full speed |
| 103 (0x67)    | Heat full speed                  | **Heat only**     | Heat-mode maximum blower output |

### Validation results

**Test 1 — Manual fan speed match** (Grey fan ∈ {40, 60, 80}, steady-state):

| Grey fan (requested) | Blue b5 (actual) | Count | Match? |
|----------------------|------------------|-------|--------|
| 80 (High)            | 80               | 79    | Yes    |
| 80 (High)            | 0 (stopped)      | 115   | Expected: Heat warm-up, fan not yet running |
| 80 (High)            | 40 (ramping)     | 8     | Expected: fan ramping up |
| 40 (Low)             | 40               | 2     | Yes    |
| 40 (Low)             | 0 (stopped)      | 11    | Expected: Heat warm-up |
| 60 (Med)             | 60               | 1     | Yes    |
| 60 (Med)             | 0 (stopped)      | 10    | Expected: Heat warm-up |

When the blower is actively running (b5 > 1), it reports the exact requested speed.
When it's not running (b5 = 0), the mainboard is overriding the request — typically in
Heat mode where the indoor fan is delayed until the heat exchanger reaches temperature.

**Test 2 — Power OFF** (Grey byte[9] bit6 = 0): **122/122 = b5=0 (100%)**

**Test 3 — Auto fan mode distribution** (Grey fan = Auto, power ON):

| Blue mode | b5=0 (stopped) | b5=1 (idle) | b5=23 (warm-up) | b5=40–100 (running) | b5=103 (heat-full) |
|-----------|----------------|-------------|------------------|---------------------|---------------------|
| Cool      | —              | 477 (34.5%) | —                | 202 (14.6%)         | —                   |
| Cool      | —              | —           | —                | 703 (50.9%)         | —                   |
| Dry       | —              | 189 (96.9%) | —                | 6 (3.1%)            | —                   |
| Fan       | —              | 167 (78.8%) | —                | 45 (21.2%)          | —                   |
| Heat      | 1737 (65.1%)   | —           | 168 (6.3%)       | 41 (1.5%)           | 722 (27.1%)         |

Key insight: **Heat mode** has a unique fan behavior — the blower is stopped (65%) most of
the time (compressor off or cycling), uses a warm-up speed of 23 (6%), and runs at a
heat-specific full speed of 103 (27%). **Cool/Dry/Fan** modes use 1 (idle) as the stopped
state and standard 20–100 values when running.

### Relationship to Grey byte[5] (requested fan speed)

Grey byte[5] is the **target** fan speed set by the user/controller. Blue byte[5] is the
**actual** speed determined by the mainboard based on:
- Operating mode and compressor state
- Heat exchanger temperature (Heat mode delays fan until warm)
- Auto-speed algorithm (varies based on delta-T between setpoint and room temp)
- Power state (always 0 when off)
