# Midea IR Protocol Reference

> **Source Status — Own Hardware Observations + Community Cross-Reference (Partial)**
>
> Primary source: own hardware captures from the `HVAC-shark-dumps` repository
> (Midea extremeSaveBlue display board, Session 2 logic-analyser captures).
> Cross-referenced against `IRremoteESP8266` (crankyoldgit) and `ESPHome` midea component.
>
> **This is a best-effort analysis.** Field encodings are inferred from a limited
> capture set (one session, one mode, one fan speed). Discrepancies between sources
> are explicitly noted. A field is only considered confirmed when independently
> verified on hardware with known input values. Everything else is a hypothesis.
>
> Confidence levels: **Confirmed** = multiple data points + source agreement.
> **Consistent** = own data + at least one source agree. **Hypothesis** = own data
> only, no source conflict. **Disputed** = sources disagree or finding contradicts
> own data. **Unknown** = insufficient data.

---

## 1. Protocol Variant — Two Midea IR Formats

Research across sources reveals **two distinct Midea IR protocol variants** that
share the same physical timing layer but differ in frame structure:

| Property            | extremeSaveBlue (this capture)          | IRremoteESP8266 "MIDEA"                 |
|---------------------|------------------------------------------|-----------------------------------------|
| Frame size          | 48 bits = 6 bytes                        | 48 bits = 6 bytes                       |
| Complement method   | **Per-byte**: each byte immediately followed by ~byte | **Whole-frame**: 6 bytes sent, then entire frame repeated inverted |
| Physical timings    | Identical (see section 2)                | Identical                               |
| Header pattern      | byte[0] = 0xB2 / 0xB9 / 0xD5 (NEC device address) | byte[5] = 0xA1/0xA2 (Header:5 + Type:3 field) |
| Carrier frequency   | 38 kHz                                   | 38 kHz                                  |
| Sources             | Own hardware (Session 2)                 | crankyoldgit/IRremoteESP8266, ESPHome   |

**These are different formats.** IRremoteESP8266's byte-level field assignments do not
map directly onto our captured frames. The two variants appear to originate from
different remote control generations or OEM variants within the Midea product family.

Supported models in IRremoteESP8266: Pioneer, Comfee, Kaysun, Keystone, MrCool,
Danby, Trotec, Lennox — none of which are the extremeSaveBlue. Model-specific
differences in protocol format are plausible.

---

## 2. Physical Layer

| Property          | Value                                                      | Confidence  |
|-------------------|------------------------------------------------------------|-------------|
| Modulation        | 38 kHz carrier (standard IR), not captured — TSOP receiver used | Confirmed |
| Receiver output   | Active-low (signal inverted by TSOP demodulator)           | Confirmed   |
| Encoding          | NEC-like pulse-width modulation                            | Confirmed   |

### Pulse timings

Measured from Session 2 captures and cross-verified against IRremoteESP8266
`kMideaTick = 80 us` (crankyoldgit/IRremoteESP8266, `ir_Midea.cpp` line 22):

| Symbol    | Formula (IRremoteESP8266)     | Calculated | Measured (Session 2) | Match  |
|-----------|-------------------------------|------------|----------------------|--------|
| Bit mark  | 7 ticks × 80 us               | 560 us     | ~0.56 ms             | ✓      |
| 1-space   | 21 ticks × 80 us              | 1680 us    | ~1.6 ms              | ✓      |
| 0-space   | 7 ticks × 80 us               | 560 us     | ~0.56 ms             | ✓      |
| Header mark | 56 ticks × 80 us            | 4480 us    | ~4.4 ms              | ✓      |
| Header space | 56 ticks × 80 us           | 4480 us    | ~4.4 ms              | ✓      |

The physical timing layer is **confirmed identical** across both protocol variants.
The difference is entirely in the data/frame structure layer.

---

## 3. Frame Structure (extremeSaveBlue NEC variant)

