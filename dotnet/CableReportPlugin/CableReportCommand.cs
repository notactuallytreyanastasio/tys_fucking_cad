// CableReportPlugin — single-command cable extraction + summary block placement
// for AutoCAD Electrical 2026 (NETLOAD).
//
//   CABLEREPORT  — pick Project (.wdp) or Folder, batch-scan every drawing via
//                  side databases (nothing visibly opens), then pick the target
//                  drawing (current or any file) and place one summary block per
//                  cable. The command ends only after all blocks are placed.
//
//   CABLECENSUSNET — same batch scan, but dumps every attributed block's
//                  tags/values to attribute-census.csv and suggests CONFIG.
//
// Attribute-tag assumptions live in Config below — lock them to reality with
// the census before trusting a production run.

using System.Text;
using System.Text.RegularExpressions;
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.DatabaseServices;
using Autodesk.AutoCAD.EditorInput;
using Autodesk.AutoCAD.Geometry;
using Autodesk.AutoCAD.Runtime;
using AcApp = Autodesk.AutoCAD.ApplicationServices.Application;

[assembly: CommandClass(typeof(CableReportPlugin.Commands))]

namespace CableReportPlugin;

public static class Config
{
    // Attributes that can hold a cable identifier (parent or child), exact tags.
    public static readonly string[] IdentifierAttrs =
        { "CABLENO", "TAG1", "TAG2", "TAGXREF", "XREF", "TAG" };

    // A value must match this wildcard to count as a cable tag.
    public const string CablePattern = "CBL*";

    // Header fields: first non-empty value wins.
    public static readonly string[] NameAttrs = { "DESC1", "CBLNAME", "NAME" };
    public static readonly string[] MfgAttrs = { "MFG" };
    public static readonly string[] CatAttrs = { "CAT", "PARTNO", "PART" };
    public static readonly string[] LocAttrs = { "LOC", "LOCATION" };

    // Per-conductor attribute families: bare tag or tag+number (WIRENO, WIRE3...).
    // Longest prefixes first so WIRENO wins over WIRE.
    public static readonly string[] WirePrefixes = { "WIRENO", "WNO", "WIRE" };
    public static readonly string[] ColorPrefixes = { "COLOR", "CLR" };
    public static readonly string[] PinPrefixes = { "TERMNO", "TERM", "PINL", "PIN" };

    // Context tag for terminal-strip style pin harvest ("TB1:3").
    public static readonly string[] PinContextAttrs = { "TAGSTRIP", "TAG1" };

    public static readonly string[] SpareTokens = { "SPARE", "SP" };

    // Pins are assigned on the cable component itself in current AcadE.
    // The legacy pins-on-terminal-blocks harvest (matched by shared wire
    // number) is OFF unless a drawing set actually stores pins that way.
    public static readonly bool HarvestPinsFromWireLinks = false;

    // The single shared report block definition has this many conductor rows;
    // unused rows stay blank on the instance. Cables with more conductors are
    // truncated with a warning.
    public const int MaxConductorRows = 24;

    // Output block geometry (drawing units).
    public const double TextHeight = 0.125;
    public const double RowFactor = 1.6;
    public const double Col2Offset = 2.0;   // x offset of the COLOR + PIN column
    public const double BlockSpacingX = 5.5;
    public const double MaxColumnHeight = 18.0;
}

public sealed class ConductorRow
{
    public string Wire = "";
    public string Color = "";
    public string Pin = "";
    public int Slot;                // numbered-family suffix, 0 = bare
    public string Flavor = "";      // "", "LANDED", "UNPOP"
    public bool IsSpare => Flavor.Length > 0 ||
        Config.SpareTokens.Contains(Wire.Trim().ToUpperInvariant());
}

public sealed class CableRecord
{
    public string Tag = "";
    public string Name = "";
    public string Mfg = "";
    public string Cat = "";
    public string Loc = "";
    public readonly List<ConductorRow> Rows = new();
    public readonly SortedSet<string> Sheets = new(StringComparer.OrdinalIgnoreCase);

