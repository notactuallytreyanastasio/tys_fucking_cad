# Advanced Techniques — the stuff that isn't in the obvious docs

Verified against Autodesk docs, the Autodesk Community forums, and Nate Holt's
blog (Holt was the original AutoCAD Electrical developer — his posts are the
closest thing to the secret manual that exists in public). Each section says
what's verified vs. what needs checking on a real install.

## 1. AcadE's internal `wd_dbx_*` API — the one that changes everything

AutoCAD Electrical ships its own AutoLISP API for batch-processing drawings in
the background. This is what AcadE itself uses for project-wide operations.
Verified function names (from Nate Holt's project-wide attribute updater):

| Function | What it does |
|---|---|
| `wd_dbx_open` | Open a drawing in the background (no window) |
| `wd_dbx_ssget` | Selection set inside that background drawing |
| `wd_dbx_entnext` | Walk sub-entities — i.e. the ATTRIBs of an INSERT |
| `wd_dbx_entget` | Read entity data (DXF group lists) |
| `wd_dbx_entmod` | Write modified entity data back |
| `wd_dbx_close` | Close, with optional save |
| `wd_wdp_get_proj_file_lsts` | **The active project's drawing list** — no .wdp parsing heuristics needed |
| `wd_pdwgs_main_withhelp` | AcadE's own "select drawings from project" dialog |

Also verified to exist: `c:wd_proj_wdp_data` (active project's WDP data as a
list, first element = the .wdp filename), `c:ace_add_dwg_to_project`,
`wd_tb_process_one` (title-block processing per drawing).

**Why this matters for CableReport:** `CABLESCAN`'s raw ObjectDBX code
(`vla-GetInterfaceObject "ObjectDBX.AxDbDocument.25"`) and the hand-rolled
`.wdp` parser are both replaceable with the native `wd_dbx_*` + 
`wd_wdp_get_proj_file_lsts` calls — fewer moving parts, and the drawing list
comes from AcadE itself, including subfolders and ordering. v2 should offer
both engines: `wd_dbx_*` when running inside AcadE, raw ObjectDBX as fallback
on plain AutoCAD.

**Where the real secret manual lives:** AcadE ships a large amount of its own
machinery as *plain-text .lsp source* in the install tree (under
`C:\Program Files\Autodesk\AutoCAD 2026\Acade\Support` and the user support
paths). Searching those files for `wd_dbx_` / `wd_wdp_` / `wd_pdwgs` gives the
actual signatures and usage examples on your exact version. That's the
authoritative reference — better than any forum post.

## 2. Running LISP without APPLOAD

APPLOAD isn't an option in this shop. Every one of these works without it:

1. **Type it at the command line** — `(load "C:/path/CableCensus.lsp")` typed
   (or pasted) straight into the command line loads the file for the current
   session. No dialog, no setting, nothing to install.
2. **AcadE Project-Wide Utilities** (Project tab → Project Tools → Utilities)
   — has a field that accepts a one-line LISP expression instead of a script
   file. Enter `(load "C:/path/extract.lsp")` and AcadE itself opens every
   selected project drawing, runs it, and closes — **this is a complete
   alternative batch engine for CABLESCAN that needs no ObjectDBX at all.**
   The .lsp just needs to end with `(c:yourcommand)` `(princ)` so it
   self-executes on load. Use forward slashes or doubled backslashes in the
   path.
3. **Per-drawing auto-load** — an `acaddoc.lsp` placed in a support-path
   folder loads automatically in every drawing that opens. Good for making
   the commands permanently available without anyone loading anything.
4. **Autoloader bundle** — a folder named `whatever.bundle` dropped in
   `%APPDATA%\Autodesk\ApplicationPlugins` with a small `PackageContents.xml`
   auto-loads LISP or .NET DLLs at startup. Per-user, no admin rights, no
   store purchase — this is the polished "put a file in place and it just
   works" deployment.
5. **NETLOAD** — for the C#/.NET plugin variant, `NETLOAD path\to\plugin.dll`
   per session, or the same .bundle mechanism to make it automatic.

## 3. accoreconsole.exe — headless AutoCAD

`accoreconsole.exe` (in the AutoCAD install folder) is AutoCAD's drawing
engine with no GUI: starts in under a second, ~100 MB RAM, batch-processes
drawings several times faster than full AutoCAD:

```
accoreconsole.exe /i "SHEET-04.dwg" /s "extract.scr"
```

with a one-loop PowerShell/batch wrapper feeding it every DWG in a folder.

**The critical caveat:** core console has **no COM/ActiveX**, so `vla-*`
functions — including all of ObjectDBX and likely the `wd_dbx_*` wrappers —
do not work, and dialogs don't exist (commands must be the hyphen-prefixed
command-line variants). A core-console extractor must be pure AutoLISP:
`ssget "X"` for the INSERTs, `entnext`/`entget` for the ATTRIBs, append to a
CSV per run. That's a clean, fast architecture — arguably *simpler* than
ObjectDBX — and it runs with zero AutoCAD windows. Worth building as the v2
scan engine if Project-Wide Utilities is awkward to standardize on.

