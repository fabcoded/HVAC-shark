# Follow Me on the Serial (R/T) Bus — Cross-Bus Analysis

> **Source Status — Own Hardware Observations**
> Based on logic analyzer captures from the `HVAC-shark-dumps` repository
> (Midea-XtremeSaveBlue-logicanalyzer Sessions 3–9). All findings verified
> with tshark + HVAC-shark Lua dissector against CRC-valid frames only.

## 1. Summary

Follow Me on the R/T serial bus uses **two separate frames** from the busadapter
(R/T master) to the AC display board (R/T slave):

1. **R/T 0x40 Set** (busadapter → display): carries the Follow Me **enable flag**
   in `body[8] bit 7` (bodySense). Event-driven — only sent on operator actions.
2. **R/T 0x41 Query** (busadapter → display): carries the Follow Me
   **temperature** in `body[4]=0x01, body[5]=T*2+50`. Sent continuously (~every
   5.5s) while Follow Me is active.

The display board reflects both back to the busadapter in R/T 0xC0 responses
(display → busadapter, ~every 5.5s): `body[8] bit 7` = Follow Me active flag,
`body[11]` = T1 indoor temperature (Follow Me sensor when active, unit's own
thermistor when disabled).

**R/T bus variant**: The R/T 0x41 uses the **standard query format**
(`body[1]=0x81`, 38-byte frame) with `body[4]` repurposed to carry the
optCommand — not the extended query format (`body[1]=0x21`, 24-byte frame)
documented in mill1000/midea-msmart Finding 10c. The extended format was never
observed on the R/T bus. See §5 for details.

---

## 2. R/T Bus Topology and Direction

The R/T bus on CN1 connects the **busadapter** (master) to the **AC display
board** (slave). This was determined from the channels.yaml configuration
(`connectedComponents: ACdisplay-busadapter_HAHB`) and confirmed by frame role
analysis:

```
  busadapter                                 AC display board
  (R/T master, start=0xAA)                   (R/T slave, start=0x55)
        |                                          |
        |──── 0x41 Query (576x) ──────────────────>|
        |──── 0x40 Set Status (61x) ──────────────>|
        |──── 0x93 Ext Status request (184x) ─────>|
        |                                          |
        |<──── 0xC0 Status Response (245x) ────────|
        |<──── 0xC1 Group Page Response (344x) ────|
        |<──── 0x93 Ext Status response (184x) ────|
```

**For Follow Me**, the relevant frame pair is:
- **busadapter → display** (0xAA): `0x40 Set Status` — carries `body[8] bit 7` (FM enable flag) and the user setpoint
- **display → busadapter** (0x55): `0xC0 Status Response` — carries `body[8] bit 7` (FM readback) and `body[11]` (indoor temperature T1 = FM sensor when active)

---

## 3. R/T Bus Polling Cycle and Frame Sequence

The R/T bus operates a fixed polling cycle. Understanding this cycle is
essential because the 0x40 Set (which carries the FM flag) is **not
continuously repeated** — it only appears as an event-driven interruption.

### 3.1 Idle polling cycle (no operator actions)

The base cycle repeats every **~5.5s** and contains no 0x40 Set commands:

```
Slot 1:  busadapter → display  0x41 (Query)  →  display → busadapter  0xC1 (Group response)  +0.9s
Slot 2:  busadapter → display  0x41 (Query)  →  display → busadapter  0xC1 (Group response)  +0.9s
Slot 3:  busadapter → display  0x41 (Query)  →  display → busadapter  0xC1 (Group response)  +0.9s
Slot 4:  busadapter → display  0x41 (Query)  →  display → busadapter  0xC0 (Status) ←── FM flag + T1
Slot 5:  busadapter → display  0x93 (ExtSts) →  display → busadapter  0x93 (ExtSts)          +0.9s
───── cycle repeats (~5.5s total) ─────
```

Each request→response pair takes ~0.2s. Spacing between pairs is ~0.9s.
The 0xC0 Status Response (display → busadapter) appears **once per cycle** (~every
5.5s) and always carries:
- `body[8] bit 7` = Follow Me active flag (mirrors current FM state)
- `body[11]` = Indoor temperature T1 (FM sensor when FM=ON, own thermistor when FM=OFF)

**This cycle is identical regardless of FM state.** The only difference is the
_values_ in the 0xC0 response, not the frame sequence.

