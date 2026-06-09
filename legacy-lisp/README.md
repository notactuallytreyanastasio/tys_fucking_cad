# Cable Report Tool for AutoCAD Electrical 2026

`CableReport.lsp` extracts cable data (tag, description, part number, location,
and per-conductor wire / color / pin rows) from an entire AutoCAD Electrical
drawing set **without opening the drawings on screen**, then places one
formatted, attribute-driven report block per cable in whatever drawing you
choose. The acceptance spec with 11 worked scenarios lives in
[`EXAMPLES.md`](EXAMPLES.md) — read it to see exactly what the report format
and grouping rules are supposed to produce.

Three commands, run in this order:

| Command | Where | What it does |
|---|---|---|
| `CABLEDUMP` | any drawing with a real cable block | Prints a block's effective name and every attribute `TAG = value` |
| `CABLESCAN` | any open drawing | Batch-scans a project (.wdp) or folder via ObjectDBX, writes `cable-data.lsp` |
| `CABLEPLACE` | the **target** drawing | Reads `cable-data.lsp`, entmakes one report block per cable |

## Step 0 — CABLEDUMP first. Seriously.

The CONFIG section ships with defaults covering the stock AcadE marker
families seen in EXAMPLES.md (`TAG1`, `CABLENO`, `TAG2`, `TAGXREF`, `XREF`,
`WIRENO`, `COLOR`, `TERMxx`, `PINxx`, ...). **Your block library almost
certainly differs.** Before trusting any scan:

1. Open a drawing that contains a real cable.
2. Run `CABLEDUMP`, click the **parent** cable marker. Copy the output.
3. Run it again on a **child/conductor** marker, and on a terminal or
   connector that carries pin numbers.
4. Paste those dumps back (to whoever is maintaining the tool / into the
   chat) so the CONFIG lists can be locked to your real attribute tags.

Nothing else in the tool is trustworthy until CONFIG matches reality.

## Loading the tool (no APPLOAD required)

APPLOAD is not available in every shop. Any of these works instead
(see TECHNIQUES.md for detail):

1. **Command line** — type or paste directly into AutoCAD's command line:
   `(load "C:/path/to/CableReport.lsp")`
   (forward slashes or doubled backslashes). Loads for the current session.
2. **AcadE Project-Wide Utilities** (Project tab > Project Tools >
   Utilities) — accepts a one-line LISP expression such as the same
   `(load ...)`; AcadE runs it in every selected project drawing.
3. **Auto-load every session** — put an `acaddoc.lsp` containing the
   `(load ...)` line in a support-path folder, or drop a `.bundle` folder
   with a `PackageContents.xml` into
   `%APPDATA%\Autodesk\ApplicationPlugins` (per-user, no admin rights).

After loading you should see: `CableReport.lsp loaded. Commands: CABLEDUMP,
CABLESCAN, CABLEPLACE`.

