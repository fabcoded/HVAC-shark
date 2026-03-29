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
confirm that T1 (byte 0x0B) tracks the KJR-120M wall-controller sensor, not the indoor
unit's own thermistor. When the KJR-120M was moved outside (~11 °C) T1 = 10–11 °C; when
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
| 0xC4    | own captures | 16-byte request → 32-byte response | **Device enumeration + extended query.** KJR-120M cold boot: scans addresses 0x00–0x0F (200 ms interval); steady-state continues probing non-zero addresses. KJR-120X: no cold boot data; steady-state polls only addr 0x00. See §0.4c–§0.4f. Response layout: see §7a. |
| 0xC6    | ESPHome + Session 3 captures | 16-byte request → 32-byte response | **Confirmed frame pattern** (Session 3). See §0.4a. |
| 0xCC    | codeberg           | 16-byte request → 32-byte response | Lock. Emulator responds with `0xC0 | 0x0C = 0xCC` in the response code. |
| 0xCD    | codeberg           | 16-byte request → 32-byte response | Unlock. Emulator responds with `0xC0 | 0x0D = 0xCD`. |

**Resolved (Session 9):** C4 uses standard 16-byte request → 32-byte response
framing, same as C0/C3. The earlier confusion arose because unanswered C4 probes
(to non-existent slaves) produced only 16-byte request frames with no 32-byte
response. The 32-byte C4 responses use the same layout as C6 responses (see §7a).

### 0.4c KJR-120M Cold Boot & Polling — **Confirmed** (own captures, Sessions 4 & 9)

Sessions 4 and 9 both captured cold boots (power off → on) with HAHB bus recording.
The KJR-120M performs a full device enumeration using C4 before any other traffic:

**Phase 1 — Fast C4 scan (~3.2 s):** Master sends C4 to addresses 0x00 through
0x0F in sequence. Each unanswered probe is followed by a 200 ms silence before the
next address is tried — this is the response window. A 16-byte C4 frame at 4800 bps
takes ~33 ms to transmit, leaving ~167 ms of listening time per probe. If no slave
responds within 200 ms of the probe start, the master moves to the next address.
16 addresses × 200 ms = 3.2 s per full sweep. During Phase 1, no unit has booted
its communication stack yet, so all 16 probes go unanswered.

**Phase 2 — First response:** On the second sweep, address 0x00 responds to C4
within ~19 ms of the probe (32-byte response at 4800 bps takes ~66 ms). The master
detects the response, immediately sends a C0 Query (40 ms after C4 response ends),
and gets a C0 response (~20 ms latency) with mode 0x00 (OFF/standby). It then
continues probing the remaining addresses (0x01–0x0F) with the same 200 ms timeout
per unanswered probe.
Confirmed identical in both Session 4 (first response after ~3.2 s) and Session 9
(first response after ~3.2 s).

**Phase 3 — Post-discovery sequence (identical in both sessions):**

After the first C4 response, the master follows a fixed sequence before entering
steady-state. Both Session 4 (Follow-Me ON) and Session 9 (Follow-Me OFF) produce
the same frame sequence:

```
+  0 ms  M→S  C4 addr=0x00                  ← probe that gets answered
+ 19 ms  S→M  C4 response                   ← slave responds in ~19 ms
+ 60 ms  M→S  C0 addr=0x00                  ← immediate status query
+ 80 ms  S→M  C0 response (mode=0x00, OFF)  ← unit reports OFF
+130 ms  M→S  C4 addr=0x01                  ← resume sweep, remaining addresses
+330 ms  M→S  C4 addr=0x02                  ← 200 ms timeout, no response
  …                                          ← 0x03–0x0F, all unanswered
+3130 ms M→S  C4 addr=0x00                  ← second pass, addr 0x00 responds again
+3150 ms S→M  C4 response
```

Note: In both sessions the unit was turned off before the power cut, so the first
C0 response showing mode=0x00 (OFF) is expected. Whether a unit that was running at
the time of power loss would boot to a different mode is unknown — no capture exists
for that scenario.

**No readiness indicator observed:** The first and second C4 responses are
byte-identical in both sessions — no field changes between sweeps. The controller
does not appear to check a "ready" flag; it mechanically completes its two-sweep
enumeration before transitioning to steady-state.

**C4 byte[16] — NV mode memory:** The C4 response byte[16] at boot reveals the
indoor unit's NV-stored operating mode *without the power-on bit* (0x80):
- Session 4: byte[16]=`0x04` at boot → `0x84` (Heat) after first C3 Set
- Session 9: byte[16]=`0x01` at boot → `0x81` (Dry) after first C3 Set

The low nibble matches the last-used mode from before power loss (0x04=Heat,
0x01=Dry). This contrasts with C0 byte[8]=`0x00` (OFF) at boot. Whether the
KJR-120M uses this NV mode byte to pre-select the mode for the operator is
unknown — the operator's first C3 Set happened to match the NV-stored mode in
both sessions.

**Phase 4 — Steady-state polling:** The KJR-120M enters a repeating poll cycle
(~1.8 s per full cycle) with no C3 or C6 traffic until the operator acts. The
non-zero probe address N cycles sequentially 0x01 → 0x02 → … → 0x0F → 0x01:

```
C4 addr=0x00 → response (19 ms) → [280 ms gap] →
C0 addr=0x00 → response (20 ms) → [280 ms gap] →
C4 addr=0x00 → response (19 ms) → [280 ms gap] →
[D0 broadcast from indoor unit] → [300 ms gap] →
C4 addr=N   → (no response, 300 ms timeout) → [next cycle]
```

