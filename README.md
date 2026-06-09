# Cable Report — AutoCAD Electrical 2026

Batch-reads every drawing in a project/folder, picks up each **main cable
component's** stored data (tag, part number, location, every wire / color /
pin, spares), and places one summary block per cable on a drawing you choose.
One command, in memory, no intermediate files.

**Start here → [RECIPE.md](RECIPE.md)** — the type-two-words-click-once
instructions.

| What | Where |
|---|---|
| The tool (.NET plugin, `CABLEREPORT` + `CABLECENSUSNET`) | `dotnet/CableReportPlugin/` |
| Prebuilt DLL | `dotnet/CableReportPlugin/bin/Release/CableReportPlugin.dll` |
| Acceptance spec / example scenarios | `EXAMPLES.md` |
| Verified AcadE internals (wd_dbx_* API, loading without APPLOAD, accoreconsole) | `TECHNIQUES.md` |
| Synthetic test drawings + generator | `test_drawings/`, `tools/make_test_dxfs.py` |
| How this project evolved | `STORY.md` |
| Deprecated LISP version (two-command flow with a data file — retired) | `legacy-lisp/` |

## Ground rules baked into the tool (from the shop's reality)

- Pins are assigned on the **cable component only** — never on wires, never
  inferred from wire-number order (orders are sometimes mixed).
- Only the **main marker** is read; its component data carries the conductor
  list. No child-marker collection, no cross-reference (XREF) tags.
- Cables live on **one drawing** (Ethernet runs are the rare exception).
- Cables can have **any number of pins** (18-pin cables exist here; numbered
  attribute families parse multi-digit suffixes; report block holds 36 rows
  and warns on truncation).
- Output is **one shared block definition** (`CBLRPT`); every cable is a
  placed instance with its own attribute values. The definition is never
  edited after creation, so a value change can never propagate across
  instances.
- Cable names: `CBL-<number>`, number usually the highest wire number in the
  cable — the report prints whether the convention holds per cable.