Each frame is **48 bits = 6 bytes**, transmitted MSB-first within each byte.

### Complement integrity check

Bytes are transmitted as NEC-style complement pairs:

| Pair | Bytes            | Relation                  |
|------|------------------|---------------------------|
| 1    | byte[0], byte[1] | byte[0] ^ byte[1] = 0xFF  |
| 2    | byte[2], byte[3] | byte[2] ^ byte[3] = 0xFF  |
| 3    | byte[4], byte[5] | byte[4] ^ byte[5] = 0xFF  |

Exception: the `0xD5` follow-up frame has a non-standard complement pair (see
section 5.3). This is likely intentional to distinguish it from AC control frames.

> **Disputed vs IRremoteESP8266**: In the IRremoteESP8266 MIDEA format, the
> complement is applied to the entire 6-byte frame (whole-frame inversion and repeat),
> not per-byte. The per-byte complement in our captures is a characteristic of the
> NEC variant used by the extremeSaveBlue remote, not of Midea IR in general.

### Button press repetition

A single button press transmits **2–3 frames** separated by ~92 ms gaps:

| Frame type          | Repetition pattern                                     |
|---------------------|--------------------------------------------------------|
| B2 AC control       | 2 identical frames + 1 `0xD5` follow-up frame         |
| B9 setup/installer  | 2 identical frames (no follow-up)                      |

---

## 4. Device IDs (byte[0])

| byte[0] | Complement byte[1] | Frame type          | Confidence |
|---------|--------------------|---------------------|------------|
| `0xB2`  | `0x4D`             | AC control command  | Confirmed  |
| `0xB9`  | `0x46`             | Setup / installer / programming | Confirmed (observed) |
| `0xD5`  | `0x66` (non-standard) | Follow-up / termination | Confirmed (observed) |

These device IDs are specific to the extremeSaveBlue NEC variant. The IRremoteESP8266
MIDEA format does not use device-ID-based addressing — it uses a Header+Type field
in a different byte position. The mapping between the two is unknown.

---

## 5. Frame Types

### 5.1 `0xB2` — AC Control Command

```
Byte  Content           Known encoding
----  -------           --------------
  0   Device ID         0xB2  (fixed)
  1   Complement        0x4D  (= ~0xB2 & 0xFF)
  2   Mode/power/fan    0xBF observed in all Session 2 frames (Heat + Auto fan + Power ON)
                        bit[7]    = Power (1=ON): hypothesis, consistent with IRremoteESP8266
                        bits[6:4] = Mode (3 bits): 011=Heat, consistent with IRremoteESP8266 Heat=3
                        bits[3:0] = Fan + flags: 1111 when Auto; layout UNKNOWN
  3   Complement        ~byte[2] & 0xFF
  4   Temp/swing byte   bits[7:5] = temperature encoding (confirmed, 3 data points)
                        bit[4]    = unknown toggle (see open questions)
                        bits[3:0] = always 0xC in all captures (fixed marker)
  5   Complement        ~byte[4] & 0xFF
```

#### Temperature encoding (byte[4] bits[7:5])

```
temp_c = bits[7:5] + 20
```

Confirmed data points from Session 2:

| byte[4] | bits[7:5] | Decoded  | Operator action          |
|---------|-----------|----------|--------------------------|
| `0x5C`  | 2         | 22 deg C | Initial state            |
| `0x4C`  | 2         | 22 deg C | Confirmed                |
| `0xCC`  | 6         | 26 deg C | Stepped up twice         |
| `0xDC`  | 6         | 26 deg C | Confirmed                |
| `0x9C`  | 4         | 24 deg C | Stepped down             |