Session 9: 66 non-zero probes observed across 80 s, all unanswered (single unit).

**Phase 5 — First operator action (C3+C6 pair, Follow-Me behaviour):**

The first C3 Set + C6 pair appears only when the operator presses a button on the
KJR-120M. If the button was pressed during boot (before the bus was ready), the
KJR-120M queues the command and sends it once steady-state polling is established.
The C3+C6 pair interrupts the polling cycle:

Session 9 (Follow-Me OFF — operator pressed mode button at t≈9 s, during boot):
```
+3150 ms S→M  C4 response                        ← second sweep complete
+3290 ms M→S  C3 Set   mode=0x81 (Dry) fan=Auto setpt=21°C   ← queued button press
+3311 ms S→M  C3 response
+3360 ms M→S  C6       swing=0x00  FM=STOP (0x44)  temp=23°C
+3380 ms S→M  C6 response
+3660 ms M→S  C0 addr=0x00  ← resumes normal polling
```

Session 4 (Follow-Me ON — operator did not press any button during boot):
```
         … ~21.9 s of pure C4/C0 polling, no C3/C6 …
+21905 ms M→S  C3 Set   mode=0x84 (Heat) fan=Auto setpt=22°C   ← first button press
          S→M  C3 response
+21975 ms M→S  C6       swing=0x00  FM=START (0x46)  temp=13°C
          S→M  C6 response
```

**Follow-Me at boot — observations:**
- C6 is never sent autonomously at boot. It always accompanies a C3 Set triggered
  by operator input.
- **FM was active before power loss (Session 4):** KJR-120M remembers FM state
  across the power cycle. The first C6 sends START (0x46) with the remembered
  sensor temperature (13 °C). All subsequent C3+C6 pairs also carry START.
- **FM was inactive before power loss (Session 9):** Every C3+C6 pair carries
  STOP (0x44) with temp=23 °C. This clears any stale FM state the indoor unit
  may have retained in NV memory from before power loss.

**Key observations:**
- Address range: 0x00–0x0F (16 addresses max on this bus)
- Boot time: ~3.2 s from first C4 probe to first slave response (both sessions)
- C4 request byte[6..7] = `0xA5 0x5A` — magic marker, constant across all probes
- No C0 or C3 traffic until at least one C4 response is received
- **Probe-to-response latency**: ~19–20 ms (slave starts transmitting 32-byte
  response ~19 ms after the 16-byte command ends). Observed across all C0/C3/C4/C6
  responses in Sessions 4 and 9.
- **Unanswered probe spacing**: exactly 200 ms between start of one probe and start
  of next (±1 ms jitter). This 200 ms window = ~33 ms transmit + ~167 ms listen.
- **Answered probe spacing**: after a response is received, the master waits ~40 ms
  before sending the next command (C0 follow-up or next C4 probe)

### 0.4d KJR-120X Polling Pattern — **Confirmed** (own dongle captures, Sessions 1–2)

The KJR-120X was captured mid-operation via passive ESP dongle sniffing (no cold
boot data available). Its polling behavior differs fundamentally from the KJR-120M:

**No address sweep:** All 534 master commands in dongle Session 1 (167 s) target
dest=0x00 exclusively. Zero commands to any non-zero address were observed at
any point — not during startup, not during steady-state, not after mode changes.

**Steady-state polling pattern:** Simple C0/C4 alternation to address 0x00:

```
C0 addr=0x00 → response (~20 ms) → C4 addr=0x00 → response (~20 ms) → …
```

Inter-command spacing: ~300 ms typical (range 150–700 ms, median ~300 ms).
No non-zero address probing. No D0 broadcasts visible (dongle is on the XYE bus
directly, not the HAHB side where D0 originates).

**HYPOTHESIS — no boot enumeration:** The KJR-120X likely skips C4 address
enumeration entirely and assumes a single indoor unit at address 0x00. This is
consistent with its design as a dedicated single-unit controller (the MFB-C XYE
adapter connects one controller to one indoor unit). No cold boot capture exists
to confirm — planned experiment.

**C6 Follow-Me variant:** KJR-120X uses Variant B (bit 0x40 clear):
- 0x06 = START (Session 1: 9×, Session 2: 3×)
- 0x04 = STOP (Session 1: 3×, Session 2: 3×)
- 0x02 = UPDATE (Session 1: 1×)

This contrasts with KJR-120M Variant A (0x46/0x44/0x42). See §0.4a for details.

### 0.4e Controller Comparison — KJR-120M vs KJR-120X

| Behavior | KJR-120M (Sessions 1–9, logic analyzer) | KJR-120X (Sessions 1–2, dongle) |
|----------|----------------------------------------|----------------------------------|
| Boot address sweep | C4 scan 0x00–0x0F, 200 ms interval | Not observed (**HYPOTHESIS**: none) |
| Sweeps before first response | 1–2 full sweeps (~3.2–6.4 s) | N/A |
| Steady-state non-zero probing | Yes, 1 per cycle cycling 0x01–0x0F | No |
| Polling cadence (addr=0x00) | ~1.8 s full cycle (C4+C0+C4+probe) | ~600 ms (C0+C4 pair) |
| C6 Follow-Me variant | Variant A (0x46/0x44/0x42) | Variant B (0x06/0x04/0x02) |
| D0 broadcasts visible | Yes (src=0x01, dest=0x20) | No (dongle on XYE bus, not HAHB) |
| Bus adapter | MFB-X (HA/HB differential, transformer-coupled) | MFB-C (XYE RS-485, 4-terminal) |