### 3.2 Event-driven R/T 0x40 Set injection (FM enable/disable)

When the operator presses a button on the KJR-120M (mode, setpoint, fan,
Follow Me toggle), the busadapter **inserts** a R/T 0x40 Set command into the
cycle. The injection creates an additional slot pair:

```
... busadapter → display 0x41 → display → busadapter 0xC1 ...
    busadapter → display 0x40 (Set) → display → busadapter 0xC0 (Status) ←── event-driven injection
    busadapter → display 0x93 → display → busadapter 0x93 ...
... busadapter → display 0x41 → display → busadapter 0xC0 ...  (regular cycle continues)
```

The R/T 0x40 Set (busadapter → display) carries all current settings (mode,
setpoint, fan, swing) plus the FM flag in `body[8]`. Each operator action
triggers one R/T 0x40 injection. **Between actions, no R/T 0x40 frames are
sent** — the FM enable flag (`body[8]=0x80`) is **not continuously reinforced**.

Session 7 timing confirms:
- **FM-ON, operator active** (t=29-44s): R/T 0x40 every ~2.5s (one per setpoint step)
- **FM-ON, operator idle** (t=45-174s): **zero** R/T 0x40 frames in 129 seconds
- **FM-OFF, operator idle** (t=475-755s): **zero** R/T 0x40 frames in 280 seconds
- **FM-OFF, operator active** (t=755-762s): R/T 0x40 appears with each button press

### 3.3 Continuous R/T 0xC0 temperature reporting

After FM is enabled via R/T 0x40, the **room controller's sensor temperature**
is continuously reported in the R/T 0xC0 Status Response (display → busadapter)
in slot 4 of the idle cycle (~every 5.5s). This happens via the R/T 0xC0
`body[11]` field regardless of whether a R/T 0x40 Set was recently sent.

The full temperature path through the system:

```
room controller  →[XYE C6]→  busadapter  →[R/T]→  display  →[internal]→  mainboard
(FM temp sensor)              (relays)             (reports T1)           (own thermistor)
```

1. **XYE:** KJR-120M room controller sends its sensor temperature to the
   busadapter via XYE C6 byte[11] (direct Celsius, every XYE C3+C6 pair
   and periodic XYE C6 UPDATE every ~3-5 minutes)
2. **R/T:** Busadapter sends the temperature to the display board via R/T 0x41
   query (busadapter → display) with `body[4]=0x01` and `body[5]=T*2+50`.
   This is a **standard query** (`body[1]=0x81`, 38-byte frame) with the
   optCommand piggybacked in body[4] — not the extended query format
   (`body[1]=0x21`, 24-byte frame) documented in protocol_serial.md §3.1.4
   and mill1000 Finding 10c. The extended format never appears on the R/T bus.
3. **R/T:** The display board reflects the temperature in every R/T 0xC0
   response (display → busadapter, `body[11]` = `T*2+50`, ~every 5.5s
   continuously)
4. **Internal bus:** The display board also forwards T1 to the mainboard via the
   CN1 internal bus (display → mainboard). When Follow Me is active, T1
   **overrides** the mainboard's own thermistor — the mainboard uses the room
   controller's sensor as its control reference.

When Follow Me is disabled, the override is removed and T1 in R/T 0xC0
`body[11]` switches back to the mainboard's own thermistor reading (e.g., 15°C
in Session 5, 21°C in Session 7) within one R/T cycle.

**Summary of the two R/T Follow Me mechanisms:**
- **R/T 0x40 Set** (busadapter → display): carries the Follow Me **flag** in
  `body[8] bit 7` — event-driven, sent once per operator action
- **R/T 0x41 query** (busadapter → display): carries the Follow Me
  **temperature** in `body[4]=0x01, body[5]=T*2+50` — sent continuously
  (~every 5.5s) while Follow Me is active

### 3.4 Cross-bus synchronization of temperature updates

The R/T and XYE buses are **not synchronized**. When the room controller sends
a new temperature via XYE C6, the R/T 0xC0 and XYE C0 polling responses
reflect the change independently, on their own polling cycles.

**Session 5 — temperature change 11°C → 10°C (cross-bus timeline):**