> **Potential discrepancy vs IRremoteESP8266**: IRremoteESP8266 documents a temperature
> range of 17–30 deg C (with 5-bit field, `Temp:5`, offset 17). Our 3-bit field
> (bits[7:5]+20) covers only 20–27 deg C. The formula is only confirmed for 22–26 deg C.
> Whether the extremeSaveBlue remote supports 17–20 deg C and uses a different encoding
> for those values, or whether the model has a higher minimum setpoint, is **unknown**.
> **[NEEDS CAPTURE: set 17 deg C and 30 deg C on extremeSaveBlue remote]**

#### byte[2] mode / fan encoding

Only `0xBF` (Heat + Auto fan + Power ON) was observed. Hypothesised layout:

| Bits     | Hypothesis                                    | Basis                                            | Confidence  |
|----------|-----------------------------------------------|--------------------------------------------------|-------------|
| bit[7]   | Power (1=ON)                                  | Consistent with IRremoteESP8266 byte-4 bit[7]    | Hypothesis  |
| bits[6:4]| Mode: 011=Heat (3-bit, same encoding as IRremoteESP8266) | IRremoteESP8266 kMideaACHeat=3=0b011 | Hypothesis  |
| bits[3:2]| Fan speed: 11 when Auto — encoding unknown    | Our bits=11 conflicts with IRremoteESP8266 Auto=0b00 | Disputed |
| bits[1:0]| Unknown                                       | No data                                          | Unknown     |

> **Source conflict on fan speed**: IRremoteESP8266 encodes Auto fan as `0b00`, Low=`0b01`,
> Med=`0b10`, High=`0b11`. In our capture, bits[3:2]=0b11 when Auto fan is active.
> Either the extremeSaveBlue variant uses different fan encoding, or the bit positions
> in byte[2] differ from IRremoteESP8266's byte 4.

#### byte[4] bit[4] — meaning unknown

Bit 4 of byte[4] toggles between frames without an explicit user action. At session
start it was already set without any swing press being observed.

> **Swing hypothesis weakened by IRremoteESP8266**: In IRremoteESP8266, vertical swing
> is implemented as a **separate Special-type frame** (`0xA201FFFFFF7C`), not as a state
> bit in regular command frames. If this convention carries over to the NEC variant,
> bit[4] is unlikely to be the vertical swing state bit. Alternative interpretations:
> a model-specific feature flag, horizontal swing state, display brightness, or a
> retained state from a previous action not in this session.
>
> **[OPEN — requires dedicated capture: toggle swing ON/OFF with no other changes]**

---

### 5.2 `0xB9` — Setup / Installer / Programming Command

```
Byte  Content           Known encoding
----  -------           --------------
  0   Device ID         0xB9  (fixed)
  1   Complement        0x46  (= ~0xB9 & 0xFF)
  2   Function ID       0xF7 = installer/setter mode (only value observed)
  3   Complement        0x08  (= ~0xF7 & 0xFF)
  4   Parameter         0x00-0x08 = sequential installer mode parameter index
                        0xFF      = settermode query command
  5   Complement        ~byte[4] & 0xFF
```

Not present in IRremoteESP8266's MIDEA protocol. Specific to this remote variant.

---

### 5.3 `0xD5` — Follow-up / Termination Frame

```
Byte  Content           Known encoding
----  -------           --------------
  0   Device ID         0xD5  (fixed)
  1   Non-standard pair 0x66  (0xD5^0x66 = 0xB3, NOT 0xFF)
  2-5 Payload           0x00 0x00 0x00 0x3B (fixed in all observations)
```

Always transmitted immediately after each B2 AC control frame pair. Not observed
after B9 frames. Not present in IRremoteESP8266's MIDEA protocol.

The non-standard complement is likely intentional to distinguish this frame from
normal AC control frames.

---

## 6. Known Field Summary (confidence table)