### 0.4f No-Response Debugging Notes

Common causes when an ESP/dongle-based master gets no responses from an indoor unit:

1. **Polling too early after power-on:** The indoor unit needs ~3.2 s to boot its
   communication stack. C4 probes sent before this will get no response. Retry
   the full 0x00–0x0F sweep after a timeout.
2. **Wrong unit address:** If emulating the KJR-120X pattern (poll only addr 0x00),
   a unit configured to a different address will never respond. Use the KJR-120M
   C4 sweep pattern (0x00–0x0F) to discover units at any address.
3. **Stale Follow-Me state:** After boot, send C6 with byte[10]=0x44 (STOP) to
   clear any Follow-Me state the indoor unit retained from before power loss.

### 0.4a Command 0xC6 — Dual-purpose: Follow-Me + Swing — **Confirmed** (own captures, Sessions 3/7/8)

C6 is a **dual-purpose master→slave command**. It carries both Follow-Me handshake
and swing (vane) activation state. The two functions coexist in the same 16-byte
frame — byte[7] selects swing mode while the C3+C6 pairing signals Follow-Me.

#### C6 framing pattern

C6 appears in two contexts — paired with C3 or standalone — depending on the
controller and the Follow-Me sub-command:

**Paired (C3+C6 atomic pair, ~60 ms gap):**
```
C3 Set (controller → AC) → C3 Response (AC → controller) →
C6     (controller → AC) → C6 Response (AC → controller)
```
KJR-120M: START and STOP are always paired with C3. Every C3 Set is followed by
a C6 — START when FM is active, STOP when FM is inactive.
KJR-120X: START and STOP are paired with C3 when the operator changes settings
(mode/fan/setpoint) while toggling FM. Dongle Session 1: 11 of 12 C6 paired with C3.

**Standalone (C6 without preceding C3):**
```
C0/C4 Response (AC → controller) → C6 (controller → AC) → C6 Response (AC → controller)
```
Both controllers: UPDATE is always standalone — sent to refresh the FM temperature
without changing any settings. KJR-120M: 4 standalone UPDATE across logic analyzer
Sessions 6–7. KJR-120X: 1 standalone UPDATE in dongle Session 1.
KJR-120X only: START and STOP can also be standalone for pure FM toggle without
settings change. Dongle Session 2: all 6 C6 frames are standalone (3× START,
3× STOP), with zero C3 commands in the entire session.

#### C6 master request (16-byte) layout

```
AA C6 [dest] [src] [master] [ownID]  b6  b7  b8  b9  b10 b11 b12 b13 [CRC] 55
                                      ↑
                                     b6 = swing state
```

**Byte [6] — Swing activation** (Sessions 7/8, validated across all sessions):

| Value | Meaning |
|-------|---------|
| 0x00  | Swing off (all vanes stopped) |
| 0x10  | Vertical swing on (up/down auto oscillation) |
| 0x20  | Horizontal swing on (left/right auto oscillation) |

Bytes [7..9] were always 0x00 in all observed C6 frames (Sessions 3–9 + unsorted).
The room temperature is **not** embedded in the C6 request — it travels in the C3
byte[8] that immediately precedes each C6.

**Byte [8] — C6 Mode Flags** (multi-purpose, own captures + two external sources):
- 0x00 = normal operation. Own captures: constant 0x00 across 107 C6 commands (Sessions 3–9).
- 0x80 = emergency (aux-only) heat request [Candidate — single source: mdrobnak, external-captures/01_mdrobnak_ch36ahu].
  The unit confirms by setting bit 0x40 in C4 response byte[15] (see §7a).
  Internally consistent (3× normal, 1× emergency), all CRC-valid.
  Not observed in own captures (emergency heat never activated on test unit).
- 0x1N = static pressure SP0..SP4 (lower nibble = level) [Candidate — single source: rymo, external-captures/02_rymo_static_pressure].
  5 command/response pairs, all CRC-valid. Response byte[24] echoes SP level as 0x2N.
  Not observed in own captures (test unit has no static pressure feature, always 0x00).

**Byte [10] — C6 Sub-command** (three independent sources, two variants):

Variant A (bit 0x40 set) — own logic analyzer captures + ESPHome esphome-mideaXYE-rs485:

| Value | Meaning | Source |
|-------|---------|--------|
| 0x46  | Follow-Me START | Own captures: 84 frames. ESPHome: `sendFollowMeData[10] = 0x46` (first send) |
| 0x42  | Follow-Me UPDATE | Own captures: 4 frames. ESPHome: `sendFollowMeData[10] = 0x42` (subsequent) |
| 0x44  | Follow-Me STOP | Own captures: 19 frames. ESPHome: `sendFollowMeData[10] = 0x44` (disable) |

Variant B (bit 0x40 clear) — KJR-120X wired controller (own + mdrobnak) + rymo wall controller:

| Value | Meaning | Source |
|-------|---------|--------|
| 0x06  | Follow-Me START | Own dongle Session 1: 9 frames, Session 2: 3 frames. mdrobnak: 3 frames |
| 0x04  | Follow-Me STOP | Own dongle Session 1: 3 frames, Session 2: 3 frames. rymo: 5 frames (SP config) |
| 0x02  | Follow-Me UPDATE | Own dongle Session 1: 1 frame. mdrobnak: 1 frame |