```
t=10.33  XYE C0                       T1=11°C  (last XYE C0 at 11°C)
t=11.52  R/T 0x40  busadapter→display          (operator action, FM flag set)
t=11.58  XYE C6   M→S                 temp=10°C ← room controller sends new temperature
t=11.60  XYE C6   S→M                 response
t=11.72  R/T 0xC0 display→busadapter  T1=11°C  (R/T response still 11°C — old value)
t=11.97  R/T 0x93 busadapter→display            (ext status request)
t=12.20  XYE C0                       T1=11°C  (XYE C0 also still 11°C)
t=12.42  R/T 0x41 busadapter→display  body[4]=0x01 body[5]=0x46 (10°C) ← first R/T frame with new temp
t=13.40  XYE C0                       T1=11°C  (XYE C0 still 11°C)
t=13.78  R/T 0xC0 display→busadapter  T1=10°C  ← display reflects the new temp (1.4s after R/T 0x41)
t=14.00  XYE C0                       T1=11°C  (XYE C0 still at 11°C!)
t=14.60  XYE C0                       T1=10°C  ← XYE C0 finally catches up (3.0s after XYE C6)
```

The sequence shows:
1. **XYE C6** delivers 10°C from the room controller at t=11.58
2. **R/T 0x41** (busadapter → display) carries 10°C at t=12.42 — 0.84s after XYE C6
3. **R/T 0xC0** (display → busadapter) reflects 10°C at t=13.78 — 1.36s after R/T 0x41
4. **XYE C0** finally shows 10°C at t=14.60 — 3.0s after XYE C6

The R/T 0x41 is the first frame to carry the new temperature after the XYE C6
delivers it. The display board then reflects it in its next R/T 0xC0 response.
The XYE C0 polling response updates independently and happened to be slower in
this case. There is no synchronization mechanism between buses.

---

## 4. Protocol Mechanism — Frame Details

### 4.1 Follow Me enable/disable — 0x40 Set body[8] bit 7 (busadapter → display)

The busadapter sends R/T 0x40 Set Status to the AC display board (start=0xAA,
direction: toACdisplay). When Follow Me is active, `body[8] bit 7 = 1` (0x80).
When disabled, `body[8] bit 7 = 0`.

**FM enabled (t=468.15s, Session 7):**
```
aa bc 22 ac 00 00 00 00 00 03 02  40 01 69 66 00 00 00 30 80 00 00 00 ...
[start][dev][ln][app][--reserved--][p][mt] b0 b1 b2 b3 b4 b5 b6 b7 b8 b9
                                           ^Set              ^swing ^^ body[8]=0x80
                                                                       FollowMe=YES
```

**FM disabled (t=469.05s, Session 7):**
```
aa bc 22 ac 00 00 00 00 00 03 02  40 01 69 66 00 00 00 30 00 00 00 00 ...
                                                                ^^ body[8]=0x00
                                                                   FollowMe=NO
```

The only byte that changes between the two frames is `body[8]`: 0x80 → 0x00.
All other fields (mode, temperature, fan, swing) remain identical.

### 4.2 Follow Me readback — 0xC0 Response body[8] bit 7 (display → busadapter)

The AC display board responds with 0xC0 Status Response (start=0x55,
direction: fromACdisplay). The same bit 7 of body[8] reflects the current
Follow Me state.

**FM active (t=465.67s, Session 7):**
```
55 bc 28 ac 00 00 00 00 00 03 03  c0 01 49 66 7f 7f 00 00 80 00 00 62 3b ...
                                   ^RSP                         ^^ b8=0x80 FM=YES
                                                                      ^^ b11=0x62
                                                                 IndoorT=(98-50)/2=24.0C
```

**FM disabled (t=468.35s, Session 7):**
```
55 bc 28 ac 00 00 00 00 00 03 02  c0 01 69 65 7f 7f 00 00 00 00 00 62 3b ...
                                                            ^^ b8=0x00 FM=NO
                                                                 ^^ b11=0x62
                                                            IndoorT=24.0C (not yet switched)
```

### 4.3 0x40 Set carries setpoint, not FM temperature (busadapter → display)

The temperature field in the 0x40 Set (`body[2]` bits[3:0] + bit[4]) encodes the
**user setpoint**, not the Follow Me sensor temperature. Session 7 confirms this:

| Time | FM | Set Temp | FM Sensor | Mode |
|------|-----|----------|-----------|------|
| 3.91s | YES | 22.0 C | 24 C | Heat |
| 6.42s | YES | 20.0 C | 24 C | Heat |
| 8.93s | YES | 18.0 C | 24 C | Heat |
| 11.44s | YES | 16.0 C | 24 C | Heat |
| 29.23s | YES | 17.0 C | 24 C | Heat |

The setpoint changes (operator stepping through 22→20→18→16→17) while the FM
sensor temperature stays at 24 C (read from 0xC0 body[11]). The 0x40 Set does
not carry the FM room temperature at all — only the setpoint and the FM
enable/disable flag.

### 4.4 Indoor temperature (T1) source switch (in 0xC0, display → busadapter)

When Follow Me is active, `body[11]` in 0xC0 responses (display → busadapter) reports
the **Follow Me sensor temperature** (from the wall controller), not the indoor
unit's own thermistor. When Follow Me is disabled, T1 switches to the unit's
own sensor.

**Session 7 — FM disable at t=468s:**

| Time (s) | body[8] bit 7 | body[11] | Indoor Temp | Source |
|----------|---------------|----------|-------------|--------|
| 465.67 | 0x80 (FM=YES) | 0x62 | 24.0 C | KJR-120M wall controller sensor |
| 468.35 | 0x00 (FM=NO)  | 0x62 | 24.0 C | transitional (not yet switched) |
| 469.25 | 0x00 (FM=NO)  | 0x5C | 21.0 C | indoor unit's own thermistor |
| 469.70+ | 0x00 (FM=NO) | 0x5C | 21.0 C | indoor unit's own thermistor |

The temperature source switch happens within **one R/T polling cycle** (~1s)
after the FM flag clears. The 3 C drop (24 → 21 C) is consistent with the
KJR-120M reading the room near the controller (warmer area) while the indoor
unit's thermistor reads a lower ambient.

**Session 4 — FM active at 13 C (constant):**

| body[11] | Indoor Temp | Expected (FM sensor) |
|----------|-------------|---------------------|
| 0x4C     | 13.0 C      | 13 C (matches KJR-120M display) |

**Session 5 — FM active, controller outside (temp drifting):**

| Time (s) | body[11] | Indoor Temp | KJR-120M display |
|----------|----------|-------------|-------------------|
| 1.52     | 0x48     | 11.0 C      | ~11 C             |
| 13.78    | 0x46     | 10.0 C      | ~10 C             |

The indoor unit's own thermistor read ~15 C during this session, but body[11]
tracked the wall controller's sensor (11 → 10 C), confirming T1 is the Follow
Me source, not the unit's local sensor.

**Session 8 — FM disabled (control group):**

| body[8] bit 7 | body[11] | Indoor Temp | Source |
|---------------|----------|-------------|--------|
| 0x00 (FM=NO) throughout | varies | 27.0 C | indoor unit's own thermistor |

---

## 5. R/T Follow Me Temperature Frame — Standard Query Variant

The Follow Me temperature on the R/T bus is carried by **R/T 0x41 query
(busadapter → display)** with `body[4]=0x01, body[5]=T*2+50`. This uses the
**standard query format** (`body[1]=0x81`, 38-byte frame) — not the extended
query format (`body[1]=0x21`, 24-byte frame) documented in protocol_serial.md
§3.1.4 and mill1000 Finding 10c.

### 5.1 R/T 0x41 query variants (Session 7, complete)

| body[1] | body[2] | body[3] | body[4] | Count | Purpose |
|---------|---------|---------|---------|-------|---------|
| 0x81 | 0x00 | 0xFF | 0x00 | 136 | R/T standard status query → R/T 0xC0 |
| 0x81 | 0x01 | 0x41 | 0x00 | 120 | R/T group page 0x41 → R/T 0xC1 |
| 0x81 | 0x01 | 0x42 | 0x00 | 115 | R/T group page 0x42 → R/T 0xC1 |
| 0x81 | 0x01 | 0x43 | 0x00 | 109 | R/T group page 0x43 → R/T 0xC1 |
| 0x81 | 0x00 | 0xFF | **0x01** | 96 | **R/T Follow Me temp** (`body[5]=T*2+50`) → R/T 0xC0 |

The Follow Me variant is identical to the standard status query (`b2=0x00,
b3=0xFF`) except `body[4]=0x01` and `body[5]` carries the encoded temperature.
No other optCommand values (0x02–0x06) were observed on the R/T bus.