    public string Part => $"{Mfg} {Cat}".Trim();
}

public sealed class ScanResult
{
    public readonly Dictionary<string, CableRecord> Cables = new(StringComparer.OrdinalIgnoreCase);
    // wire number -> pin designations harvested from terminal/connector blocks
    public readonly Dictionary<string, List<string>> PinsByWire = new(StringComparer.OrdinalIgnoreCase);
    public int DrawingsScanned;
    public readonly List<string> Skipped = new();
}

public class Commands
{
    // ------------------------------------------------------------------
    // CABLEREPORT — the whole job in one command
    // ------------------------------------------------------------------
    [CommandMethod("CABLEREPORT", CommandFlags.Session)]
    public static void CableReport()
    {
        var doc = AcApp.DocumentManager.MdiActiveDocument;
        if (doc == null) return;
        var ed = doc.Editor;

        var files = PromptDrawingList(ed);
        if (files == null || files.Count == 0)
        {
            ed.WriteMessage("\nNothing to scan.");
            return;
        }

        var result = ScanAll(ed, files);
        ed.WriteMessage($"\n\nScanned {result.DrawingsScanned} drawing(s), " +
                        $"{result.Cables.Count} cable(s), " +
                        $"{result.Cables.Values.Sum(c => c.Rows.Count)} conductor row(s).");
        foreach (var s in result.Skipped) ed.WriteMessage($"\n  skipped: {s}");
        if (result.Cables.Count == 0) return;

        if (Config.HarvestPinsFromWireLinks) ApplyHarvestedPins(result);
        var warnings = new List<string>();

        // ---- target selection ----
        var kw = new PromptKeywordOptions("\nPlace report on [Current drawing/File]", "Current File")
        { AllowNone = false };
        var kr = ed.GetKeywords(kw);
        if (kr.Status != PromptStatus.OK) return;

        int placed;
        if (kr.StringResult == "Current")
        {
            var pr = ed.GetPoint("\nTop-left insertion point: ");
            if (pr.Status != PromptStatus.OK) return;
            using (doc.LockDocument())
            using (var tr = doc.Database.TransactionManager.StartTransaction())
            {
                placed = PlaceAll(doc.Database, tr, result, pr.Value, warnings);
                tr.Commit();
            }
        }
        else
        {
            var fr = ed.GetFileNameForOpen(new PromptOpenFileOptions("Select target drawing")
            { Filter = "Drawing (*.dwg)|*.dwg" });
            if (fr.Status != PromptStatus.OK) return;
            string target = fr.StringResult;

            var openDoc = FindOpenDocument(target);
            if (openDoc != null)
            {
                using (openDoc.LockDocument())
                using (var tr = openDoc.Database.TransactionManager.StartTransaction())
                {
                    placed = PlaceAll(openDoc.Database, tr, result, new Point3d(1.0, Config.MaxColumnHeight + 1.0, 0), warnings);
                    tr.Commit();
                }
                ed.WriteMessage($"\n{target} is open in this session — placed into the open document (unsaved).");
            }
            else
            {
                using var db = new Database(false, true);
                db.ReadDwgFile(target, FileOpenMode.OpenForReadAndWriteNoShare, true, null);
                using (var tr = db.TransactionManager.StartTransaction())
                {
                    placed = PlaceAll(db, tr, result, new Point3d(1.0, Config.MaxColumnHeight + 1.0, 0), warnings);
                    tr.Commit();
                }
                db.SaveAs(target, DwgVersion.Current);
                ed.WriteMessage($"\nSaved {target}.");
            }
        }

        foreach (var w in warnings) ed.WriteMessage($"\nWARNING: {w}");
        ed.WriteMessage($"\nCABLEREPORT complete: {placed} summary block(s) placed.");
    }