The lower nibble encodes the sub-command (0x02=update, 0x04=stop-or-config, 0x06=start).
Bit 0x40 distinguishes master type: set by HAHB-decoded XYE (MFB-X adapter) and
ESPHome/ESP-based masters, clear on KJR-120X wired controllers.
**Cross-validated**: own dongle captures (Midea-XtremeSaveBlue-dongle Sessions 1-2,
KJR-120X passive sniff) independently confirm mdrobnak's Variant B values.
Both variants are accepted by the indoor unit.

**Byte [11] — Follow-Me Temperature** (direct Celsius, all sources agree):
- Own dongle captures: 0x13=19°C, 0x14=20°C, 0x15=21°C (varies between sessions, plausible room temps).
- Own logic analyzer captures + mdrobnak + ESPHome: byte[11] = temperature in °C (direct value, no offset).
- ESPHome code confirms: `sendFollowMeData[11] = static_cast<uint8_t>(std::round(followMeTemp))`.
- rymo SP commands: byte[11] = 0x17 (23) — purpose unclear, consistent across all 5 SP frames.

**Validation across all captures:**

| Session | C6 byte[6] values | Notes |
|---------|-------------------|-------|
| 1–2 | (no C6 frames) | No wired controller |
| 3 | 3× 0x00 | No swing changes |
| 4 | 8× 0x00 | No swing changes |
| 5 | 4× 0x00 | No swing changes |
| 6 | 1× 0x00 | No swing changes |
| 7 | 79× 0x00, 1× 0x10, 1× 0x20 | Phase 6 swing toggle |
| 8 | 2× 0x00, 1× 0x10, 1× 0x20 | Dedicated swing session |
| 9 | 6× 0x00 | No swing changes |
| dongle/Session 1 | 11× 0x00, 1× 0x10 | Vertical swing on first C6, then off |
| dongle/Session 2 | 6× 0x00 | No swing changes, pure Follow-Me toggle |

#### C6 slave response (32-byte)

```
AA C6 ... [oper] [fan] [setT]  BC D6 32 98 … [ctr] 55
           ↑      ↑     ↑                     ↑
          b16    b17   b18              rolling +1
```
- Bytes [16..18] echo the operating state (oper / fan / setT) from the preceding C3
- Response payload is structurally identical to C4 ExtQuery response (see §7a)
- Byte [30] is a rolling counter incrementing +1 per frame

#### Follow-Me function

C6 acts as a Follow-Me handshake: it flags the preceding C3 as a Follow-Me
temperature push (room temperature, not a user-set command) and requests a full
state echo. This is analogous to the UART `body[8] bit 7 = 0x80` enable flag
in 0x40 Set.

**UART parallel** (mill1000/midea-msmart Finding 10, see `midea-msmart-mill1000.md`):

| UART Follow-Me | XYE equivalent |
|----------------|----------------|
| `0x40` body[8]=0x80 enable flag | `C6` request (byte[6]=swing state) |
| `0x41` body[4]=0x01, body[5]=T×2+50 | `C3` byte[8] = T + 0x40 |

The temperature encoding differs: UART uses `T × 2 + 50`; XYE uses `T + 0x40`.

**Session 7:** 81 C6 pairs observed (one per setpoint/mode/fan change). When
Follow-Me was disabled via the KJR-120M menu, C6 pairs stopped immediately (last
C6 at t=762s, session continued to t=781s with no further C6). After disable,
T1 (C0 byte[11]) changed from 24.0 °C to 20.5 °C — T1 switched from KJR-120M
sensor to the indoor unit's own thermistor.

#### Follow-Me lifecycle — controller-specific patterns

**Activation (START):**
The operator enables Follow-Me on the wired controller. The controller sends C6
with byte[10]=START (0x46 KJR-120M / 0x06 KJR-120X) and byte[11]=current room
temperature in °C. On the KJR-120M this is always paired with a C3 Set. On the
KJR-120X, START can be standalone if no settings change simultaneously (dongle
Session 2: 3× standalone START, pure FM toggle).

**Steady-state (START repeated + periodic UPDATE):**
While Follow-Me is active, every operator action (mode/fan/setpoint change) on
the KJR-120M triggers a C3+C6 pair with byte[10]=START. The FM temperature in
byte[11] is refreshed with each pair:
- Logic analyzer Session 4: 8× START at 13 °C (temperature constant, operator changed setpoint/fan)
- Logic analyzer Session 7: 69× START at 24 °C (temperature constant across mode/fan/setpoint sweep)

Periodically, the controller sends a standalone C6 UPDATE (0x42 KJR-120M / 0x02
KJR-120X) to refresh the FM temperature without any operator action:
- KJR-120M logic analyzer Session 7: 3× UPDATE at t=120 s, 302 s, 596 s (~3–5 min intervals)
- KJR-120M logic analyzer Session 6: 1× UPDATE at t=81 s (standalone, no C3)
- KJR-120X dongle Session 1: 1× UPDATE at t=113 s (standalone, no C3)

UPDATE is always standalone (never paired with C3) on both controllers.

**Deactivation (STOP):**
The operator disables Follow-Me. The controller sends C6 with byte[10]=STOP
(0x44 KJR-120M / 0x04 KJR-120X). On the KJR-120X, STOP can be standalone
(dongle Session 2: 3× standalone STOP). On the KJR-120M, STOP is always
paired with C3.