## 4. DATAEXTRACTION — the no-code path that's actually real

Plain AutoCAD's `DATAEXTRACTION` wizard extracts block attributes **from
multiple drawings or whole folders at once** into CSV/XLSX, no code involved.
As a calibration tool it does the same job as CABLECENSUS: run it over a few
sheets, include all blocks with attributes, and the resulting spreadsheet
shows every block name + attribute tag in the wild. Slower to drive than
CABLECENSUS but requires loading nothing.

## 5. What's still unverified (deliberately not stated as fact)

- Exact argument signatures of the `wd_dbx_*` functions — read them out of
  the shipped `Acade\Support` .lsp sources on the real install.
- How AcadE associates cable child markers with the wire they sit on
  (geometric/XDATA linkage) — relevant only if the attribute data turns out
  not to carry wire numbers on children (the B1 scenario in EXAMPLES.md).
- The AcadE catalog/project scratch database layout — not needed for the
  attribute-based v1.

## Sources

- [Nate Holt — How to execute a Lisp function, all dwgs / project-wide](https://nateholt.wordpress.com/2009/08/13/how-to-execute-a-lisp-function-all-dwgs-project-wide-autocad-electrical/)
- [Nate Holt — Project-wide attribute value updater](https://nateholt.wordpress.com/2009/07/27/project-wide-attribute-value-updater-autocad-electrical/)
- [Nate Holt — Programmatically adding active dwg to active project](https://nateholt.wordpress.com/2011/02/12/programmatically-adding-active-dwg-to-active-project-autocad-electrical/)
- [Autodesk forums — AutoCAD Electrical c: commands from Lisp](https://forums.autodesk.com/t5/autocad-electrical-forum/autocad-electrical-c-commands-from-lisp/td-p/8556283)
- [Autodesk — AutoCAD Electrical API overview](https://aps.autodesk.com/developer/overview/autocad-electrical-api)
- [Autodesk — About the Project .WDP File](https://knowledge.autodesk.com/support/autocad-electrical/learn-explore/caas/CloudHelp/cloudhelp/2017/ENU/AutoCAD-Electrical/files/GUID-FD3F36A0-01B7-44D2-8B73-81721934A6BD-htm.html)
- [Autodesk Developer Blog — Getting started with AccoreConsole](https://blog.autodesk.io/getting-started-with-accoreconsole/)
- [Tek1 — How to load lisp files in AcCoreConsole](https://www.tek1.com.au/autocaddotnetapi/load-lisp-files-accoreconsole/)
- [FDES — AccoreConsole: headless CAD automation guide](https://fdestech.com/resources/accoreconsole-guide-headless-cad-automation/)
