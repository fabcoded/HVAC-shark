# Midea HVAC — Shared Protocol Elements

> **Source Status — Own Hardware Observations and Community Sources**
> This document summarises protocol elements that appear **identically or analogously
> across two or more Midea communication buses**. Every entry has been confirmed on at
> least one bus through own hardware captures (see `HVAC-shark-dumps` repository).
> Bus-specific details are kept in the individual protocol references:
>
> - [protocol_uart.md](protocol_uart.md) — Wi-Fi dongle / SmartKey (UART, 9600 bps)
> - [protocol_rt.md](protocol_rt.md) — R/T extension board (half-duplex, 2400 bps)
> - [protocol_xye.md](protocol_xye.md) — XYE RS-485 central controller bus (4800 bps nibble-pair)
> - [protocol_mainboard.md](protocol_mainboard.md) — Display ↔ mainboard internal link (9600 bps)
> - [protocol_ir.md](protocol_ir.md) — Infrared remote (NEC-like)
> - [protocol_serial.md](protocol_serial.md) — Shared UART/R/T command set (transport-agnostic)

---

## 0. Scope

This document covers **overarching Midea protocol constants and patterns** — elements
that are native to the Midea protocol family and appear on multiple buses. It does
**not** include:

- Bus-specific frame layouts (see individual docs above)
- HVAC_shark project-internal identifiers (see §8 below, clearly marked)
- Hypothetical or unconfirmed field assignments

Cross-bus field comparisons with translation tables are in
[comparison_uart_vs_xye.md](comparison_uart_vs_xye.md).

---

## 1. Universal Frame Pattern

All observed Midea buses follow the same conceptual framing:

```
[START] [HEADER] [PAYLOAD] [INTEGRITY]
```

| Element | UART | R/T | XYE | Mainboard |
|---------|------|-----|-----|-----------|
| Start byte | 0xAA | 0xAA (request) / 0x55 (response) | 0xAA | 0xAA |
| End marker | — | 0xEF (response trailer) | 0x55 (epilogue) | — |
| Length field | byte[1] (total − 1) | byte[2] (data length; total = val + 4) | implicit (fixed 16 or 32) | byte[2] (total frame length) |
| CRC-8 | Yes | Yes | No | Yes |
| Checksum | Yes (additive) | Yes (two's complement) | Yes (two's complement) | Yes (additive) |

The start byte `0xAA` is the single most reliable Midea protocol indicator — every
bus uses it at byte[0] for at least one frame direction. The epilogue `0x55` is only
used by R/T (response start byte, direction indicator) and XYE (fixed frame terminator).

---

## 2. Shared Constants

### 2.1 Start Byte `0xAA` — **[Confirmed]** all buses

Universal across all four serial buses. Always at byte[0].

- **UART**: both request and response start with 0xAA
- **R/T**: requests (adapter → display) use 0xAA; responses (display → adapter) use 0x55
- **XYE**: all frames (master commands and slave responses) start with 0xAA
- **Mainboard**: all frame types (0x20, 0x30, 0x31, 0x50, 0xFF) start with 0xAA

### 2.2 Appliance Type `0xAC` — **[Confirmed]** UART, R/T, Mainboard

Identifies the device as an air conditioner. Present in UART and R/T frame headers;
embedded in mainboard telemetry responses. Not present in XYE frame structure.

| Bus | Location | Status |
|-----|----------|--------|
| UART | byte[2] | Header field (universal per `protocol_uart.md`) |
| R/T | byte[3] | Shifted by one byte due to device-type insertion at byte[1] |
| Mainboard | AA30 response byte[16] | Embedded in telemetry payload |
| XYE | — | Not present |

### 2.3 Device Type `0xBC` — **[Confirmed]** R/T, XYE

Appears on multi-device buses as a device-class identifier. Not present on
point-to-point or single-device buses.

| Bus | Location | Meaning | Status |
|-----|----------|---------|--------|
| R/T | byte[1] | Extension board identifier (constant) | Confirmed |
| XYE | response byte[19] | Fixed outdoor-unit device type marker | Confirmed (always 0xBC on tested HW) |
| UART | — | Not present (point-to-point, no device addressing) | — |
| Mainboard | — | Not present (single device, no addressing) | — |

### 2.4 Epilogue / Direction Marker `0x55`

Not universal — only appears on R/T and XYE buses.

| Bus | Location | Function |
|-----|----------|----------|
| R/T | byte[0] of responses | **Direction indicator**: 0x55 = display → adapter (response) |
| XYE | byte[15] (16-byte) or byte[31] (32-byte) | **Fixed frame epilogue** |
| UART | — | Not used |
| Mainboard | — | Not used |

---

## 3. Integrity Algorithms

### 3.1 CRC-8/MAXIM — **[Confirmed]** UART, R/T, Mainboard