    // ------------------------------------------------------------------
    // CABLECENSUSNET — attribute discovery, no config needed
    // ------------------------------------------------------------------
    [CommandMethod("CABLECENSUSNET", CommandFlags.Session)]
    public static void CableCensus()
    {
        var doc = AcApp.DocumentManager.MdiActiveDocument;
        if (doc == null) return;
        var ed = doc.Editor;

        var files = PromptDrawingList(ed);
        if (files == null || files.Count == 0)
        {
            ed.WriteMessage("\nNothing to scan.");
            return;
        }

        var csv = new StringBuilder("drawing,block,tag,value\r\n");
        var stats = new Dictionary<(string Block, string Tag), (int Count, List<string> Samples)>();
        var cableTags = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        int scanned = 0;

        foreach (var f in files)
        {
            ed.WriteMessage($"\nScanning {Path.GetFileName(f)} ...");
            try
            {
                WithDrawing(f, (db, tr) =>
                {
                    foreach (var (blockName, attrs) in AttributedInserts(db, tr))
                        foreach (var (tag, val) in attrs)
                        {
                            csv.Append($"{CsvEsc(Path.GetFileName(f))},{CsvEsc(blockName)},{CsvEsc(tag)},{CsvEsc(val)}\r\n");
                            var key = (blockName, tag);
                            if (!stats.TryGetValue(key, out var st)) st = (0, new List<string>());
                            st.Count++;
                            if (val.Trim().Length > 0 && st.Samples.Count < 3 && !st.Samples.Contains(val))
                                st.Samples.Add(val);
                            stats[key] = st;
                            if (WildcardMatch(val, Config.CablePattern)) cableTags.Add(tag);
                        }
                });
                scanned++;
            }
            catch (System.Exception ex)
            {
                ed.WriteMessage($" SKIPPED ({ex.Message})");
            }
        }

        string outPath = Path.Combine(Path.GetDirectoryName(files[0]) ?? ".", "attribute-census.csv");
        File.WriteAllText(outPath, csv.ToString());

        ed.WriteMessage($"\n\n================ ATTRIBUTE CENSUS ({scanned} drawings) ================");
        foreach (var grp in stats.GroupBy(kv => kv.Key.Block).OrderBy(g => g.Key))
        {
            ed.WriteMessage($"\n\nBLOCK: {grp.Key}");
            foreach (var kv in grp.OrderBy(kv => kv.Key.Tag))
                ed.WriteMessage($"\n   {kv.Key.Tag}  (x{kv.Value.Count})" +
                    (kv.Value.Samples.Count > 0 ? $"   e.g. {string.Join(" | ", kv.Value.Samples)}" : ""));
        }
        if (cableTags.Count > 0)
            ed.WriteMessage($"\n\nLikely cable identifier attribute(s): {string.Join(", ", cableTags)}");
        ed.WriteMessage($"\n\nFull dump: {outPath}\nSend that CSV back to lock the Config to your real blocks.\n");
    }

    // ------------------------------------------------------------------
    // Scanning
    // ------------------------------------------------------------------

    static List<string>? PromptDrawingList(Editor ed)
    {
        var kw = new PromptKeywordOptions("\nScan drawings from [Project/Folder]", "Project Folder")
        { AllowNone = false };
        var kr = ed.GetKeywords(kw);
        if (kr.Status != PromptStatus.OK) return null;

        if (kr.StringResult == "Project")
        {
            var fr = ed.GetFileNameForOpen(new PromptOpenFileOptions("Select AcadE project file")
            { Filter = "AcadE project (*.wdp)|*.wdp" });
            return fr.Status == PromptStatus.OK ? ParseWdp(fr.StringResult) : null;
        }
        else
        {
            var fr = ed.GetFileNameForOpen(new PromptOpenFileOptions("Pick ANY drawing in the folder to scan")
            { Filter = "Drawing (*.dwg)|*.dwg" });
            if (fr.Status != PromptStatus.OK) return null;
            string dir = Path.GetDirectoryName(fr.StringResult)!;
            return Directory.EnumerateFiles(dir, "*.dwg", SearchOption.TopDirectoryOnly)
                            .OrderBy(p => p, StringComparer.OrdinalIgnoreCase).ToList();
        }
    }

