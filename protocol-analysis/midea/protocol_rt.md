# Midea R/T Bus Protocol Reference

> **Source Status — Own Hardware Observations Only**
> Based entirely on own hardware captures from the `HVAC-shark-dumps` repository
> (Midea extremeSaveBlue display board, Session 1). No community reference for
> this specific bus was found. No official Midea specification is publicly available.
> Confidence levels are stated explicitly per field.

For the relationship to Midea UART, see [protocol_uart.md](protocol_uart.md).

---

## 1. Physical Layer

| Property       | Value                                                          | Confidence  |
|----------------|----------------------------------------------------------------|-------------|
| Topology       | Single-wire, bidirectional, half-duplex                        | Confirmed   |
| Connector      | CN1 on display board                                           | Confirmed   |
| Wire           | Dedicated R/T pin (separate from CN1 grey/blue UART wires)    | Confirmed   |
| Bridge         | Display-side single-ended wire -> converter PCB -> HA/HB differential bus toward mainboard | Observed |
| Baud rate      | Unknown — consistent with 9600 bps but not directly measured  | Unknown     |
| Data format    | 8N1 (assumed, same as UART)                                    | Hypothesis  |
| Voltage        | Not measured                                                   | Unknown     |

The label "R/T" (Receive/Transmit) indicates the pin is shared for both directions.
Direction is distinguished at the protocol level by the start byte (`0xAA` vs `0x55`),
not by voltage or timing.

CN1 also carries two separate unidirectional UART wires to the mainboard (grey = rxd,
blue = txd), which are a distinct parallel path and use the standard Midea UART
framing directly — not the HA/HB framing documented here.

---

## 2. Frame Structure

The R/T bus uses **HA/HB framing** — a one-byte-shifted variant of the Midea UART
frame with an added device type byte. The body payload is byte-for-byte compatible
with Midea UART commands.

### 2.1 Request frame: display -> extension board (start byte `0xAA`)

```
Offset  Field             Value / Description
------  -----             -------------------
  0     START             0xAA  (display -> ext. board)
  1     DEVICE_TYPE       0xBC  (extension board, constant)
  2     LENGTH            Data length; total frame = byte[2] + 4
  3     APPLIANCE_TYPE    0xAC  (air conditioner)
  4-8   Reserved          0x00 0x00 0x00 0x00 0x00  (5 bytes)
  9     PROTOCOL_VER      0x03
 10     MSG_TYPE          0x03 (data) or 0x02 (ack)
 11..N-5  BODY            UART-compatible command payload (see protocol_uart.md)
  N-4   CRC8              CRC-8/854 over body bytes [11..N-5]
  N-3   CHECKSUM          Two's complement of sum of bytes [1..N-4]
  N-2   Padding           0x00
  N-1   FRAME_CHECK       Two's complement making full packet sum = 0x00 mod 256
```

Observed length: 38 bytes (`byte[2]=0x22`), except one 5-byte startup probe.

### 2.2 Response frame: extension board -> display (start byte `0x55`)

```
Offset  Field             Value / Description
------  -----             -------------------
  0     START             0x55  (ext. board -> display)
  1     DEVICE_TYPE       0xBC
  2     LENGTH            Data length; total frame = byte[2] + 4
  3     APPLIANCE_TYPE    0xAC
  4-8   Reserved          0x00 0x00 0x00 0x00 0x00
  9     PROTOCOL_VER      0x03
 10     MSG_TYPE          0x03 (data) or 0x02 (ack)
 11..N-5  BODY            UART-compatible response payload
  N-3   CHECKSUM          Two's complement of sum of bytes [2..N-3]
  N-2   Padding           0x00
  N-1   END_MARKER        0xEF  (fixed)
```

Observed lengths: 38 bytes (`byte[2]=0x22`) or 44 bytes (`byte[2]=0x28`).

---

## 3. Length Formula

```
total_bytes = byte[2] + 4
```

Confirmed for 178 of 179 captured packets (99.4%). One 5-byte startup probe
(`AA BC 22 AC 00`) does not carry a payload and is likely a bus reset or probe.

