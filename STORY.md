# The Story So Far — Cable Report Tool

*Last updated: June 9, 2026, ~6:30 PM — workflow still running (implementation phase)*

## The Problem

Ty has a ton of AutoCAD Electrical 2026 drawings, and scattered across them are
cables. Each cable is a component sitting on wires, and the component carries
attribute data: the cable's numbering, its location, where it needs to go, the
conductor colors, each wire within the cable, the pin numbering, and whether
each pin actually gets a wire landed on it or sits spare.

The ask: a tool that opens every drawing in turn, pulls all the cable component
data, closes the drawing, and then — once everything is collected — lets him
pick one target drawing and drops the whole dataset onto it as AutoCAD
Electrical blocks. Each block reads top to bottom:

1. Cable name
2. Cable tag
3. Cable part number
4. Location
5. Then a two-column table: wire numbers on one side, color + pin on the other

The command only ends once every block is placed. Preference was AutoLISP,
with C#/.NET via NETLOAD as the fallback.

## The Naming Scheme

Cables are named `CBL-<number>`, where the number is *usually* the highest
wire number in the cable's vertical stack of wires. Example: a cable carrying
wires 1000, 1001, 1002 is `CBL-1002`, with 1000 on pin 1, 1001 on pin 2,
1002 on pin 3.

**The critical wrinkle:** "usually" is doing a lot of work in that sentence.
Pin order is sometimes mixed, so the tool can never infer a pin from wire
number order — it has to read the actual pin assignment stored in the block
attributes, every time. This single fact shaped the whole design.

## Decisions Made

All of this is tracked in the deciduous decision graph (goal #76):

- **Two approaches considered:** AutoLISP with ObjectDBX batch reads (#78)
  vs. a C# .NET plugin with side databases (#79). ObjectDBX lets LISP read
  drawings without visibly opening them; .NET is more robust but needs a
  build toolchain and a DLL to NETLOAD.
- **Chose AutoLISP (#80)** — it was Ty's stated preference, it's
  APPLOAD-able with zero build steps, and the main Lisp pain point
  (wrangling attribute data) is mitigated by putting every attribute-tag
  assumption in one editable CONFIG section.
- **Two-command flow, not one:** a LISP command cannot survive switching
  documents, so the tool splits into `CABLESCAN` (batch-extract everything
  to a data file) and `CABLEPLACE` (run inside the chosen target drawing to
  place the blocks). A third command, `CABLEDUMP`, prints every attribute
  tag/value of a selected block — that's the discovery tool for locking the
  config to the real block structure.

## What's Been Built (so far)

Ty said to invent realistic examples of the problem rather than wait on his
screenshots, and asked for a multi-agent workflow. The workflow
(`cable-report-tool`, run `wf_d2e0b957-1e5`) has five phases:

| Phase | Status | What happened |
|-------|--------|---------------|
| Examples | ✅ Done | Four agents in parallel invented scenarios from different angles: typical sequential cables (a 3-conductor Belden 8770, wires 1000–1002 → pins 1–3, `CBL-1002`), scrambled pin maps (`CBL-2041`, a 4-conductor control cable PNL-3 → MCC-1 where wire order ≠ pin order), spare/unpopulated pins, and the different block structures AcadE shops use (stock parent+child cable markers, single custom blocks with numbered PIN1/WIRE1/COLOR1 attributes, cables spanning multiple drawings). |
| Design | ✅ Done | Synthesized the scenarios into `EXAMPLES.md` (~24 KB) — which doubles as the acceptance spec, with each scenario's expected summary-block output — plus a design brief covering the data model, default attribute-tag config, parent/child grouping by shared cable tag, cross-drawing merging, spare-pin representation, and pin-numeric row sorting. |
| Implement | 🔄 Running | An agent is writing `CableReport.lsp` (the three commands) and `README.md` right now. |
| Review | ⏳ Pending | Three adversarial reviewers queued: AutoLISP correctness, ObjectDBX/AcadE pitfalls (ProgID versioning, per-file document lifecycle, active-drawing collision), and spec compliance — including hand-walking an EXAMPLES.md scenario through the code. |
| Fix | ⏳ Pending | Applies whatever the reviewers confirm. |

### Files in this directory

- `EXAMPLES.md` — synthetic but realistic cable scenarios + expected outputs (done)
- `CableReport.lsp` — the tool itself (being written)
- `README.md` — usage, APPLOAD instructions, CONFIG knobs, limitations (being written)
- `STORY.md` — this file

## A Glitch Worth Noting

The workflow's directory argument didn't interpolate into the agent prompts —
it arrived as the literal string `"undefined"` (the args object was passed
JSON-encoded instead of as a raw object). The design agent noticed and
recovered by writing to the actual working directory, which was correct, and
the implementation prompt carries the full requirements inline so nothing
essential was lost. Still being watched: after the workflow finishes, verify
all files landed here and re-run the review if the reviewers tripped on the
bogus path.

## Getting Creative (the CABLEDUMP problem)

Ty can't run CABLEDUMP on a real cable — so the calibration plan inverted:
instead of him clicking a block, the tooling discovers everything itself.

- **`CableCensus.lsp` / `CABLECENSUS`** — zero-config discovery. One command
  batch-reads every drawing (project or folder, nothing visibly opens),
  dumps every attributed block to `attribute-census.csv`, prints a per-block
  tag summary with sample values, flags which block/attribute combos hold
  values matching `CBL*`, and prints the suggested CONFIG line for
  CableReport.lsp. Nobody ever has to know an attribute tag name up front.
- **`tools/make_test_dxfs.py` + `test_drawings/`** — six synthetic DXF sheets
  (SHEET-04/07/09/10/11/12) mirroring every EXAMPLES.md scenario: happy-path
  markers, the CABLENO/XREF tag variant, the scrambled-pin CBL-2041, tag ≠
  highest wire (CBL-1300, with trap wire 1185), all three spare flavors, the
  19-pin MIL connector with deleted attributes and an end-mismatch, the
  single-block schedule (CBL-318), and the cross-sheet CBL-412/413 dedupe
  case. Verified by round-trip read: groupings come back correct. Open in
  AutoCAD, SAVEAS to .dwg, and the whole pipeline is testable with zero real
  drawings.
- **No-code fallbacks documented** for getting real attribute data without
  any LISP: AutoCAD's built-in DATAEXTRACTION wizard (batches multiple
  drawings to CSV/XLSX), AcadE's built-in reports (Cable Summary / From-To
  exports), saving one representative drawing as DXF and sending it, or just
  sending the block-editor screenshots.

## What Happens Next

1. Workflow finishes → verify files, summarize review findings, log the
   outcome node in the decision graph.
2. **The big unblocker is on Ty's side, and it no longer requires clicking
   anything:** APPLOAD `CableCensus.lsp`, run `CABLECENSUS`, pick the project
   or folder, and send back `attribute-census.csv` (or any of the no-code
   fallbacks above). Every attribute tag in the CONFIG section is currently
   an educated guess based on stock AcadE conventions (`CABLENO`, `TAG1`,
   `WIRENO`, `LOC`, `CAT`...) — the census locks it to reality.
3. Confirm how drawings are enumerated in his shop — AcadE project file
   (`.wdp`) or plain folder of DWGs. Both paths are implemented.
4. Test against a real drawing set, fix what reality breaks.