    static List<string> ParseWdp(string wdpPath)
    {
        // Heuristic: drawing entries are lines not starting with a directive char.
        var dir = Path.GetDirectoryName(wdpPath)!;
        var files = new List<string>();
        foreach (var raw in File.ReadLines(wdpPath))
        {
            var line = raw.Trim();
            if (line.Length == 0 || "+=?*;[~".Contains(line[0])) continue;
            if (!line.EndsWith(".dwg", StringComparison.OrdinalIgnoreCase)) line += ".dwg";
            files.Add(Path.IsPathRooted(line) ? line : Path.GetFullPath(Path.Combine(dir, line)));
        }
        return files;
    }

    static ScanResult ScanAll(Editor ed, List<string> files)
    {
        var result = new ScanResult();
        foreach (var f in files)
        {
            ed.WriteMessage($"\nScanning {Path.GetFileName(f)} ...");
            if (!File.Exists(f)) { result.Skipped.Add($"{f} (missing)"); continue; }
            try
            {
                WithDrawing(f, (db, tr) => ScanDatabase(db, tr, Path.GetFileName(f), result));
                result.DrawingsScanned++;
            }
            catch (System.Exception ex)
            {
                result.Skipped.Add($"{Path.GetFileName(f)} ({ex.Message})");
            }
        }
        return result;
    }

    /// Runs `action` against the drawing's database: the live database when the
    /// file is open in this session (any tab, not just the active one),
    /// otherwise a read-only side database. Side databases never show a window.
    static void WithDrawing(string path, Action<Database, Transaction> action)
    {
        var openDoc = FindOpenDocument(path);
        if (openDoc != null)
        {
            using var tr = openDoc.Database.TransactionManager.StartTransaction();
            action(openDoc.Database, tr);
            tr.Commit();
            return;
        }
        using var db = new Database(false, true);
        db.ReadDwgFile(path, FileOpenMode.OpenForReadAndAllShare, true, null);
        using (var tr = db.TransactionManager.StartTransaction())
        {
            action(db, tr);
            tr.Commit();
        }
    }

    static Document? FindOpenDocument(string path)
    {
        string full = Path.GetFullPath(path);
        foreach (Document d in AcApp.DocumentManager)
            if (string.Equals(Path.GetFullPath(d.Name), full, StringComparison.OrdinalIgnoreCase))
                return d;
        return null;
    }

    static IEnumerable<(string BlockName, List<(string Tag, string Value)> Attrs)>
        AttributedInserts(Database db, Transaction tr)
    {
        var bt = (BlockTable)tr.GetObject(db.BlockTableId, OpenMode.ForRead);
        var ms = (BlockTableRecord)tr.GetObject(bt[BlockTableRecord.ModelSpace], OpenMode.ForRead);
        foreach (ObjectId id in ms)
        {
            if (tr.GetObject(id, OpenMode.ForRead, false, true) is not BlockReference br) continue;
            if (br.AttributeCollection.Count == 0) continue;

            string name;
            try
            {
                var btrId = br.IsDynamicBlock ? br.DynamicBlockTableRecord : br.BlockTableRecord;
                name = ((BlockTableRecord)tr.GetObject(btrId, OpenMode.ForRead)).Name;
            }
            catch { name = "?"; }

            var attrs = new List<(string, string)>();
            foreach (ObjectId aid in br.AttributeCollection)
                if (tr.GetObject(aid, OpenMode.ForRead, false, true) is AttributeReference ar)
                    attrs.Add((ar.Tag.ToUpperInvariant(), ar.TextString));
            yield return (name, attrs);
        }
    }