If your security settings block loading, add the folder to *Options >
Files > Trusted Locations* (or set `SECURELOAD` appropriately per your CAD
manager's policy).

## Step 1 — CABLESCAN

Run `CABLESCAN` from any open drawing. You get a keyword prompt:

```
Scan source [Project/Folder] <Folder>:
```

- **Project** — pick your AcadE `.wdp` project file. The drawing list is
  parsed from it: directive lines starting with `+ = ? * ; [ ~` are skipped,
  every other line is treated as a drawing path, relative paths are resolved
  against the `.wdp` folder, and `.dwg` is appended when missing.
- **Folder** — pick *any* DWG inside the folder you want scanned; every
  `*.dwg` in that folder is processed.

Each drawing is opened invisibly through **ObjectDBX**
(`ObjectDBX.AxDbDocument.25` on 2026 — the major version is taken from
`ACADVER`, so the same file works on other releases). If a file in the list
is already open in your session (**any** tab, not just the active one), it
is scanned through that open document instead, because ObjectDBX cannot
open an in-use file. Unreadable files are reported and skipped, never
fatal, and pressing Esc mid-scan releases the ObjectDBX document cleanly.

What counts as a cable component: any attributed block reference in model
space where one of the configured cable-tag attributes (`CABLENO`, `TAGXREF`,
`TAG2`, `XREF`, `TAG1` by default) holds a value matching the configured
pattern (default `CBL*`). All blocks sharing the same tag value merge into
one cable record — **exact string match, project-wide, across drawings**:

- header fields (DESC/MFG/CAT/LOC) fill in from whichever block has them
  first (parent markers win because children usually carry none);
- a parent marker that carries its own COLOR/WIRENO contributes conductor #1
  (it is a conductor, not just a header — see EXAMPLES.md A1/A4);
- conductor rows dedupe by **(cable tag, wire number)** across drawings:
  the same wire seen with different attribute completeness merges into one
  row, blank color/pin fields filling in field-wise (continuation markers,
  duplicated wire segments). Blank-wire and spare rows merge only when
  literally identical;
- numbered attribute families (`WIRE1/COLOR1/PIN1` ... `WIRE12/...`) on
  single-block cable schedules are enumerated and zipped by **numeric**
  suffix (PIN10 after PIN9), so the D1 pattern in EXAMPLES.md works too;
- all-blank numbered slots whose pin attribute exists on the insert are
  kept as **unpopulated** spares (C1-style `TERM09..12 = ""`), and spare
  tokens in the wire field are classified as **landed** spares;
- pins are also picked up from **non-cable blocks** (terminal symbols,
  schedules) that carry a wire number and a pin on the same insert —
  e.g. `HT0_001` with `WIRENO=1000` + `TERM01=1` fills `TB1:1` into the
  matching conductor of whatever cable owns wire 1000;
- source drawings are tracked per cable.

You get a per-drawing progress line, a final summary table (tag, conductor
count, drawings), and the results are persisted with `prin1` into
**`cable-data.lsp`** next to the `.wdp` / inside the scanned folder.

## Step 2 — CABLEPLACE

Open the drawing where the report should live and run `CABLEPLACE`. Pick the
data file, then a top-left insertion point.

For each cable the tool **entmakes a unique block definition** named
`CBLRPT_<sanitized tag>` (suffixed `_1`, `_2`... if the name already exists)
containing one ATTDEF per text cell, laid out top to bottom:

```
CABLE: <description>
TAG:   <cable tag>
PART:  <MFG> <CAT>
LOC:   <location>
-----------------------------------------------
WIRE        COLOR + PIN                <- two columns: wire at x=0,
<wire>      <color>  pin <pin>            color/pin at the configured offset
<wire>      <color>  TB1:3              <- terminations merged from terminal blocks
<wire>      <color>  (no pin data)
SPARE       --  pin 9  (unpopulated)   <- empty pin attribute on the insert
SPARE       <color>  landed: <pin>     <- spare token in the wire field
SPARE       <color>  (slot 11)         <- schedule slot with color, no wire
-----------------------------------------------
<n> of <n> conductors assigned.        <- or "N conductors, U used, S spare."
Tag = highest wire no (1002): convention holds.   <- verified, never assumed
```

Numeric pins sort numerically (`distof`, so 10 > 9); non-numeric pins sort
by contact sequence (case-insensitive string order); on a mixed cable the
numeric pins lead and pin-less rows keep extraction order at the end. Pin
order is **never** inferred from wire numbers — see EXAMPLES.md B1/B2 for
why that rule exists. The closing tag-convention line appears whenever the
tag has trailing digits and at least one all-digit wire number was found.

Each block is inserted with `entmake` (`INSERT` with `66 . 1`, one `ATTRIB`
per cell positioned at insertion point + local offset, closed by `SEQEND`).
Cables stack downward; when a column would exceed the configured max height
the next cable starts a new column to the right. The command finishes only
after every cable is placed and prints the count. Because everything is an
attribute, you can edit any value afterwards with `ATTEDIT`/double-click.

### Why two commands?

A LISP command cannot survive switching documents — the moment the active
drawing changes, the running command's execution context is gone. So
extraction (`CABLESCAN`) writes everything to a data file, and placement
(`CABLEPLACE`) is a separate command you run *in* the target drawing. This
also means you can re-place the same scan into several drawings, or re-scan
without touching the report drawing.

## CONFIG knobs

All tunables live in the clearly marked CONFIG section at the top of
`CableReport.lsp`:

| Variable | Default | Meaning |
|---|---|---|
| `cbl:cfg-cable-tag-atts` | `("CABLENO" "TAGXREF" "TAG2" "XREF" "TAG1")` | Attribute tags that may hold the cable identifier (parent ids + child cross-refs). First non-empty match wins. |
| `cbl:cfg-cable-pattern` | `"CBL*"` | `wcmatch` pattern a value must match to count as a cable tag. Comma-separate alternatives (`"CBL*,W-*"`). Case-insensitive. |
| `cbl:cfg-name-atts` | `("DESC1" "DESC2" "DESC3")` | Cable description attributes. |
| `cbl:cfg-mfg-atts` / `cbl:cfg-cat-atts` / `cbl:cfg-loc-atts` | `("MFG")` / `("CAT")` / `("LOC")` | Part number and location attributes. |
| `cbl:cfg-wire-prefixes` | `("WIRENO" "WIRE")` | Wire-number tag prefixes. Bare tag and numbered (`WIRE1..n`) both work. **Keep longest-first.** |
| `cbl:cfg-color-prefixes` | `("COLOR" "CLR")` | Conductor color tag prefixes. |
| `cbl:cfg-pin-prefixes` | `("TERMNO" "TERM" "PIN")` | Pin/terminal tag prefixes (`TERM01..nn`, bare `PIN`, ...). **Keep longest-first.** |
| `cbl:cfg-spare-tokens` | `("SPARE" "SP")` | Wire-field values meaning "spare" (case-insensitive, trimmed). Applied to the wire field only — a pin *named* `S`/`SP` stays a pin. |
| `cbl:cfg-data-file` | `"cable-data.lsp"` | Name of the persisted scan file. |
| `cbl:cfg-text-height` | `0.09375` | ATTDEF text height (drawing units). |
| `cbl:cfg-row-factor` | `1.6` | Line spacing = height x factor. |
| `cbl:cfg-col2-offset` | `1.25` | X offset of the COLOR/PIN column. |
| `cbl:cfg-block-gap-rows` | `2.0` | Blank rows between stacked cable blocks. |
| `cbl:cfg-max-col-height` | `22.0` | Column wraps when it would exceed this height. |
| `cbl:cfg-col-spacing` | `6.0` | X distance between report columns. |
| `cbl:cfg-layer` | `"0"` | Layer for the generated text entities. |

## Current assumptions and limitations

- **Model space only.** Paper-space and nested (block-in-block) inserts are
  not scanned.
- **Attribute-based extraction only.** Wire/color/pin data is read from
  attributes on the cable-tagged blocks, plus pins from any block that
  carries a wire number and a pin **on the same insert** (terminal symbols
  like `HT0_001`, schedule blocks) — these merge into the owning cable's
  conductors by shared wire number. The geometric work — pairing a
  connector's `TERMxx` pin with the wire whose endpoint it touches,
  following `SIGCODE` source/destination arrows across sheets, picking up
  wire numbers from `WD_WNH` blocks for inline markers that carry no
  `WIRENO` — is **not implemented yet**. That is the machinery EXAMPLES.md
  group B and parts of A/C exercise; until it lands, device-side pins
  (e.g. `TERM01=+` on a transmitter with no `WIRENO`) won't appear in rows,
  and inline children without `WIRENO` render as `(no wire no)` rows.
- **Spare handling distinguishes two of the three flavors.** Unpopulated
  pins (a pin attribute exists on a cable-tagged insert but the slot is
  blank) render `SPARE  --  pin <n>  (unpopulated)`; spare tokens in the
  wire field render `SPARE  <color>  landed[: <pin>]`; D1-style schedule
  slots with a color but no wire render `SPARE  <color>  (slot <n>)`.
  The third flavor — pins *deleted* from the insert and known only from a
  catalog lookup (C3 in EXAMPLES.md) — needs a catalog table and is not
  produced yet.
- **`.wdp` parsing is heuristic.** Lines starting with `+ = ? * ; [ ~` are
  treated as directives and skipped; everything else is assumed to be a
  drawing path. Exotic project files may need the Folder mode instead.
- **Exact-match grouping.** `CBL-412` and `CBL-413` are different cables;
  there is no prefix/fuzzy matching, by design.
- **Wire numbers and pins are strings throughout** (`412T1`, `SPARE`, `+`,
  `AI1` are all valid); nothing is ever int-parsed except for sorting checks
  via `distof`.
- ObjectDBX reads the drawing as saved on disk — unsaved edits in drawings
  open in another session are invisible. Read-only access; scanned drawings
  are never modified.

## Files

- `CableReport.lsp` — the tool (all three commands, CONFIG at top).
- `EXAMPLES.md` — normative scenarios + acceptance rules. The target spec.
- `cable-data.lsp` — generated by `CABLESCAN`, consumed by `CABLEPLACE`.