### 5.2 Discrepancy with UART documentation

Protocol_serial.md §3.1.4 states that in the standard 0x41 query
(`body[1]=0x81`), body[4] is "0x00 (unused)". The optCommand field is
documented only for the extended 0x41 (`body[1]=0x21`). **The R/T bus
contradicts this**: it uses the standard format with `body[4]` repurposed to
carry the optCommand.

The extended query format (`body[1]=0x21`) was **never observed** on the R/T
bus in any session. All R/T 0x41 frames use `body[1]=0x81`.

### 5.3 Verification across sessions

| Session | Follow Me state | R/T 0x41 body[4]=0x01 | body[5] | Decoded temp | Expected |
|---------|----------------|----------------------|---------|-------------|----------|
| 4 | ON (13°C) | 16 frames | 0x4C | 13°C | 13°C |
| 5 | ON (11→10°C) | 10 frames | 0x48→0x46 | 11→10°C | 11→10°C |
| 7 | ON then OFF (24°C) | 96 frames (ON) + 22 frames (OFF, stale) | 0x62 | 24°C | 24°C |
| 8 | OFF (never active) | **0 frames** | — | — | correct |

Session 8 (Follow Me never active) has zero `body[4]=0x01` frames — confirming
this variant only appears when Follow Me is or was active. Session 7 continues
sending `body[4]=0x01` after Follow Me disable (during operator actions that
trigger XYE C6 STOP), carrying the stale 24°C value.

### 5.4 Wi-Fi UART — no active Follow Me temperature observed

The Wi-Fi UART bus (Sessions 4, 5, 8) only contained heartbeat frames
(0xA0–0xA6) — no 0x41 queries of any format. The 0xA0 heartbeat ACK shows
`Indoor Temp = -25°C (raw=0)` — uninitialized. The Wi-Fi dongle was connected
but not actively polling in these sessions, so the UART Follow Me temperature
path could not be tested.

---

## 6. Cross-Bus Translation: XYE C6 → R/T 0x40

### 6.1 Translation mapping

| XYE event | R/T equivalent | Direction | Mechanism |
|-----------|---------------|-----------|-----------|
| C6 START (byte[10]=0x46) | R/T 0x40 Set `body[8]` bit 7 = 1 | busadapter → display | Follow Me flag relay |
| C6 STOP (byte[10]=0x44) | R/T 0x40 Set `body[8]` bit 7 = 0 | busadapter → display | Follow Me flag relay |
| C6 byte[11] = room temp (direct C) | R/T 0x41 `body[4]=0x01, body[5]=T*2+50` | busadapter → display | Temperature relay (encoding conversion) |
| C6 UPDATE (byte[10]=0x42) | R/T 0x41 `body[4]=0x01` with updated temp | busadapter → display | Periodic temperature refresh |
| (all of the above) | R/T 0xC0 `body[11]` = T * 2 + 50 | display → busadapter | Display reflects T1 back continuously |

The busadapter performs three functions:
1. **Follow Me flag relay**: XYE C6 START/STOP → R/T 0x40 `body[8]` bit 7 (busadapter → display)
2. **Temperature relay**: XYE C6 room temp → R/T 0x41 `body[4]=0x01, body[5]=T*2+50` (busadapter → display)
3. **Encoding conversion**: XYE uses direct Celsius in C6 byte[11]; R/T uses `T * 2 + 50` in both 0x41 body[5] and 0xC0 body[11]

### 6.2 Timing and asynchronous relay

The R/T bus and XYE bus are **not synchronized**. The R/T bus polls on its own
cycle, independent of XYE. Frame-level timing analysis from Session 7:

**R/T polling pattern:**
- Each R/T request→response pair (busadapter → display → busadapter) takes ~0.2s
- Pair-to-pair interval is ~0.9–1.2s; full cycle ~5.5s
- The R/T bus uses a multi-slot cycle: R/T 0x41 queries + R/T 0xC0/0xC1 responses + R/T 0x93 ext status, with R/T 0x40 Set injected only on operator actions

**Cross-bus relay delay — FM disable event (Session 7, t=468s):**

