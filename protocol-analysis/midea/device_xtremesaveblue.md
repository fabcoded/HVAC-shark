# Midea XtremeSaveBlue — Device-Specific Observations

> These observations are specific to the **Midea XtremeSaveBlue Q11 platform**
> (indoor model MSAGBU-09HRFN8-QRD0GW). Other Midea models or PCB revisions
> may behave differently.

For the generic serial protocol, see [protocol_serial.md](protocol_serial.md).
For capture sessions, see the `HVAC-shark-dumps` repository.

---

## 1. Bus Data Rates (Confirmed)

| Bus | Connector | Baud | Encoding | ms/byte | 38-byte frame TX |
|-----|-----------|------|----------|---------|-----------------|
| Display↔Mainboard | CN1 grey/blue | 9600 | 8N1 | 1.04 ms | ~40 ms |
| UART wifi dongle | CN3 brown/orange | 9600 | 8N1 | 1.04 ms | ~40 ms |
| R/T pin | CN1 R/T | **2400** | 8N1 | 4.17 ms | **~158 ms** |
| HA/HB RS-485 | Adapter board | **48000** | 8N1 nibble-pair | 0.21 ms | ~8 ms (physical) |

R/T at 2400 baud is 4× slower than UART — a 38-byte R/T frame takes ~158 ms to
transmit. HA/HB uses nibble-pair encoding (2 physical bytes per logical byte,
XOR 0xFF), so the effective logical data rate is ~2400 bytes/s.

---

## 2. Command Relay Timing (Session 8)

A Set Status command from the wall controller traverses:
**bus adapter → R/T (2400 baud) → display → internal bus (9600 baud) → mainboard**

Observed timing (t relative to R/T 0x40 frame start):

```
t+0.000s  R/T    toACdisplay     0x40 Set (Mode=Auto, from wall controller)
t+0.004s  DISP   toACmainboard   D_set (Mode=Auto, 30°C, forwarded to mainboard)
t+0.197s  R/T    fromACdisplay   C0 Status (response with current state)
```

The 4 ms between R/T frame start and D_set forwarding is shorter than one R/T
frame TX time (~158 ms at 2400 baud). This means the display starts forwarding
to the mainboard **before the R/T frame has finished transmitting** — the display
processes the R/T frame incrementally, not after full receipt.

Note: timestamps mark the first byte on the wire. When correlating across buses,
always account for frame TX time at the respective baud rate.

---

## 3. Mode Mismatch: Auto → Heat Sub-Mode (Session 8)

Cross-bus direction analysis revealed a consistent mode discrepancy:

| Bus | Direction | Frame | Mode field |
|-----|-----------|-------|------------|
| Display→Mainboard | toACmainboard | D_set (0x20 Grey) | **Auto, 30°C** |
| Mainboard→Display | fromACmainboard | D_sts (0x20 Blue) | **Heat** |
| R/T fromACdisplay | fromACdisplay | C0 Status | **Auto, 30°C** |

The display continuously sends the **user-requested** mode (Auto) to the mainboard.
The mainboard responds with the **actual operating sub-mode** (Heat) — selected
automatically based on current temperature conditions.

The R/T and UART status frames report the user-requested mode, not the actual
sub-mode. To determine the real operating mode, read the display-mainboard internal
bus (D_sts) or C1 Group 1 "indoor operating mode" field.

---

## 4. Polling Rates

| Bus | Rate | Cycle time |
|-----|------|------------|
| Display↔Mainboard | ~4 Hz | ~250 ms |
| R/T (bus adapter) | ~0.18 Hz | ~5.5 s |
| UART (wifi dongle) | Sporadic | Seconds between heartbeats |

The display↔mainboard bus at ~4 Hz is the primary data exchange. The display
caches mainboard state and redistributes it to the slower R/T and UART buses
on their respective schedules.
