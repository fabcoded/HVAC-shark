# AGENTS.md — HVAC-shark

> This file is read automatically by AI coding agents (Claude Code, Cursor, Copilot,
> Windsurf, and others that honour `AGENTS.md` or `CLAUDE.md`). It sets the ground
> rules for working in this repository.

## Project overview

HVAC-shark is an open-source protocol analysis toolkit for HVAC systems.
It captures, decodes, and dissects the internal communication buses of air
conditioning units for reverse-engineering and research purposes. Currently
focused on Midea/Carrier family protocols.

Components:
- Wireshark Lua dissector (`wireshark_dissectors/HVAC-shark_mid-xye.lua`)
- ESP32 / Python live-capture dongle (`dongle/mid-xye/`)
- Offline pcap converter for Saleae logic-analyser exports (in the dumps repo)

## Target audience

This project is used by professionals with strong backgrounds in both software
engineering and microelectronics/embedded systems. Do not over-explain basic
concepts (serial protocols, bit manipulation, pcap format, Lua, C++, etc.).

## Working style

**Ask before assuming.** This codebase involves undocumented proprietary
protocols where a wrong assumption leads to incorrect dissectors or corrupt
captures. When the intent of a change is not completely clear:

1. Ask for clarification before writing any code.
2. If the first answer is still ambiguous, ask again with a more specific
   follow-up question. Do not proceed on a guess.
3. Only implement what was explicitly requested. Do not add features,
   refactor surrounding code, or "improve" things that were not mentioned.

**Follow the terms of use and license terms of each source.** Check terms and licenses for each source and after each use of a source to ensure that you have complied with the terms of use and licenses.

**Minimal changes.** Protocol decoders are built incrementally as more
captures become available. A partial decoder with clearly marked unknowns
(`TBD`,`FIXME`, `?`) is better than a complete-looking decoder built on guesses.

**Document uncertainty explicitly.** When a field encoding is inferred from
only one or two data points, label it as such in both code comments and any
markdown documentation. Use the session `SessionNotes.md` files as ground
truth for validating decoded values against known actions.

**Best-effort analysis — note all controversies.** Protocol documentation in
this project is built from captures, open-source references, and community
notes — never from an official Midea specification. When sources disagree,
**always state the conflict explicitly** rather than silently picking one.
Use the following labels consistently:

| Label           | Meaning                                                             |
|-----------------|---------------------------------------------------------------------|
| **Confirmed**   | Multiple independent data points, or hardware verified              |
| **Consistent**  | Own captures + at least one source agree                            |
| **Hypothesis**  | Own data only, no source conflict, but not independently verified   |
| **Disputed**    | Sources disagree with each other or with own captures               |
| **Unknown**     | Insufficient data to form a hypothesis                              |

When updating documentation: do not silently upgrade a label. If a field
moves from Hypothesis to Confirmed, record what new evidence confirmed it.

## Conventions

- **Temperature**: all values are in **°C (Celsius)** unless a field description explicitly states otherwise.
- **Confidence labels**: see the table in the Working style section above — use them in both code comments and markdown docs.

## Protocol constants

HVAC_shark UDP framing (port 22222):

| Offset | Size | Field          | Values                                      |
|--------|------|----------------|---------------------------------------------|
| 0      | 10   | Magic          | `HVAC_shark` (ASCII)                        |
| 10     | 1    | Manufacturer   | `0x01` = Midea                              |
| 11     | 1    | Bus type       | `0x00`=XYE, `0x01`=UART, `0x02`=disp-mb, `0x03`=r-t, `0x04`=IR |
| 12     | 1    | Header version | `0x00`=legacy, `0x01`=extended              |
| 13+    | var  | Metadata       | len-prefixed: channel name, board, comment  |
| ...    | var  | Protocol data  | bus-specific payload                        |

Bus type `0x04` (IR) payload: 6 decoded bytes per frame (NEC-like encoding,
active-low TSOP receiver). See `SessionNotes.md` in session folders for
known field mappings.

## Local toolchain

### tshark / Wireshark

`tshark` is available at `C:\Program Files\Wireshark\tshark.exe` (Wireshark 4.4.2,
verified 2026-03-21). The HVAC-shark Lua dissector is symlinked into
`%APPDATA%\Wireshark\plugins\` and is loaded automatically by both Wireshark
and tshark — no `-X lua_script:` flag needed.

**Before using tshark in a session**, verify the path is still valid:
```
"C:/Program Files/Wireshark/tshark.exe" --version
```
If that fails, ask the user where tshark is installed before proceeding.

Invoke tshark with forward slashes or double-escaped backslashes in bash
(the shell is bash even on Windows):
```bash
TSHARK="C:/Program Files/Wireshark/tshark.exe"
"$TSHARK" -r session.pcap -V 2>&1 | head -50
```
