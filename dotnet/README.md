# CableReportPlugin — the one-command .NET version

No LISP, no two-step dance, no data file. `NETLOAD` once, run `CABLEREPORT`,
done.

## Commands

| Command | What it does |
|---|---|
| `CABLEREPORT` | Pick **Project** (.wdp) or **Folder** → every drawing is batch-read through side databases (nothing visibly opens; drawings already open in any tab are read live) → pick the target (**Current** drawing or any **File**) → one summary block per cable is placed → command ends. If the target file isn't open, the blocks are written into it and it's saved in place. |
| `CABLECENSUSNET` | Same batch scan, but dumps every attributed block's tag/value pairs to `attribute-census.csv` and prints which attributes look like cable identifiers. Run this first; send the CSV back to lock `Config` to your real blocks. |

## How the output blocks work (instance vs. definition)

There is exactly **one** block definition, `CBLRPT`, created once in the
target drawing and never edited afterwards. Every cable gets its own placed
**instance** of that block, and all per-cable data is written into the
instance's attribute values (AttributeReferences) — never into the
definition. Editing attributes inside the definition would change every
placed copy in the drawing at once (the failure mode where one edit shows
up in all the drawers); this plugin structurally cannot do that.

The definition has `Config.MaxConductorRows` (default 24) conductor rows;
unused rows stay blank on each instance, and a cable with more conductors
truncates with a printed WARNING.

## Block layout (per cable instance, top to bottom)

Cable name, cable tag, part number (MFG + CAT), location, separator,
`WIRE | COLOR + PIN` column header, one row per conductor (wire number left;
color + pin right; spares rendered as `SPARE … (unpopulated)` /
`landed: <pin>` / `(slot n)`), separator, conductor accounting line,
tag-convention verdict (`Tag = highest wire no: convention holds.` or
`DOES NOT hold`), and the source sheets.

Pin numbers are read from the **cable component's own attributes** — in
current AcadE, pins are assigned on the cable component, not on wires.
(A legacy harvest that pulls pins off terminal/connector blocks by shared
wire number exists behind `Config.HarvestPinsFromWireLinks`, default off,
for drawing sets that still store pins the old way.) Row order is never
inferred from wire-number order.

## Build (Windows or Mac, .NET 8 SDK+)

```
cd dotnet/CableReportPlugin
dotnet build -c Release
```

Output: `bin/Release/CableReportPlugin.dll`. The AutoCAD assemblies come from
the `AutoCAD.NET` NuGet package at compile time only (`ExcludeAssets=runtime`)
— AutoCAD itself provides them when the DLL is loaded.

## Load in AutoCAD Electrical 2026

- Per session: `NETLOAD`, browse to `CableReportPlugin.dll`.
- Permanent, no admin, no store: create
  `%APPDATA%\Autodesk\ApplicationPlugins\CableReport.bundle\` containing the
  DLL and a `PackageContents.xml` that points at it — auto-loads every
  session (see TECHNIQUES.md).
- If SECURELOAD complains, add the folder to Options → Files → Trusted
  Locations.

## Config

All attribute-tag assumptions are in the `Config` class at the top of
`CableReportCommand.cs` (identifier tags, `CBL*` pattern, header/conductor
families, spare tokens, block geometry). Run `CABLECENSUSNET` against real
drawings and adjust to match before trusting production output.

## Known limitations

- Extraction is attribute-based: data must live on the cable component's
  attributes. Geometric association (reading which wire a marker sits on)
  is not built.
- No catalog lookup, so "deleted attribute" spares can't be inferred from CAT.
- Model space only.
- A cable with more conductors than `Config.MaxConductorRows` truncates
  (with a warning) rather than growing the block.
