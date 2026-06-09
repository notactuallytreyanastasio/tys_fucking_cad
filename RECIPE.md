# The Recipe — you do almost nothing

Total effort: type two words, pick two files, click once.

## One-time setup (once, ever)

Get `dotnet/CableReportPlugin/bin/Release/CableReportPlugin.dll` onto the
Windows machine (anywhere — Desktop is fine).

## Every time you want the cable report

In the AutoCAD Electrical command line:

```
NETLOAD
```
→ pick `CableReportPlugin.dll`.

```
CABLEREPORT
```
→ it asks **Project/Folder** — type `P` and pick your `.wdp`
   (or `F` and pick any drawing in the folder).

Then it does the whole thing itself: walks every drawing in the background
(nothing opens on screen), picks up each main cable component, reads its
stored data — tag, part number, location, every wire/color/pin, spares —
holds it in memory, and when it's done it asks one question:

→ **Place report on [Current drawing/File]** — type `C`, **click once**
   where you want the top-left corner.

Blocks appear, one per cable, command ends. That's the entire job.
No data files, no exports, no second command, no editing anything.

## If the attribute names don't match your blocks

First run looks wrong (empty fields, missing cables)? Run `CABLECENSUSNET`
once instead — same picks, zero clicks — and send back the
`attribute-census.csv` it drops next to your drawings. The `Config` block
gets corrected to your shop's real attribute tags and you get a new DLL.

## To skip even the NETLOAD step in future sessions

Drop the DLL in a folder
`%APPDATA%\Autodesk\ApplicationPlugins\CableReport.bundle\Contents\` with the
`PackageContents.xml` from `dotnet/README.md` — it auto-loads every session.
