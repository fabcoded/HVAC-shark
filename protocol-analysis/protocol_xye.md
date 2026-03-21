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
  1     COMMAND           0xC0=Query, 0xC3=Set, 0xC4=Ext.Query, 0xC6=Ext.Set, 0xCC=Lock, 0xCD=Unlock
  2     DEST_ID           Target unit 0x00-0x3F; 0xFF=broadcast
  3     SRC_ID            Master address
  4     DIR_FLAG          0x00 = master->slave
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
 11     T1_INDOOR         (raw - 0x30) x 0.5 deg C
 12     T2A_COIL_IN       (raw - 0x30) x 0.5 deg C
 13     T2B_COIL_OUT      (raw - 0x30) x 0.5 deg C
 14     T3_OUTDOOR_COIL   (raw - 0x30) x 0.5 deg C
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
 27-28  (reserved)        0x00
 29     STARTUP_1         Boot readiness counter
 30     STARTUP_2         Boot readiness counter
 31     CRC               Two's complement checksum
```

---

## 3. Checksum Algorithm

XYE uses a single two's complement sum covering the entire frame, including the `0xAA` preamble and `0x55` epilogue (all bytes except the CRC byte itself):

```
CRC = (255 - (sum_of_all_bytes_except_CRC % 256) + 1) & 0xFF
```

---

## 4. Command Codes

| Code   | Direction      | Name           | Description                                      |
|--------|----------------|----------------|--------------------------------------------------|
| `0xC0` | Master->Slave  | Query          | Request current status from unit                 |
| `0xC0` | Slave->Master  | Status response| Current state (32-byte response frame)           |
| `0xC3` | Master->Slave  | Set parameters | Write operating parameters to unit               |
| `0xC4` | Master->Slave  | Extended query | Query extended data (e.g. outdoor temp T4)       |
| `0xC6` | Master->Slave  | Follow-Me set  | Send remote room temperature sensor reading      |
| `0xCC` | Master->Slave  | Lock           | Lock unit (disable local remote control)         |
| `0xCD` | Master->Slave  | Unlock         | Unlock unit                                      |

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
| `0x80` | Auto   |
| `0x01` | High   |
| `0x02` | Medium |
| `0x03` | Low    |

---

## 7. Temperature Encoding

### Target temperature
Byte 0x0A: direct integer value in degrees C.

### Measured temperatures (sensor bytes 0x0B-0x0E)
All sensor bytes use the same formula:

```
temp_c = (raw_byte - 0x30) * 0.5
```

Offset `0x30 = 48`. Range: -24 deg C (raw=0x00) to +103.5 deg C (raw=0xFF).

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

## References

- XYE reverse engineering: https://codeberg.org/xye/xye
- ESPHome XYE implementation: https://github.com/wtahler/esphome-mideaXYE-rs485
- HA Community XYE thread: https://community.home-assistant.io/t/midea-a-c-via-local-xye/857679
- Midea UART reference: [protocol_uart.md](protocol_uart.md)
- UART vs. XYE comparison: [comparison_uart_vs_xye.md](comparison_uart_vs_xye.md)