**KJR-120M special behaviour — STOP on every C3 when FM is inactive:**
When Follow-Me is not active, the KJR-120M still sends a C6 STOP after every
C3 Set. This means every KJR-120M settings change produces a C3+C6 pair
regardless of FM state — STOP when FM is off, START when FM is on:
- Logic analyzer Session 8: 4× STOP (FM was disabled, operator only changed swing)
- Logic analyzer Session 9: 6× STOP (FM was disabled, operator cycled modes at cold boot)

This contrasts with the KJR-120X, where C6 only appears when FM is explicitly
toggled or updated — no C6 accompanies C3 when FM is inactive.

#### Swing activation function (Session 8)

When the user sets swing on/off (via wired controller or app), the C6 master
request byte[6] changes to reflect the new swing state. Confirmed in Session 7
Phase 6, Session 8 Phases 1–2, and the unsorted FollowMe+program capture:
- Horizontal swing on: byte[6] = 0x20
- Vertical swing on: byte[6] = 0x10
- Both off: byte[6] = 0x00

Note: C3 response byte[20] bit 2 carries vertical swing flag but does **not**
report horizontal swing. Horizontal swing state is only visible in the D0
broadcast (see §0.4b) and in C6 byte[6].

**Open question:** Does the wired controller (KJR-120M/X) populate C6 bytes [6..9] with a measured
room temperature when an external sensor is wired? Not observed — payload bytes
other than [7] were always zero. ESPHome uses C6 for room temperature; the exact
byte layout is not confirmed against own captures.

### 0.4b Command 0xD0 — Broadcast — **Confirmed** (own captures, Sessions 3–9)

D0 is a 32-byte unsolicited broadcast frame (src=0x01, dest=0x20) observed
only on the HAHB bus (logic analyzer Sessions 3–9, KJR-120M via MFB-X adapter).
It is a periodic status report containing the full operating state, appearing
once per polling cycle (~1.2 s intervals). No command from the controller
triggers it — the AC unit emits D0 autonomously.

**Not observed on the XYE bus:** Dongle Sessions 1–2 (KJR-120X via MFB-C adapter,
XYE bus) contain zero D0 frames across 1,326 total frames. The dongle firmware
(`decode_xye.cpp`) forwards every frame between 0xAA and 0x55 without filtering —
no command codes are dropped. D0 appears to be specific to the HAHB bus and is not
emitted on the XYE bus.

**D0 layout (32 bytes):**

| Byte | Field | Encoding | Validated |
|------|-------|----------|-----------|
| [0] | Preamble | 0xAA | All sessions |
| [1] | Command | 0xD0 | All sessions |
| [2] | Unknown | 0x20 (constant) | Sessions 3–9 |
| [3] | Unknown | 0x01 (constant) | Sessions 3–9 |
| [4] | Unknown | 0x00 (constant) | Sessions 3–9 |
| [5] | Operating Mode | User-set mode only (§5.1), no Auto sub-modes | Session 7: all 5 modes tracked |
| [6] | Fan Speed | Same as C0/C3 (§6) | Session 7: Auto/Low/High tracked |
| [7] | Set Temperature | T + 0x40 (§7) | Session 7: full 16–30°C sweep |
| [8–10] | Reserved | 0x00 | **Confirmed** constant (1540 frames, Sessions 3–9) |
| [11] | **Swing** | See below | **Confirmed** Sessions 7/8 |
| [12–14] | Reserved | 0x00 | **Confirmed** constant (1540 frames) |
| [15] | **FLAGS_1** | 0x04 or 0x06 (2 values) | Sessions 3–9: 592× 0x04, 948× 0x06 |
| [16] | **OUTDOOR_TEMP?** | Variable (7 distinct: 0x0A–0x19) | Hypothesis: outdoor ambient temp as direct integer (10–25 matches session ambient °C) |
| [17] | Reserved | 0x00 | **Confirmed** constant (1540 frames) |
| [18] | **UNKNOWN_A** | 0x61, 0x97, 0xA0–0xA2 (5 values) | Variable across sessions, stable within session |
| [19] | **UNKNOWN_B** | 25 distinct values | Highly variable — possibly a counter or status word |
| [20–28] | Reserved | 0x00 | **Confirmed** constant (1540 frames) |
| [29] | **CRC** | 85 distinct values | Highly variable — almost certainly CRC byte |
| [30] | CRC (original) | Two's complement checksum | Per protocol §3 |
| [31] | EPILOGUE | 0x55 | All sessions |

**Byte [11] — Swing state** (Sessions 7/8):

| Value | Meaning |
|-------|---------|
| 0x00  | Swing off |
| 0x10  | Vertical swing on (up/down) |
| 0x20  | Horizontal swing on (left/right) |

Same encoding as C6 byte[6]. D0 byte[11] is the only place where horizontal
swing is reported in a broadcast/response frame — C0/C3 response byte[20] bit 2
only covers vertical swing.