```
t=465.67  R/T  display→busadapter  0xC0  FM=YES  (last FM-active response)
t=468.15  R/T  busadapter→display  0x40  FM=YES  (Set in-flight — busadapter hasn't processed XYE C6 STOP yet)
t=468.20  XYE  C6 M→S        STOP          (KJR-120M sends C6 STOP on XYE bus)
t=468.22  XYE  C6 S→M        response      (indoor unit acknowledges STOP)
t=468.35  R/T  display→busadapter  0xC0  FM=NO   (display responds FM=NO — 0.15s after C6 STOP)
t=469.05  R/T  busadapter→display  0x40  FM=NO   (busadapter sends updated FM=NO — 0.85s after XYE C6 STOP)
t=469.25  R/T  display→busadapter  0xC0  FM=NO   (confirmed, stays NO from here)
```

**Key observations:**
- The R/T 0x40 (busadapter → display) at t=468.15 was already in-flight when the XYE C6 STOP arrived at t=468.20 — it still carries FM=YES (stale state)
- The R/T 0xC0 (display → busadapter) at t=468.35 already shows FM=NO, only 0.15s after the XYE C6 STOP — the display board processed the XYE state change faster than the busadapter's next R/T 0x40
- The busadapter updates its R/T 0x40 Set to FM=NO at t=469.05, 0.85s after the XYE C6 STOP
- **Typical relay delay: 0.8–0.9s** (one R/T polling cycle)
- **In-flight R/T frames carry stale state** — a R/T 0x40 Set sent before a XYE C6 event will reflect the previous state

**Brief FM toggle (Session 7, t=175s):**

```
t=174.91  R/T  busadapter→display  0x40  FM=YES  (in-flight before C6 STOP)
t=174.97  XYE  C6 M→S        STOP
t=175.11  R/T  display→busadapter  0xC0  FM=NO   (display responds FM=NO, 0.14s later)
t=175.81  R/T  busadapter→display  0x40  FM=NO   (busadapter relays FM=NO, 0.84s later)
t=176.01  R/T  display→busadapter  0xC0  FM=NO
t=176.17  XYE  C6 M→S        START         (re-enabled 1.2s later)
t=176.26  R/T  busadapter→display  0x40  FM=YES  (busadapter relays FM=YES, 0.09s later — fast!)
t=176.46  R/T  display→busadapter  0xC0  FM=NO   (response still NO — one cycle latency)
t=177.37  XYE  C6 M→S        START         (reinforcement)
t=178.52  R/T  display→busadapter  0xC0  FM=YES  (finally confirmed, 2.3s after first START)
```

This shows the asymmetric timing: the busadapter can relay a XYE C6 START into a
R/T 0x40 very quickly (0.09s) if the R/T cycle happens to align, but the
display board's R/T 0xC0 response takes an additional R/T cycle to reflect
the new FM state.

---

## 7. Follow Me Lifecycle on R/T Bus

### 7.1 Activation (START)

1. Operator enables Follow Me on the KJR-120M wall controller
2. **XYE:** KJR-120M sends C6 to the busadapter with byte[10]=0x46 (START), byte[11]=room temp in direct Celsius
3. **XYE:** Busadapter receives XYE C6, sets its internal FM flag, stores the room temperature
4. **R/T:** Busadapter sends the next R/T 0x40 Set (busadapter → display) with `body[8] bit 7 = 1` (0x80) — FM enabled
5. **R/T:** Display board responds with 0xC0 (display → busadapter) — `body[8] bit 7 = 1` (FM active) and `body[11]` = FM sensor temperature (encoded as `T * 2 + 50`)

### 7.2 Steady state

- **R/T:** The 0x40 Set (busadapter → display) with `body[8]=0x80` is **not continuously
  repeated**. It only appears when the operator changes a setting (mode/fan/setpoint).
  Between actions: zero R/T 0x40 frames.
- **R/T:** The display board retains the FM state internally after receiving the
  initial R/T 0x40 Set — it does not need periodic reminders from the busadapter.
- **R/T:** The 0xC0 Status Response (display → busadapter) **is** continuous (~every 5.5s,
  part of the idle R/T polling cycle). It always carries the current FM flag in
  `body[8] bit 7` and the FM sensor temperature in `body[11]`.
- **XYE:** Every operator action triggers a C3+C6 START pair on the XYE bus.
  Periodic XYE C6 UPDATE (every ~3-5 minutes) refreshes the temperature.