Three of the four serial buses use the same CRC-8 polynomial and lookup table:

| Parameter | Value |
|-----------|-------|
| Algorithm | CRC-8/MAXIM (also: CRC-8/Dallas, DOW CRC) |
| Polynomial | 0x31 (normal), 0x8C (reflected) |
| Init value | 0x00 |
| RefIn / RefOut | true / true |
| XorOut | 0x00 |

The **256-entry lookup table is identical** across all three buses. Only the
**byte range covered** differs:

| Bus | CRC byte range | Notes |
|-----|----------------|-------|
| UART | frame[10..N-3] (body bytes only) | Excludes header and checksum |
| R/T | frame[11..N-5] (body, shifted) | One-byte offset from UART due to device-type insertion |
| Mainboard | frame[0..N-3] (**includes 0xAA start**) | Unique: covers entire frame |

**XYE does not use CRC-8** — it relies solely on a two's complement checksum.

Verification: UART CRC confirmed across community sources; mainboard CRC verified
against **25,832 frames** (100% match, 8 sessions).

### 3.2 Additive Checksum — **[Confirmed]** UART, Mainboard

```
checksum = (256 - sum(frame[1:-1])) & 0xFF
```

- Byte[0] (`0xAA`) is **excluded** from the sum.
- Last byte of the frame.
- **Identical formula** on UART and mainboard.

### 3.3 Two's Complement Checksum — **[Confirmed]** R/T, XYE

Mathematically related to the additive checksum but applied over different byte ranges:

| Bus | Formula | Byte range |
|-----|---------|------------|
| R/T (request) | two's complement of sum | bytes[1..N-4] |
| R/T (response) | two's complement of sum | bytes[2..N-3] |
| XYE | `(255 - (sum % 256) + 1) & 0xFF` | entire frame except CRC byte |

All checksums use **modulo-256 arithmetic**.

---

## 4. Shared Command Code: `0xC0`

The **only command/response code that is numerically identical across UART and XYE**:

| Bus | Role | Location |
|-----|------|----------|
| UART / R/T | Status response identifier | body[0] = 0xC0 |
| XYE | Query command **and** response code | byte[1] = 0xC0 |

This is strong evidence that UART and XYE share a **common Midea-internal protocol
origin** (see [comparison_uart_vs_xye.md](comparison_uart_vs_xye.md) §8).

Other command codes use different numeric values for the same semantic function
(e.g. UART 0x41 = query vs XYE 0xC0 = query; UART 0x40 = set vs XYE 0xC3 = set).

---

## 5. Temperature Encoding Variants

All buses encode temperatures as **offset + scale** into a single byte, but use
**different offsets** depending on bus and context. The scale factor is always
0.5 °C/unit except where noted.

| Bus | Context | Formula | Offset | Scale | Confirmed |
|-----|---------|---------|--------|-------|-----------|
| UART / R/T | C0 response body[11–12] (indoor, outdoor sensors) | (val − 50) / 2 | 50 | 0.5 °C | Session 6 service menu |
| UART / R/T | C1 Group 1 body[10] (T1 indoor coil) | (val − 30) / 2 | 30 | 0.5 °C | Session 6 (raw 0x42 → 18 °C) |
| UART / R/T | C1 Group 1 body[12–13] (T3 outdoor coil, T4 outdoor ambient) | (val − 50) / 2 | 50 | 0.5 °C | Session 6 |
| UART / R/T | C1 Group 1 body[14] (Tp discharge pipe) | direct integer °C | — | 1.0 °C | Session 6 (raw 0x4A = 74 °C) |
| XYE | C0/C3/C4/C6 response byte[11–14] (T1, T2A, T2B, T3) | (val − 40) / 2 | 40 | 0.5 °C | Sessions 4/5/6 |
| XYE | C0 response byte[10] (setpoint) | val − 0x40 | 64 | 1.0 °C | Session 7 (full 16–30 °C sweep) |
| Mainboard | AA20 Grey byte[4] (setpoint) | (val − 30) / 2 | 30 | 0.5 °C | Sessions 4/7/8/9 |

All formulas produce **degrees Celsius**. The same physical temperature yields
different raw byte values on different buses.

---

## 6. Fan Speed Encoding Variants

Two distinct encoding schemes are used:

| Bus | Scheme | Auto | Turbo | High | Medium | Low | Silent |
|-----|--------|------|-------|------|--------|-----|--------|
| UART / R/T / Mainboard | Integer (percentage-like) | 102 | 100 | 80 | 60 | 40 | 20 |
| XYE | One-hot bitmask | 0x80 | — | 0x01 | 0x02 | 0x04 | — |

**Notes:**
- R/T also reports **101** as a system-forced Auto variant in Dry and Auto modes
  (distinct from user-set 102). See `protocol_xye.md` §6.