**Validation across all captures:** D0 byte[11] is 0x00 in all sessions without
swing changes (3–6, 9). Non-zero values appear only in Session 7 (9× 0x10,
4× 0x20 during Phase 6 swing toggle) and Session 8 (34× 0x10, 35× 0x20 during
dedicated swing testing).

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
  4     MASTER_FLAG       Always 0x00 in all own captures (4847 logic analyzer frames Sessions 3–9
                         + 974 dongle frames Sessions 1-2 = 5821 total) and in mdrobnak captures.
                         Codeberg spec claims 0x80 = from master but this is NOT observed on
                         real hardware with KJR-120X wired controllers — **Corrected**.
                         NOTE: ESPHome esphome-mideaXYE-rs485 sets 0x80 in C0/C3 templates
                         (likely from Codeberg spec) but 0x00 in its C6 template — inconsistent
                         within the same codebase. Both 0x00 and 0x80 appear to be accepted
                         by indoor units.
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
  2     SLAVE_FLAG        Always 0x00 in all own captures (5821 frames — logic analyzer + dongle)
                         and in mdrobnak captures. Codeberg spec claims 0x80 = slave->master
                         but this is NOT observed on real hardware — **Corrected**.
  3     DEST_ID           Master address
  4     SRC_ID            Unit address
  5     SRC_ID_repeat     Same as byte 4
  6     MARKER            0x30 (fixed)
  7     CAPABILITIES      0x80=extended temp range, 0x10=swing capable
  8     OPERATING_MODE    Current operating mode (see §5). In Auto mode, response byte includes active sub-mode (§5.2): 0x91=fan, 0x94=heat, 0x98=cool
  9     FAN_SPEED         Fan speed (see §6)
 10     SET_TEMP          Target temperature: raw - 0x40 = °C (e.g. 0x56 = 22 °C) — Confirmed
 11     T1_INDOOR         Follow-Me mode dependent: controller sensor when FM active, indoor thermistor when FM off — formula (raw-40)/2 — Confirmed §0.1, see §7 note
 12     T2A_COIL_IN       Indoor coil inlet — formula (raw-40)/2 — Confirmed §0.1
 13     T2B_COIL_OUT      Indoor coil outlet — formula (raw-40)/2; 0x00 = not reported on this HW
 14     T3_OUTDOOR_COIL   Outdoor coil temperature — formula (raw-40)/2 — Confirmed §0.1
 15     CURRENT           0-99 A (direct value) — **always 0x00 on this HW** — Confirmed (1357 frames, Sessions 3–9). Current draw is only available via UART C1 Group 1 (R-T bus: body[7] outdoor current) or UART C1 Group 4 (WiFi: body[16..18] real-time power)
 16     FREQUENCY         **constant 0xFF** across all 1357 frames (Sessions 3–9)
 17     TIMER_START       Bitmask — **always 0x00** across all 1357 frames. Timer encoding not exercised in any capture.
 18     TIMER_STOP        Bitmask — **always 0x00** across all 1357 frames. 15-min interval hypothesis remains unvalidated.
 19     RUN_STATUS        0x01 = compressor/unit running
 20     MODE_FLAGS        0x02=turbo, 0x01=ECO/sleep, 0x04=vertical swing only (horizontal NOT here — see §0.4a/§0.4b). Cross-bus **Confirmed**: turbo (X-06, 332 pairs PASS), v-swing (X-09, 320 pairs PASS). ECO/sleep not distinguishable (always 0 in captures — ECO never toggled).
 21     OP_FLAGS          0x04=pump running, 0x80=locked — **always 0x00** across all 1357 frames. Pump and lock never activated in captures.
 22     ERROR_1           Error/protection bitmask — **always 0x00** (1357 frames)
 23     ERROR_2           Error/protection bitmask — **always 0x00** (1357 frames)
 24     ERROR_3           Error/protection bitmask — **always 0x00** (1357 frames)
 25     ERROR_4           Error/protection bitmask — **always 0x00** (1357 frames)
 26     COMM_ERROR        0-2 — **always 0x00** (1357 frames)
 27     L1                **constant 0xFF** across all 1357 frames — NOT 0x00 as codeberg README claims (see §0.3)
 28     L2                **constant 0x00** across all 1357 frames — matches codeberg README
 29     L3                **constant 0x00** across all 1357 frames — matches codeberg README
 30     CRC               Two's complement checksum (per Erlang emulator + our dissector)
 31     EPILOGUE          0x55
```

---

## 3. Checksum Algorithm

XYE uses a checksum covering the frame contents. Two equivalent formulations exist:

```
Formulation A (twos complement of inner bytes):
  CRC = (-sum(bytes[1..N-2])) % 256

Formulation B (ones complement of all bytes, used by ESPHome esphome-mideaXYE-rs485):
  CRC = 0xFF - (sum(all bytes except CRC) & 0xFF)