- **XYE→R/T:** When the busadapter receives a XYE C6 UPDATE, it relays the
  updated temperature in the next R/T 0x41 query (busadapter → display) with
  `body[4]=0x01, body[5]=T*2+50`. The display board then reflects it in the
  next R/T 0xC0 response (display → busadapter) in `body[11]`.

### 7.3 Deactivation (STOP)

1. Operator disables Follow Me on the KJR-120M wall controller
2. **XYE:** KJR-120M sends C6 to the busadapter with byte[10]=0x44 (STOP)
3. **XYE:** Busadapter receives XYE C6, clears its internal FM flag
4. **R/T:** Busadapter sends the next R/T 0x40 Set (busadapter → display) with `body[8] bit 7 = 0` (0x00) — FM disabled
5. **R/T:** Display board responds with 0xC0 (display → busadapter) — `body[8] bit 7 = 0` (FM inactive) and `body[11]` switches from the FM sensor temperature to the unit's own thermistor
6. **R/T:** The T1 source switch in `body[11]` of the 0xC0 response (display → busadapter) happens within one R/T polling cycle (~1s)

---

## 8. Open Question Updates

### OQ-16: Follow Me body[8] bit 7 — Lua vs mill1000/midea-msmart (Disputed → Confirmed)

mill1000/midea-msmart Finding 10 (see `midea-msmart-mill1000.md`) places Follow
Me (`bodySense`) at body[8] bit 7 of the 0x40 Set command. The Lua SET command
decoder has `strongWind/comfortableSleep/power_saving` at body[8] instead.

**Own hardware captures confirm body[8] bit 7 = Follow Me**:
- Session 7: R/T 0x40 body[8] transitions from 0x80 (FM=YES) to 0x00 (FM=NO)
  in exact correlation with XYE C6 STOP events
- Sessions 3-6: R/T 0x40 body[8]=0x80 consistently throughout all FM-active captures
- Session 8: R/T 0x40 body[8]=0x00 consistently when Follow Me is disabled
- Both R/T 0x40 Set (busadapter → display) and R/T 0xC0 Response (display →
  busadapter) show the same bit

**Resolution**: mill1000/midea-msmart Finding 10 is correct. The Lua SET
dissector's body[8] interpretation appears to apply to a different device type
or firmware variant. On the tested Midea XtremeSave Blue, body[8] bit 7 =
Follow Me.

### OQ-17: localBodySense at body[9] bit 7 (Unknown → Not Observed)

mill1000 Finding 10b claims R/T 0xC0 `body[9] bit 7 = localBodySense` (unit's
own body-sense active). This was not specifically tested but R/T 0xC0 body[9]
was consistently 0x00 in Session 7 captures regardless of Follow Me state. May
require a unit with built-in occupancy/body-sense detection to observe.

---

## 9. Evidence Summary

| Finding | Sessions | Confidence |
|---------|----------|------------|
| R/T 0x40 Follow Me flag: `body[8]` bit 7 (busadapter → display) | 3, 4, 5, 6, 7, 8 | **Confirmed** |
| R/T 0xC0 Follow Me readback: `body[8]` bit 7 (display → busadapter) | 7, 8 | **Confirmed** |
| R/T 0x41 Follow Me temp: `body[4]=0x01, body[5]=T*2+50` (busadapter → display) | 4, 5, 7, 8 | **Confirmed** |
| R/T 0x41 uses standard format (`body[1]=0x81`), not extended (`body[1]=0x21`) | 4, 5, 7, 8 | **Confirmed** |
| R/T 0xC0 `body[11]` T1 = FM sensor when Follow Me active (display → busadapter) | 4, 5, 7 | **Confirmed** |
| R/T 0xC0 `body[11]` T1 = mainboard thermistor when Follow Me disabled | 7, 8 | **Confirmed** |
| R/T 0x40 Set is event-driven, not continuous (busadapter → display) | 4, 7 | **Confirmed** |
| R/T 0x40 Set carries setpoint, not Follow Me temperature | 7 | **Confirmed** |
| R/T 0xC0 response repeats every ~5.5s (display → busadapter, idle cycle) | 4, 7 | **Confirmed** |
| R/T 0x41 optCmd=0x01 continues after FM disable (stale temp, operator actions only) | 7 | **Observed** |
| Wi-Fi UART: only heartbeats, no active polling (dongle not app-connected) | 4, 5, 8 | **Observed** |
| XYE→R/T relay delay: ~0.8-0.9s (one R/T cycle) | 7 | **Observed** |
| R/T in-flight frames carry stale state when XYE event arrives mid-cycle | 7 | **Observed** |
| ~~No R/T 0x41 optCmd=0x01 on R/T bus~~ | — | **Corrected** (searched for wrong format) |