    static void ScanDatabase(Database db, Transaction tr, string sheet, ScanResult result)
    {
        foreach (var (_, attrList) in AttributedInserts(db, tr))
        {
            var attrs = new Dictionary<string, string>();
            foreach (var (tag, val) in attrList)
                if (!attrs.ContainsKey(tag)) attrs[tag] = val;

            string? cableTag = Config.IdentifierAttrs
                .Select(t => attrs.GetValueOrDefault(t, ""))
                .FirstOrDefault(v => WildcardMatch(v, Config.CablePattern));

            if (cableTag != null)
                AbsorbCableBlock(cableTag, attrs, sheet, result);
            else
                HarvestPins(attrs, result);
        }
    }

    static void AbsorbCableBlock(string tag, Dictionary<string, string> attrs, string sheet, ScanResult result)
    {
        if (!result.Cables.TryGetValue(tag, out var rec))
            result.Cables[tag] = rec = new CableRecord { Tag = tag };
        rec.Sheets.Add(sheet);

        rec.Name = FillIfEmpty(rec.Name, First(attrs, Config.NameAttrs));
        rec.Mfg = FillIfEmpty(rec.Mfg, First(attrs, Config.MfgAttrs));
        rec.Cat = FillIfEmpty(rec.Cat, First(attrs, Config.CatAttrs));
        rec.Loc = FillIfEmpty(rec.Loc, First(attrs, Config.LocAttrs));

        foreach (var row in RowsFromAttrs(attrs))
            MergeRow(rec, row);
    }

    /// Conductor slots from one insert: bare family (slot 0) plus numbered
    /// families (slot N). Keeps all-blank slots when a pin attribute physically
    /// exists (flavor UNPOP); classifies spare tokens (flavor LANDED).
    static IEnumerable<ConductorRow> RowsFromAttrs(Dictionary<string, string> attrs)
    {
        var slots = new Dictionary<int, ConductorRow>();
        var pinAttrExists = new HashSet<int>();

        foreach (var (tag, val) in attrs)
        {
            if (TryFamily(tag, Config.WirePrefixes, out int s)) Slot(slots, s).Wire = val;
            else if (TryFamily(tag, Config.ColorPrefixes, out s)) Slot(slots, s).Color = val;
            else if (TryFamily(tag, Config.PinPrefixes, out s))
            {
                Slot(slots, s).Pin = val;
                pinAttrExists.Add(s);
            }
        }

        foreach (var (slot, row) in slots.OrderBy(kv => kv.Key))
        {
            row.Slot = slot;
            bool blankWire = row.Wire.Trim().Length == 0;
            bool blankAll = blankWire && row.Color.Trim().Length == 0 && row.Pin.Trim().Length == 0;
            bool spareToken = Config.SpareTokens.Contains(row.Wire.Trim().ToUpperInvariant());

            if (spareToken) row.Flavor = "LANDED";
            else if (blankWire && pinAttrExists.Contains(slot)) row.Flavor = "UNPOP";

            if (blankAll && !pinAttrExists.Contains(slot)) continue; // nothing there at all
            yield return row;
        }
    }

    static ConductorRow Slot(Dictionary<int, ConductorRow> slots, int s)
        => slots.TryGetValue(s, out var r) ? r : slots[s] = new ConductorRow();

    static bool TryFamily(string tag, string[] prefixes, out int slot)
    {
        foreach (var p in prefixes)
            if (tag.StartsWith(p, StringComparison.Ordinal))
            {
                var rest = tag[p.Length..];
                if (rest.Length == 0) { slot = 0; return true; }
                if (rest.All(char.IsAsciiDigit)) { slot = int.Parse(rest); return true; }
            }
        slot = -1;
        return false;
    }