| Field              | Byte  | Bits  | Encoding                                     | Confidence  | Source conflict?                              |
|--------------------|-------|-------|----------------------------------------------|-------------|-----------------------------------------------|
| Device type        | 0     | [7:0] | 0xB2=AC, 0xB9=Setup, 0xD5=Follow-up         | Confirmed   | Not in IRremoteESP8266 (different variant)    |
| Complement pairs   | 1,3,5 | [7:0] | ~byte[n-1] & 0xFF (except 0xD5 pair)        | Confirmed   | IRremoteESP8266 uses whole-frame inversion    |
| Temperature        | 4     | [7:5] | bits + 20 = deg C (22-26 deg C confirmed)    | Consistent  | IRremoteESP8266: offset 17, 5-bit field — range discrepancy |
| Fixed marker       | 4     | [3:0] | Always 0xC                                  | Observed    | —                                             |
| bit4 / feature flag| 4     | [4]   | Toggles; meaning unknown                     | Unknown     | IRremoteESP8266 swing is a separate frame     |
| Power              | 2     | [7]   | 1=ON                                         | Hypothesis  | Consistent with IRremoteESP8266               |
| Mode               | 2     | [6:4] | 011=Heat (IRremoteESP8266 coding hypothesised)| Hypothesis | Only Heat observed                            |
| Fan speed          | 2     | [3:2] | 11 when Auto; encoding unknown               | Disputed    | IRremoteESP8266 Auto=00, conflict             |
| B9 function ID     | 2     | [7:0] | 0xF7 = installer/setter mode                 | Observed    | Not in IRremoteESP8266                        |
| B9 parameter       | 4     | [7:0] | Index 0x00-0x08; 0xFF = settermode query    | Observed    | Not in IRremoteESP8266                        |
| Follow-up payload  | 2-5   | all   | 0x00 0x00 0x00 0x3B (fixed)                 | Observed    | Not in IRremoteESP8266                        |

---

## 7. Open Questions

### 7.1 byte[4] bit[4] — feature flag, not swing?

Bit 4 was already set at session start without a swing press. IRremoteESP8266 uses
a Special-type frame for swing toggle (not a state bit), weakening the swing hypothesis.

**To resolve**: capture a session toggling vertical swing ON and OFF with no other changes.

### 7.2 byte[2] bit layout — mode, fan speed, power

Only `0xBF` (Heat + Auto fan) observed. Fan speed encoding conflicts with
IRremoteESP8266 (our Auto=11 vs IRremoteESP8266 Auto=00).

**To resolve**: capture with Cool, Dry, Fan-only modes and with Auto/High/Medium/Low fan.

### 7.3 Temperature range below 22 deg C and above 26 deg C

Confirmed for 22, 24, 26 deg C. IRremoteESP8266 documents 17–30 deg C but uses
a different format. Whether our formula extends to 17 deg C is unknown.

**To resolve**: set 17 deg C (Midea minimum) and 30 deg C (maximum).

### 7.4 Protocol variant origin

The extremeSaveBlue remote uses NEC per-byte complement, while IRremoteESP8266
MIDEA uses whole-frame inversion. Whether these are two distinct Midea IR standards
(e.g. "Midea1" vs "Midea2"), a regional variant, or a generation difference is
**unknown**. No public documentation found.

### 7.5 B9 installer mode parameter semantics

Parameters 0x00–0x08 stepped through sequentially. What each controls is unknown.

---

## References

- Own hardware captures: HVAC-shark-dumps repository (Midea extremeSaveBlue, Session 2)
- Session notes: [SessionNotes.md](../../../../HVAC-shark-dumps/Midea-extremeSaveBlue-display/Session%202/SessionNotes.md)
- Session findings: [findings.md](../../../../HVAC-shark-dumps/Midea-extremeSaveBlue-display/Session%202/findings.md)
- crankyoldgit/IRremoteESP8266 — `src/ir_Midea.h`, `src/ir_Midea.cpp`
- ESPHome midea component — `esphome/components/midea/ir_transmitter.h`
- IRremoteESP8266 protocol spreadsheet: https://docs.google.com/spreadsheets/d/1TZh4jWrx4h9zzpYUI9aYXMl1fYOiqu-xVuOOMqagxrs/