---

## 10. Architecture Diagram

```
KJR-120M                    busadapter                       AC display board
  (wall controller)          (R/T master)                    (R/T slave)
        |                         |                               |
        |--- XYE C6 START ------>|                               |
        |    byte[10]=0x46       |--- R/T 0x40 Set (0xAA) ------>|  Follow Me flag
        |    byte[11]=room_temp  |    body[8]=0x80 (FM=YES)      |
        |                        |                               |
        |                        |--- R/T 0x41 Query (0xAA) ---->|  Follow Me temperature
        |                        |    body[4]=0x01               |
        |                        |    body[5]=room_temp*2+50     |
        |                        |                               |
        |                        |<-- R/T 0xC0 Response (0x55) --|  continuous readback
        |                        |    body[8]=0x80 (FM=YES)      |
        |                        |    body[11]=room_temp*2+50    |
        |                        |                               |
        |--- XYE C6 UPDATE ----->|--- R/T 0x41 Query (0xAA) ---->|  updated temperature
        |    byte[10]=0x42       |    body[4]=0x01               |
        |    byte[11]=new_temp   |    body[5]=new_temp*2+50      |
        |                        |                               |
        |--- XYE C6 STOP ------>|--- R/T 0x40 Set (0xAA) ------>|  Follow Me flag clear
        |    byte[10]=0x44       |    body[8]=0x00 (FM=NO)       |
        |                        |                               |
        |                        |<-- R/T 0xC0 Response (0x55) --|  T1 switches source
        |                        |    body[8]=0x00 (FM=NO)       |
        |                        |    body[11] → own thermistor  |
        |                        |                               |
        |  (FM disabled, idle)   |--- R/T 0x41 Query (0xAA) ---->|  body[4]=0x00 (no FM temp)
        |                        |    normal idle cycle           |
        |                        |                               |
        |  (FM disabled,         |--- R/T 0x41 Query (0xAA) ---->|  body[4]=0x01, body[5]=stale temp
        |   operator action      |    (stale last-known temp,    |
        |   triggers C6 STOP)    |     only during actions)      |
```

Note: The R/T bus is asynchronous relative to XYE. The busadapter relays each
XYE C6 event on the next R/T polling slot (~0.8-0.9s delay). In-flight R/T
frames sent before a XYE C6 event carry the previous state.

---

## Appendix A — Alternative Follow Me Paths

### A.1 IR path

ESPHome's midea component (dudanov/esphome, open-source) sends Follow Me via
**IR transmission**, not serial. It constructs an IR frame containing the
temperature and transmits it via an IR LED, emulating a physical Midea remote.
This bypasses the serial bus entirely. The IR approach does not require a
wired controller or busadapter.

### A.2 UART extended query — not yet captured

The serial protocol documentation (protocol_serial.md §3.1.4.6) describes a
UART Follow Me temperature push using the **extended 0x41 query** format
(`body[1]=0x21`, 24-byte frame, `body[4]=0x01, body[5]=T*2+50`). This is the
expected Wi-Fi app path. Source: mill1000/midea-msmart Finding 10 (see
`midea-msmart-mill1000.md`).

Comparison with the R/T variant we captured:

| Aspect | R/T (own captures) | UART extended (documented, not captured) |
|--------|-------------------|----------------------------------------|
| body[1] | `0x81` (standard query) | `0x21` (extended query) |
| Frame length | 38 bytes | 24 bytes |
| body[4] | `0x01` (optCommand) | `0x01` (optCommand) |
| body[5] | `T * 2 + 50` | `T * 2 + 50` |
| Temperature encoding | identical | identical |
| Response | 0xC0 status | 0xC1 extended state |

The payload encoding is the same — only the frame format and expected response
differ. We have not captured the UART extended variant because the Wi-Fi dongle
was never actively polling in our sessions (only heartbeats). A session with
the dongle paired to an active app would be needed to observe it.
