# HVAC-shark

Open-source protocol analysis toolkit for Midea HVAC systems. Captures, decodes,
and dissects the internal communication buses of Midea air conditioning units for
reverse-engineering and research purposes.

## Disclaimer and intended use

This code is provided for research and educational purposes only. There is absolutely
no warranty that it works as intended. Use of this code should not encourage anyone
to work on their HVAC systems, as doing so carries risks of personal injury or
property damage. The author is not responsible for any harm or damage resulting
from the use of this code.

This repository aggregates information that is publicly available on the internet
for research and debugging purposes. If anyone feels offended or has a problem with
the mention of brand names, please contact me directly. The mentioned brand names
are not owned by me, nor am I affiliated with them.

## Components

| Component | Path | Description |
|-----------|------|-------------|
| Wireshark Lua dissector | `wireshark_dissectors/` | Dissects HVAC_shark UDP frames in Wireshark |
| ESP32 / Python dongle | `dongle/mid-xye/` | Live-capture firmware + Python serial-to-UDP bridge |
| Protocol reference docs | `protocol-analysis/` | Reverse-engineered protocol documentation |

## Currently supported protocols

- **mid-xye** — Midea XYE RS-485 inter-unit bus (4800 baud, 16/32-byte frames)

## Repository layout

```
wireshark_dissectors/   Lua dissector loaded into Wireshark
dongle/mid-xye/         ESP32 firmware + Python serial-to-UDP bridge
  mid_xye/              Arduino project (PlatformIO)
  py-mid-xye/           Python equivalent bridge
protocol-analysis/      Protocol reference documents and comparison notes
```

## Companion repository: HVAC-shark-dumps

Capture sessions, raw logic-analyser exports, and session documentation live in a
separate repository to keep binary data out of the main codebase:

**[HVAC-shark-dumps](https://github.com/fabcoded/HVAC-shark-dumps)**

Contents:
- `.pcap` files converted from Saleae logic-analyser exports, ready to open in Wireshark
- Raw Saleae CSV exports and `.sal` session files
- `SessionNotes.md` (operator logs) and `findings.md` (analysis results) per session
- `channels.yaml` configuration files used by the offline pcap converter

Each device has its own subfolder (e.g. `Midea-extremeSaveBlue-display/`) with a
README describing the hardware, captured buses, and session index.

The offline pcap converter (`logicanalyzer-tools/logic_analyzer_midea_to_pcap.py`)
lives in the dumps repository next to the data it processes.

## Conventions

- **Temperature**: all temperature values are in **°C (Celsius)** unless explicitly
  noted otherwise in the relevant file or field description.

## Contributing

Contributions are welcome! Please submit a pull request or open an issue to discuss your ideas.

## Acknowledgements

A huge thank you to the open-source and home-automation community — especially the
contributors around **Home Assistant**, **ESPHome**, and the broader maker community —
for their tireless reverse-engineering work and for publishing their findings openly.

Projects that made this research possible:
- [crankyoldgit/IRremoteESP8266](https://github.com/crankyoldgit/IRremoteESP8266)
- [dudanov/MideaUART](https://github.com/dudanov/MideaUART)
- [chemelli74/midea-local](https://github.com/chemelli74/midea-local)
- [reneklootwijk/node-mideahvac](https://github.com/reneklootwijk/node-mideahvac)
- [codeberg.org/xye/xye](https://codeberg.org/xye/xye)
- [wtahler/esphome-mideaXYE-rs485](https://github.com/wtahler/esphome-mideaXYE-rs485)
- The countless forum threads, GitHub issues, and pull requests in the HA and ESPHome communities

If you believe your work is referenced here without proper attribution, if you would
like code or findings removed, or if you have any licensing concerns, please open an
issue or get in touch directly via this GitHub repository. We will respond promptly.

## For AI agents

AI agents working in this repository should follow the instructions in
[AGENTS.md](AGENTS.md). Unless otherwise advised by the repository owner,
`AGENTS.md` is the authoritative guide for coding style, working conventions,
protocol documentation standards, and confidence labelling.