- XYE uses bit-position encoding: bit7 = Auto, bit2 = Low, bit1 = Medium, bit0 = High.
- The UART/R/T/Mainboard integer scheme is identical — no translation needed between
  those three buses.

---

## 7. Operating Mode Encoding Variants

Three distinct encodings for the same five operating modes:

| Bus | Encoding | Off | Fan | Dry | Heat | Cool | Auto |
|-----|----------|-----|-----|-----|------|------|------|
| UART / R/T | C0 body[2] bits[7:5] | — | 5 | 3 | 4 | 2 | 1 |
| XYE | One-hot + bit7 = power | 0x00 | 0x81 | 0x82 | 0x84 | 0x88 | 0x90 |
| Mainboard | AA20 byte[3] index | — | 2 | 1 | 3 | 0 | 4 |

**XYE Auto sub-modes** (in C0/C3 32-byte responses only, not in D0 or Set commands):
- `0x91` = Auto + Fan (idle / deciding)
- `0x94` = Auto + Heat (actively heating)
- `0x98` = Auto + Cool (actively cooling)

The sub-mode bits use the same one-hot encoding as the base modes
(`0x01` = fan, `0x04` = heat, `0x08` = cool), ORed with `0x90` (Auto base).

**UART / R/T vs Mainboard modes require a lookup table** — no arithmetic
conversion is possible. See `validate_mainboard_hypotheses.py` for the confirmed
mapping (H-01).

---

## 8. HVAC_shark Bus Classification — Project-Specific

> **Not part of the Midea protocol.** These identifiers are assigned by this project
> for multiplexing captures from different physical buses into a single pcap file.
> They are carried in the HVAC_shark v2 header at byte[11] and have no meaning
> outside this project's tools.

| Code | Bus name | Physical interface | Baud rate |
|------|----------|-------------------|-----------|
| 0x00 | XYE | RS-485 HA/HB differential (nibble-pair encoded) | 4800 (logical ~2400 byte/s) |
| 0x01 | UART | 5 V TTL, CN3 connector | 9600 |
| 0x02 | disp-mainboard_1 | Internal grey/blue wires, CN1 connector | 9600 |
| 0x03 | r-t_1 | R/T pin, half-duplex single wire, CN1 | 2400 |
| 0x04 | IR | Infrared remote (NEC-like pulse-width modulation) | — |

**Defined in:**
- Wireshark dissector: `HVAC-shark_mid-xye.lua` (line 1949, `BUS_TYPE_NAMES` table)
- Pcap converter: `logic_analyzer_midea_to_pcap.py` (channels.yaml `busType` field)

**HVAC_shark v2 header layout** (prepended to each UDP-encapsulated frame):

```
Offset  Size  Field
  0     10    Magic: "HVAC_shark" (ASCII)
 10      1    Manufacturer (1 = Midea)
 11      1    Bus type (see table above)
 12      1    Header version (0x00 = legacy, 0x01 = extended)
 13+     var   [v1 only] Length-prefixed strings: channel name, circuit board, comment
```

---

## 9. Protocol Disambiguation

When a frame starts with `0xAA`, the protocol can be identified unambiguously from
**byte[1] alone** — the valid value ranges never overlap:

| Byte[1] range | Protocol | Frame size determination |
|---|---|---|
| `0x0D`–`0x40` (13–64 decimal) | **UART** (byte[1] = length) | Variable: byte[1] + 1 bytes total |
| `0xC0`–`0xCD` (192–205 decimal) | **XYE** (byte[1] = command code) | Fixed: 16 bytes if byte[2] ≠ 0x80; 32 bytes if byte[2] = 0x80 |
| `0x20`, `0x30`, `0x31`, `0x50`, `0xFF` | **Mainboard** (byte[1] = frame type) | Variable: byte[2] = total length |

A UART length of 0xC0 would imply a 193-byte frame — far beyond any known command.
In practice UART frames are 13–39 bytes (`0x0D`–`0x27`). **Single-byte disambiguation,
zero lookahead.**

R/T frames use the same header structure as UART (with a device-type byte inserted
at byte[1] = 0xBC), so R/T vs UART is distinguished by the capture context (bus type
in HVAC_shark header), not by frame content.

---

## References

- [protocol_uart.md](protocol_uart.md) — UART transport and framing
- [protocol_rt.md](protocol_rt.md) — R/T bus framing (HA/HB variant)
- [protocol_xye.md](protocol_xye.md) — XYE RS-485 protocol
- [protocol_mainboard.md](protocol_mainboard.md) — Display ↔ mainboard internal bus
- [protocol_serial.md](protocol_serial.md) — Shared UART/R/T command set
- [comparison_uart_vs_xye.md](comparison_uart_vs_xye.md) — Cross-protocol field mapping
- [device_xtremesaveblue.md](device_xtremesaveblue.md) — Device-specific observations