    /// Dedupe/merge per EXAMPLES.md rule 4: rows with a real wire number merge
    /// by wire number, field-wise filling blanks; blank/spare rows need literal
    /// identity to collapse.
    static void MergeRow(CableRecord rec, ConductorRow row)
    {
        bool realWire = row.Wire.Trim().Length > 0 && !row.IsSpare;
        if (realWire)
        {
            var hit = rec.Rows.FirstOrDefault(r =>
                string.Equals(r.Wire.Trim(), row.Wire.Trim(), StringComparison.OrdinalIgnoreCase));
            if (hit != null)
            {
                hit.Color = FillIfEmpty(hit.Color, row.Color);
                hit.Pin = FillIfEmpty(hit.Pin, row.Pin);
                if (hit.Slot == 0) hit.Slot = row.Slot;
                return;
            }
        }
        else if (rec.Rows.Any(r => r.Wire == row.Wire && r.Color == row.Color &&
                                   r.Pin == row.Pin && r.Slot == row.Slot))
        {
            return;
        }
        rec.Rows.Add(row);
    }

    /// Terminal/connector blocks carry the pins but no cable tag. When a block
    /// has exactly one non-empty wire value, every non-empty pin value on it
    /// belongs to that wire (HT0_001: WIRENO=1000, TERM01=1 -> "TB1:1").
    static void HarvestPins(Dictionary<string, string> attrs, ScanResult result)
    {
        var wires = new List<string>();
        var pins = new List<string>();
        foreach (var (tag, val) in attrs)
        {
            if (val.Trim().Length == 0) continue;
            if (TryFamily(tag, Config.WirePrefixes, out _)) wires.Add(val.Trim());
            else if (TryFamily(tag, Config.PinPrefixes, out _)) pins.Add(val.Trim());
        }
        if (wires.Distinct(StringComparer.OrdinalIgnoreCase).Count() != 1 || pins.Count == 0) return;

        string ctx = First(attrs, Config.PinContextAttrs);
        foreach (var p in pins)
        {
            string pin = ctx.Length > 0 ? $"{ctx}:{p}" : p;
            if (!result.PinsByWire.TryGetValue(wires[0], out var list))
                result.PinsByWire[wires[0]] = list = new List<string>();
            if (!list.Contains(pin, StringComparer.OrdinalIgnoreCase)) list.Add(pin);
        }
    }

    static void ApplyHarvestedPins(ScanResult result)
    {
        foreach (var rec in result.Cables.Values)
            foreach (var row in rec.Rows)
                if (row.Pin.Trim().Length == 0 && row.Wire.Trim().Length > 0 &&
                    result.PinsByWire.TryGetValue(row.Wire.Trim(), out var pins))
                    row.Pin = string.Join(" / ", pins);
    }

    // ------------------------------------------------------------------
    // Placement
    // ------------------------------------------------------------------

    const string ReportBlockName = "CBLRPT";

    static int PlaceAll(Database db, Transaction tr, ScanResult result, Point3d topLeft, List<string> warnings)
    {
        double rowH = Config.TextHeight * Config.RowFactor;
        var defId = EnsureReportBlockDef(db, tr);
        double x = topLeft.X, y = topLeft.Y;
        int placed = 0;

        foreach (var rec in result.Cables.Values.OrderBy(c => c.Tag, StringComparer.OrdinalIgnoreCase))
        {
            var values = InstanceValues(rec, warnings, out int contentRows);
            double height = (9 + contentRows) * rowH;
            if (y < topLeft.Y && y - height < topLeft.Y - Config.MaxColumnHeight)
            {
                x += Config.BlockSpacingX;
                y = topLeft.Y;
            }
            InsertInstance(db, tr, defId, new Point3d(x, y, 0), values);
            y -= height + rowH;
            placed++;
        }
        return placed;
    }