---

## 4. Checksum / Integrity

Three layers on request frames, two on responses. In both directions, the sum of
all bytes in the complete packet equals `0x00` mod 256.

### Request (0xAA direction)

| Field    | Coverage          | Algorithm                     | Confirmed     |
|----------|-------------------|-------------------------------|---------------|
| CRC8     | body [11..N-5]    | CRC-8/854 (lookup table)      | 90/90 packets |
| CHECKSUM | bytes [1..N-4]    | Two's complement of byte sum  | 90/90 packets |
| FRAME_CHECK | entire frame   | Makes full sum = 0x00 mod 256 | Derived       |

### Response (0x55 direction)

| Field       | Coverage        | Algorithm                     | Confirmed     |
|-------------|-----------------|-------------------------------|---------------|
| CHECKSUM    | bytes [2..N-3]  | Two's complement of byte sum  | 88/88 packets |
| END_MARKER  | byte N-1        | Fixed value 0xEF              | Confirmed     |

Note: checksum coverage differs between directions (requests start at byte[1],
responses at byte[2]). Both still produce full-packet sum = 0.

---

## 5. Relationship to Midea UART

The R/T bus is not a separate protocol — it is Midea UART body commands wrapped in
HA/HB framing. The header differs by one byte offset:

| Field             | UART offset | R/T bus offset | Difference                          |
|-------------------|-------------|----------------|-------------------------------------|
| Start byte        | 0           | 0              | UART: always 0xAA; R/T: 0xAA or 0x55 |
| LENGTH            | 1           | 2              | Shifted by 1 (DEVICE_TYPE inserted) |
| APPLIANCE_TYPE    | 2           | 3              | Shifted                             |
| Reserved          | 4-7 (4 B)   | 4-8 (5 B)      | One extra reserved byte             |
| PROTOCOL_VER      | 8           | 9              | Shifted                             |
| MSG_TYPE          | 9           | 10             | Shifted                             |
| Body start        | 10          | 11             | Shifted                             |

The UART body decoders (`0xC0` status, `0xC1` power, `0x41` query, `0x93` status)
apply directly to R/T frames — adjust body offset from byte[10] to byte[11].

---

## 6. Observed Polling Cycle

The display polls the extension board in a strict 5-step repeating cycle,
~0.198 s between request/response pairs, full cycle every ~5.5 s:

| Step | Request body cmd | Request params | Response body cmd | Resp frame size | Description          |
|------|------------------|----------------|-------------------|-----------------|----------------------|
| 1    | `0x93`           | `00 80 84`     | `0x93`            | 44 bytes        | Status query         |
| 2    | `0x41`           | `81 01 41`     | `0xC1`            | 38 bytes        | Capability page 0x41 |
| 3    | `0x41`           | `81 01 42`     | `0xC1`            | 38 bytes        | Capability page 0x42 |
| 4    | `0x41`           | `81 01 43`     | `0xC1`            | 38 bytes        | Capability page 0x43 |
| 5    | `0x41`           | `81 00 FF`     | `0xC0`            | 44 bytes        | Full status response |

---

## 7. Open Questions

- **Baud rate**: not directly measured. Consistent with 9600 bps by timing, but
  unconfirmed. Requires a direct baud-rate measurement on the wire.
- **HA/HB differential layer**: the converter PCB between CN1 and the mainboard
  was not captured. The physical characteristics of the HA/HB side (voltage swing,
  termination, bus arbitration) are unknown.
- **DEVICE_TYPE 0xBC**: meaning of this value beyond "extension board" is unknown.
  Whether other device types exist on the same bus is unknown.
- **MSG_TYPE 0x02**: observed as "ack" but the exact conditions that trigger an
  ack response vs. a data response are not fully understood.

---

## References

- Own hardware captures: HVAC-shark-dumps repository (Midea extremeSaveBlue, Session 1)
- Session findings: [findings.md](../../../HVAC-shark-dumps/Midea-extremeSaveBlue-display/Session%201/findings.md)
- Midea UART reference (body command set): [protocol_uart.md](protocol_uart.md)