```

These are algebraically identical because preamble (0xAA) + epilogue (0x55) = 0xFF.
Adding 0xFF to the inner sum before ones complement yields the same result as
twos complement of the inner sum alone. Our dissector uses formulation A.

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

## 5. Operating Mode Encoding — **Confirmed** (Sessions 7/8/9)

Byte 0x08 in the slave response (and byte[6] in the 16-byte Set command):

### 5.1 Set command / D0 broadcast mode byte

These frames carry the **user-set mode** only:

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

### 5.2 C0/C3 response mode byte — Auto sub-mode (Sessions 8/9)

In Auto mode, the **slave response** (C0/C3 32-byte) combines the Auto flag
with the actual operating sub-mode. The D0 broadcast and C3 Set request always
use the plain 0x90.

| Response | Meaning | Bit pattern | Evidence |
|----------|---------|-------------|----------|
| `0x10`   | Auto (startup) | `0001 0000` | Not in own captures. ESPHome esphome-mideaXYE-rs485 + rymo C6 response byte[16] |
| `0x91`   | Auto + Fan (idle) | `1001 0001` | Session 9: after cold boot, unit deciding |
| `0x94`   | Auto + Heat | `1001 0100` | Session 8: room < setpoint 30 °C |
| `0x98`   | Auto + Cool | `1001 1000` | Session 8: setpoint jumped to 16 °C, room > setpoint |

The sub-mode can change dynamically: Session 8 at t=237s, dropping setpoint from
28 °C to 16 °C caused 0x94→0x98 within 600 ms. Session 7 at t=583s, switching to
Auto mode showed 0x91 (fan idle) for ~5 s, then transitioned to 0x94 (heating).

**Interpretation:** response_mode = 0x90 | sub_mode_bits, where sub_mode_bits
use the same one-hot encoding as the base modes (0x01=fan, 0x04=heat, 0x08=cool).
This tells the controller what the unit is actually doing, not just what was
requested.

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

**Fan auto sub-modes in responses** (ESPHome esphome-mideaXYE-rs485, confirms mdrobnak Session 7 claim):
When auto is active, the response combines bit 0x80 with the actual speed:

| Value  | Meaning       | Source |
|--------|---------------|--------|
| `0x80` | Auto (idle)   | Own captures + ESPHome + mdrobnak |
| `0x81` | Auto + High   | ESPHome, mdrobnak claim (not in own captures) |
| `0x82` | Auto + Medium | ESPHome, mdrobnak claim (not in own captures) |
| `0x84` | Auto + Low    | ESPHome, mdrobnak claim (not in own captures) |

Same pattern as Auto mode sub-modes in §5.2: response = 0x80 | actual_speed.

**Cross-bus correlation (Session 7, XYE ↔ R-T UART):**

| XYE byte[9] | R-T UART body[3] | Fan speed |
|-------------|------------------|-----------|
| `0x80`      | 102              | Auto |
| `0x04`      | (missed, ~2.5s poll) | Low |
| `0x02`      | (missed)         | Medium |
| `0x01`      | 80               | High |

R-T UART uses integer encoding (20=Silent, 40=Low, 60=Medium, 80=High, 102=Auto).
The R-T bus polls every ~2.5 s, so brief fan speed changes (Low→Medium→High within
seconds) may be missed in R-T data while XYE captures every transition.

R-T also reports `fan=101` during Auto and Dry modes — this may be a variant of
Auto specific to those modes (102=user-set Auto, 101=system-forced Auto).

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
| 0x0B | T1 — Follow-Me room temperature reference | Follow-Me mode dependent value (see note below). See §0.1 for cross-validation. |
| 0x0C | T2A — Indoor coil inlet (evaporator/condenser inlet) | |
| 0x0D | T2B — Indoor coil outlet | 0x00 = not reported on this hardware |
| 0x0E | T3 — Outdoor coil temperature | |

**T1 — Follow-Me mode dependent value:** T1 changes source depending on Follow-Me
state. When Follow-Me is active, T1 reflects the room temperature measured by the
wired controller's (KJR-120M/X) built-in sensor — the value pushed via C6 byte[11].
When Follow-Me is disabled, T1 reverts to the indoor AC unit's own thermistor
reading. Confirmed in logic analyzer Session 7: T1 dropped from 24.0 °C (controller
sensor) to 20.5 °C (indoor thermistor) immediately on FM disable.

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
  6-14  FLAGS             05 00 02 30 0E 00 00 00 00 (mostly constant — byte[14] varies: 0x00 or 0x01)
 15     EXT_STATUS        Own captures: constant 0x00 across all 1,348 C4/C6 responses (Sessions 3–9).
                         mdrobnak (CH-36AHU): 0x20 = normal, 0x60 = emergency heat.
                         bit 0x40 = emergency heat active [Candidate — single source: mdrobnak,
                         not observed in own captures — emergency heat never activated on test unit].
                         mdrobnak values: 0x20 (normal, 3 frames), 0x60 (emergency, 1 frame).
                         Own HW baseline differs (0x00 vs 0x20) — hardware-variant dependent.
 16     OPERATING_MODE    Same encoding as C0 byte[8] (see §5)
 17     FAN_SPEED         Same encoding as C0 byte[9] (see §6)
 18     SET_TEMP          Same encoding as C0 byte[10]: raw - 0x40 = °C
 19     DEVICE_TYPE       Fixed 0xBC = outdoor unit device type. NOT Tp. Previously misidentified
                         as Tp because in Session 6 byte[22] (true Tp) also happened to be 0xBC
                         (Tp=74°C → raw=0xBC) — a coincidence. Constant across all sessions.
 20     UNKNOWN           Constant 0xD6 (87°C if sensor formula) — identity unknown
 21     T4                Outdoor ambient: (raw-40)/2 = °C — Confirmed Session 6 (T4=4°C, raw≈0x30)
 22     Tp                Compressor discharge temperature: (raw-40)/2 = °C
                         Confirmed by cross-session comparison with UART R/T C1-G1 body[14]:
                         329 matched pairs, mean diff = −0.02°C, max |diff| = 3°C (timing).
                         Session 6: byte[22]=0xBC→74°C = service menu Tp=74°C ✓
 23     RESERVED          0x00 in all own and external captures
 24     SP_READBACK       Own captures: constant 0x00 (107 C6 responses, Sessions 3–9).
                         rymo: 0x2N where N = static pressure level (0x20=SP0 .. 0x24=SP4)
                         [Candidate — single source: rymo, external-captures/02_rymo_static_pressure].
 25-29  RESERVED          All zeros in all own and external captures
 30     CRC               Two's complement checksum
 31     EPILOGUE          0x55
```