    /// ONE shared block definition (CBLRPT), created once and never edited
    /// afterwards. All per-cable data goes into each placed instance's
    /// AttributeReferences — never into the definition's AttributeDefinitions,
    /// which would change every insert of the block project-wide.
    static ObjectId EnsureReportBlockDef(Database db, Transaction tr)
    {
        var bt = (BlockTable)tr.GetObject(db.BlockTableId, OpenMode.ForRead);
        if (bt.Has(ReportBlockName)) return bt[ReportBlockName];

        bt.UpgradeOpen();
        var def = new BlockTableRecord { Name = ReportBlockName, Origin = Point3d.Origin };
        var defId = bt.Add(def);
        tr.AddNewlyCreatedDBObject(def, true);

        double rowH = Config.TextHeight * Config.RowFactor;
        double y = 0;
        const string sep = "-----------------------------------";

        void Attr(string tag, double xOff)
        {
            var ad = new AttributeDefinition(new Point3d(xOff, y, 0), "", tag, tag, db.Textstyle)
            { Height = Config.TextHeight, LockPositionInBlock = true };
            def.AppendEntity(ad);
            tr.AddNewlyCreatedDBObject(ad, true);
        }
        void Text(string s, double xOff)
        {
            var t = new DBText
            {
                Position = new Point3d(xOff, y, 0),
                TextString = s,
                Height = Config.TextHeight,
                TextStyleId = db.Textstyle,
            };
            def.AppendEntity(t);
            tr.AddNewlyCreatedDBObject(t, true);
        }
        void Next() => y -= rowH;

        Attr("CBLNAME", 0); Next();
        Attr("CBLTAG", 0); Next();
        Attr("PARTNO", 0); Next();
        Attr("LOC", 0); Next();
        Text(sep, 0); Next();
        Text("WIRE", 0); Text("COLOR + PIN", Config.Col2Offset); Next();
        for (int i = 1; i <= Config.MaxConductorRows; i++)
        {
            Attr($"W{i}", 0);
            Attr($"D{i}", Config.Col2Offset);
            Next();
        }
        Text(sep, 0); Next();
        Attr("COUNT", 0); Next();
        Attr("VERDICT", 0); Next();
        Attr("SHEETS", 0);

        return defId;
    }

    static Dictionary<string, string> InstanceValues(CableRecord rec, List<string> warnings, out int contentRows)
    {
        var v = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["CBLNAME"] = rec.Name.Length > 0 ? rec.Name : rec.Tag,
            ["CBLTAG"] = rec.Tag,
            ["PARTNO"] = rec.Part.Length > 0 ? rec.Part : "(none on marker)",
            ["LOC"] = rec.Loc,
            ["VERDICT"] = TagConventionVerdict(rec),
            ["SHEETS"] = $"Sheets: {string.Join(", ", rec.Sheets)}",
        };

        var rows = SortRows(rec.Rows);
        if (rows.Count > Config.MaxConductorRows)
            warnings.Add($"{rec.Tag}: {rows.Count} conductors, only the first " +
                         $"{Config.MaxConductorRows} fit the report block — raise Config.MaxConductorRows.");

        int i = 0, used = 0, spare = 0;
        foreach (var r in rows)
        {
            string wireCell, detail;
            if (r.Flavor == "UNPOP")
            {
                spare++;
                wireCell = "SPARE";
                detail = $"--  pin {(r.Pin.Trim().Length > 0 ? r.Pin : r.Slot.ToString())}  (unpopulated)";
            }
            else if (r.IsSpare)
            {
                spare++;
                wireCell = "SPARE";
                detail = r.Pin.Trim().Length > 0 ? $"{r.Color}  landed: {r.Pin}"
                       : r.Wire.Trim().Length == 0 ? $"{r.Color}  (slot {r.Slot})"
                       : $"{r.Color}";
            }
            else
            {
                used++;
                wireCell = r.Wire;
                detail = r.Pin.Trim().Length > 0 ? $"{r.Color}  {r.Pin}" : $"{r.Color}  (no pin data)";
            }
            if (i < Config.MaxConductorRows)
            {
                v[$"W{i + 1}"] = wireCell;
                v[$"D{i + 1}"] = detail.Trim();
            }
            i++;
        }