Session 7 confirmed: byte[19] (device-type `0xBC`) and byte[20] (unknown `0xD6`) are
constant across all modes. Byte[21] (T4) drifts ±1°C with ambient.
Byte[22] is Tp (compressor discharge temperature), confirmed: 329 matched pairs across
Sessions 3–8 vs UART R/T C1-G1, mean diff −0.02°C. Byte[22] varies 30–74°C with
compressor load, not with mode — confirms it is a thermal sensor, not a control field.

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
- **Current draw** — byte 0x0F, direct Ampere value (always 0x00 on tested HW — see §2.2)
- **Follow-Me** — room temperature from a remote sensor (cmd `0xC6`)
- **Static pressure control** — for ventilation/duct applications
- **Emergency heat** mode
- **Lock / Unlock** — disable/enable local remote control (`0xCC` / `0xCD`)

---

## 11. Open Questions — Setpoint / Temperature Encoding Variants

The setpoint byte encoding differs across hardware and sources. The sensor
temperature formula `(raw - 40) / 2 = °C` is consistent across all sources,
but the setpoint byte (C3 command byte[8], C0 response byte[10]) shows at
least two variants plus an unresolved Fahrenheit mechanism.

### C3 command byte[8] — setpoint sent TO unit

**Confirmed (own captures):** `raw - 0x40 = °C`. Range 0x50-0x5E = 16-30°C,
validated against Session 7 operator notes (full 16-30°C sweep).

**Consistent:** mdrobnak C3 Celsius commands use same encoding (0x56=22°C, 0x57=23°C).

**Fahrenheit hypothesis (mdrobnak Session 5, 4 frames):**
- Celsius values: 0x56/0x57/0x58 (bit 7 clear)
- Fahrenheit values: 0xCB/0xCF (bit 7 set)
- If bit 7 = Fahrenheit flag: `raw & 0x7F` = direct °F (0xCB → 75°F, 0xCF → 79°F)
- Plausible but only 4 frames from single source, no ground truth.

### C0/C3 response byte[10] — setpoint echoed FROM unit

**Variant A (own HW):** Response echoes command encoding. 0x50-0x5E, same range as
commands. `raw - 0x40 = °C`. Confirmed 1,357 frames.

**Variant B (mdrobnak HW):** Response returns direct °C with no offset.
0x15=21°C, 0x16=22°C, 0x18=24°C. Different encoding from commands on same unit.

### ESPHome esphome-mideaXYE-rs485 temperature bugs

ESPHome sends raw Fahrenheit values (e.g. 70, 86) as byte[8] without any
conversion or bit 7 flag. It displays response byte[10] as °F without applying
`raw - 0x40`. Users report it "works" but temperature accuracy issues are common.

Possible explanations (unresolved):
1. **Accidental roundtrip**: On Variant A HW, the unit echoes the raw value back,
   so the display roundtrips (86 in → 86 out) even though the unit interprets it
   as 22°C not 86°F. User sees correct display but wrong actual temperature.
2. **Range-based auto-detect**: The unit firmware may interpret values > ~50 as
   Fahrenheit and < ~50 as Celsius without needing bit 7. This would explain
   why ESPHome works and why mdrobnak's unit returns direct °C in responses.
3. **Firmware variant**: Different indoor unit firmware versions may handle the
   encoding differently.

**Cannot be resolved without controlled testing:** Set a known temperature via XYE,
verify with a physical thermometer or the wired controller display.

---

## 12. Planned Experiments

- [ ] **Change XYE unit address** — modify DEST_ID/SRC_ID fields via dongle to
      observe bus behavior, KJR-120X response, and polling pattern changes.
      Clarifies the address bytes (2-5) which are always 0x00 in current captures.

- [ ] **Toggle relay on MFB-C adapter board** — capture XYE bus traffic during
      relay activation. Determine how the adapter communicates relay state to the
      indoor unit and what XYE command/response carries the relay control.

- [ ] **Toggle relay on MFB-X adapter board** — same relay test on the HAHB
      variant for cross-bus comparison.

- [ ] **Controlled setpoint test** — set a known temperature via XYE, verify with
      wired controller display and physical thermometer. Resolves the §11 encoding
      variant questions (raw-0x40 vs direct vs Fahrenheit auto-detect).

- [ ] **Fahrenheit mode test** — switch KJR-120X display to °F, capture C3 commands
      during setpoint changes. Verify if bit 7 of byte[8] is the °C/°F flag, what
      values the controller sends, and how the unit responds (byte[10] encoding).

---

## References

- XYE reverse engineering: https://codeberg.org/xye/xye
- ESPHome XYE implementation: https://github.com/wtahler/esphome-mideaXYE-rs485
- HA Community XYE thread: https://community.home-assistant.io/t/midea-a-c-via-local-xye/857679
- Discoveries from mill1000/midea-msmart (`midea-msmart-mill1000.md`)
- georgezhao2010/midea_ac_lan — device type definitions (0xC3/0xCC/0xCD/0xCF)
- Midea UART reference: [protocol_uart.md](protocol_uart.md)
- UART vs. XYE comparison: [comparison_uart_vs_xye.md](comparison_uart_vs_xye.md)