        v["COUNT"] = spare == 0 ? $"{used} of {used} conductors assigned."
                                : $"{used + spare} conductors, {used} used, {spare} spare.";
        contentRows = Math.Min(rows.Count, Config.MaxConductorRows);
        return v;
    }

    static string TagConventionVerdict(CableRecord rec)
    {
        var m = Regex.Match(rec.Tag, @"(\d+)\s*$");
        var numericWires = rec.Rows.Select(r => r.Wire.Trim())
            .Where(w => w.Length > 0 && w.All(char.IsAsciiDigit))
            .Select(long.Parse).ToList();
        if (!m.Success || numericWires.Count == 0)
            return "Tag convention: not checkable (non-numeric tag or wires).";
        return long.Parse(m.Groups[1].Value) == numericWires.Max()
            ? $"Tag = highest wire no ({numericWires.Max()}): convention holds."
            : $"Tag suffix {m.Groups[1].Value} != highest wire no ({numericWires.Max()}): convention DOES NOT hold.";
    }

    static List<ConductorRow> SortRows(List<ConductorRow> rows)
    {
        // Numeric pins numerically, then non-numeric pins by string, pin-less
        // rows last in extraction order. Never inferred from wire numbers.
        string PinKeyOf(ConductorRow r) => r.Pin.Trim();
        var numeric = rows.Where(r => double.TryParse(PinKeyOf(r), out _))
                          .OrderBy(r => double.Parse(PinKeyOf(r))).ToList();
        var lettered = rows.Where(r => PinKeyOf(r).Length > 0 && !double.TryParse(PinKeyOf(r), out _))
                           .OrderBy(PinKeyOf, StringComparer.OrdinalIgnoreCase).ToList();
        var pinless = rows.Where(r => PinKeyOf(r).Length == 0).ToList();
        return numeric.Concat(lettered).Concat(pinless).ToList();
    }

    /// Inserts one instance of the shared definition and fills the INSTANCE's
    /// AttributeReferences from `values`. Tags missing from `values` (unused
    /// conductor rows) get "" on the instance. The definition is never edited
    /// after creation — editing AttributeDefinitions inside the definition
    /// would change every placed copy at once.
    static void InsertInstance(Database db, Transaction tr, ObjectId defId, Point3d at,
                               Dictionary<string, string> values)
    {
        var bt = (BlockTable)tr.GetObject(db.BlockTableId, OpenMode.ForRead);
        var ms = (BlockTableRecord)tr.GetObject(bt[BlockTableRecord.ModelSpace], OpenMode.ForWrite);
        var br = new BlockReference(at, defId);
        ms.AppendEntity(br);
        tr.AddNewlyCreatedDBObject(br, true);

        var def = (BlockTableRecord)tr.GetObject(defId, OpenMode.ForRead);
        foreach (ObjectId id in def)
        {
            if (tr.GetObject(id, OpenMode.ForRead) is not AttributeDefinition ad) continue;
            var ar = new AttributeReference();
            ar.SetAttributeFromBlock(ad, br.BlockTransform);
            ar.TextString = values.GetValueOrDefault(ad.Tag.ToUpperInvariant(), "");
            br.AttributeCollection.AppendAttribute(ar);
            tr.AddNewlyCreatedDBObject(ar, true);
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    static string First(Dictionary<string, string> attrs, string[] tags)
        => tags.Select(t => attrs.GetValueOrDefault(t, "").Trim()).FirstOrDefault(v => v.Length > 0) ?? "";

    static string FillIfEmpty(string current, string candidate)
        => current.Trim().Length > 0 ? current : candidate;

    static bool WildcardMatch(string value, string pattern)
        => value.Trim().Length > 0 && Regex.IsMatch(value.Trim(),
            "^" + Regex.Escape(pattern).Replace(@"\*", ".*").Replace(@"\?", ".") + "$",
            RegexOptions.IgnoreCase);

    static string CsvEsc(string s)
        => s.Contains(',') || s.Contains('"') || s.Contains('\n')
            ? "\"" + s.Replace("\"", "\"\"") + "\"" : s;
}
