#!/usr/bin/env python3
"""Generate synthetic AutoCAD Electrical test drawings from EXAMPLES.md scenarios.

Creates DXF files in test_drawings/ that mirror the block/attribute structures
described in EXAMPLES.md (scenarios A1-A4, B1-B2, C1-C3, D1-D2). Open them in
AutoCAD (or AutoCAD Electrical), SAVEAS .dwg into a test folder, and CABLESCAN /
CABLECENSUS that folder — a full end-to-end test with no real project drawings.

Usage: python3 tools/make_test_dxfs.py
"""

import os

import ezdxf

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "test_drawings")

ATTR_H = 0.08   # attribute text height
ATTR_DY = 0.12  # vertical spacing between stacked attributes


def new_doc():
    doc = ezdxf.new("R2018", setup=True)
    doc.header["$INSUNITS"] = 1  # inches
    return doc


def blockdef(doc, name):
    """Simple rectangle body so the block is visible; attributes are per-insert."""
    if name in doc.blocks:
        return
    blk = doc.blocks.new(name=name)
    blk.add_lwpolyline([(0, 0), (0.5, 0), (0.5, 0.25), (0, 0.25)], close=True)


def ins(msp, doc, name, pos, attrs):
    """Insert block `name` at pos with exactly the attribute tags in `attrs`.

    Tags are added per-insert (not from ATTDEFs) so scenarios with deleted
    attributes (C3) genuinely lack those tags on the insert.
    """
    blockdef(doc, name)
    ref = msp.add_blockref(name, pos)
    x, y = pos
    dy = 0.30
    for tag, val in attrs.items():
        a = ref.add_attrib(tag, str(val), (x + 0.05, y + dy))
        a.dxf.height = ATTR_H
        dy += ATTR_DY
    return ref


def wire(msp, doc, x1, x2, y, wireno):
    """Horizontal wire LINE with a WD_WNH wire-number block sitting on it."""
    msp.add_line((x1, y), (x2, y))
    if wireno is not None:
        ins(msp, doc, "WD_WNH", ((x1 + x2) / 2.0, y), {"WIRENO": wireno})


def label(msp, text, pos):
    msp.add_text(text, dxfattribs={"height": 0.18}).set_placement(pos)


def sheet_04():
    """A1 (CBL-1002), A4 (CBL-204), B1 (CBL-2041), C1 (CBL-MCC1-PNL3-012)."""
    doc = new_doc()
    msp = doc.modelspace()

    # --- A1: 3C instrument cable CBL-1002, wires 1000-1002, pins in order ---
    label(msp, "A1: CBL-1002 happy path", (0, 13.6))
    ins(msp, doc, "LT_XMTR", (0, 12), {
        "TAG1": "LT-401", "LOC": "FLD", "MFG": "ENDRESS+HAUSER",
        "CAT": "FMU40-ANB2A2", "TERM01": "+", "TERM02": "-", "TERM03": "S"})
    wire(msp, doc, 1, 6, 12.8, 1000)
    wire(msp, doc, 6, 11, 12.8, 1000)   # second segment: duplicate WD_WNH for 1000
    wire(msp, doc, 1, 11, 12.2, 1001)
    wire(msp, doc, 1, 11, 11.6, 1002)
    ins(msp, doc, "HCM1", (4, 12.8), {
        "TAG1": "CBL-1002", "MFG": "BELDEN", "CAT": "8770", "LOC": "FLD",
        "COLOR": "BLK", "DESC1": "3C 18AWG SHLD INSTR CABLE", "WIRENO": "1000"})
    ins(msp, doc, "HCM2", (4, 12.2), {"TAG2": "CBL-1002", "COLOR": "RED", "WIRENO": "1001"})
    ins(msp, doc, "HCM2", (4, 11.6), {"TAG2": "CBL-1002", "COLOR": "WHT", "WIRENO": "1002"})
    for i, w in enumerate(["1000", "1001", "1002"]):
        ins(msp, doc, "HT0_001", (11.2, 12.8 - 0.6 * i), {
            "TAGSTRIP": "TB1", "LOC": "PNL-3", "TERM01": str(i + 1), "WIRENO": w})

    # --- A4: CABLENO/XREF tag variant, CBL-204, no termination symbols ---
    label(msp, "A4: CBL-204 CABLENO/XREF variant", (0, 9.6))
    wires = [("1001", "BLK"), ("1002", "RED"), ("1003", "WHT"), ("1004", "GRN")]
    for i, (w, _c) in enumerate(wires):
        wire(msp, doc, 1, 11, 9.0 - 0.6 * i, w)
    ins(msp, doc, "HC1", (4, 9.0), {
        "CABLENO": "CBL-204", "MFG": "BELDEN", "CAT": "9534", "LOC": "MCC-1",
        "DESC1": "4C #24AWG OAS PLC ANALOG", "COLOR": "BLK", "WIRENO": "1001"})
    for i, (w, c) in enumerate(wires[1:], start=1):
        ins(msp, doc, "HC1-CHILD", (4, 9.0 - 0.6 * i), {"XREF": "CBL-204", "COLOR": c, "WIRENO": w})

    # --- B1: scrambled pin map CBL-2041; children carry NO WIRENO ---
    label(msp, "B1: CBL-2041 scrambled pins (children have no WIRENO)", (0, 5.6))
    b1 = [("2041", "BK", "7", "14"), ("2040", "RD", "2", "11"),
          ("2039", "WH", "9", "18"), ("2038", "GN", "4", "12")]
    for i, (w, _c, _pp, _tb) in enumerate(b1):
        wire(msp, doc, 1, 11, 5.0 - 0.6 * i, w)
    ins(msp, doc, "HCM1_INLINE", (4, 5.0), {
        "TAG1": "CBL-2041", "COLOR": "BK", "DESC1": "4C #18 AWG SOOW"})
    for i, (_w, c, _pp, _tb) in enumerate(b1[1:], start=1):
        ins(msp, doc, "HCM2_INLINE", (4, 5.0 - 0.6 * i), {"TAGXREF": "CBL-2041", "COLOR": c})
    ins(msp, doc, "HCN1P12", (0, 5.0), {
        "TAG1": "PJ4", "LOC": "PNL-3", "MFG": "TE CONNECTIVITY", "CAT": "206036-1",
        "TERM01": "7", "TERM02": "2", "TERM03": "9", "TERM04": "4"})
    for i, (_w, _c, _pp, tb) in enumerate(b1):
        ins(msp, doc, "HT0001", (11.2, 5.0 - 0.6 * i), {
            "TAGSTRIP": "TB2", "LOC": "MCC-1", "TERMNO": tb})

    # --- C1: 12-pin connectors, TERM09..12 empty strings, HCM2 children key on TAG1 ---
    label(msp, "C1: CBL-MCC1-PNL3-012 with 4 unpopulated pins", (0, 1.6))
    colors = ["BLK", "RED", "WHT", "GRN", "ORN", "BLU", "WHT/RED", "WHT/BLK"]
    conn = {"LOC": "MCC-1", "MFG": "AMPHENOL", "CAT": "97-3106A-20-27P"}
    pj = {"TAG1": "PJ412", **conn}
    pl = {"TAG1": "PL412", "LOC": "PNL-3", "MFG": conn["MFG"], "CAT": conn["CAT"]}
    for n in range(1, 13):
        v = str(n) if n <= 8 else ""
        pj[f"TERM{n:02d}"] = v
        pl[f"TERM{n:02d}"] = v
    ins(msp, doc, "HCN1P12", (0, 1.0), pj)
    ins(msp, doc, "HCN1P12", (11.2, 1.0), pl)
    for i, c in enumerate(colors):
        w = str(1101 + i)
        wire(msp, doc, 1, 11, 1.0 - 0.45 * i, w)
        blkname = "HCM1" if i == 0 else "HCM2"
        attrs = {"TAG1": "CBL-MCC1-PNL3-012", "COLOR": c, "WIRENO": w}
        if i == 0:
            attrs.update({"MFG": "BELDEN", "CAT": "27331A",
                          "DESC1": "12C #16AWG 600V TC", "LOC": "MCC-1"})
        ins(msp, doc, blkname, (4, 1.0 - 0.45 * i), attrs)

    return doc


def sheet_07():
    """A2 (CBL-2003), C2 (CBL-PNL3-JB7-005), D2 parent (CBL-412 on VC1)."""
    doc = new_doc()
    msp = doc.modelspace()

    # --- A2: 4-conductor motor feed CBL-2003 ---
    label(msp, "A2: CBL-2003 motor feed", (0, 13.6))
    ins(msp, doc, "HMS1", (0, 12), {
        "TAG1": "M-201", "LOC": "MCC-1", "MFG": "ALLEN-BRADLEY", "CAT": "509-BOD",
        "TERM01": "T1", "TERM02": "T2", "TERM03": "T3"})
    ins(msp, doc, "HMO1", (11.2, 12), {
        "TAG1": "MTR-201", "LOC": "FLD", "MFG": "BALDOR", "CAT": "EM3611T",
        "TERM01": "1", "TERM02": "2", "TERM03": "3", "TERM04": "4"})
    a2 = [("2000", "BK1"), ("2001", "BK2"), ("2002", "BK3"), ("2003", "GNYE")]
    for i, (w, c) in enumerate(a2):
        wire(msp, doc, 1, 11, 12.8 - 0.6 * i, w)
        if i == 0:
            ins(msp, doc, "HCM1", (4, 12.8), {
                "TAG1": "CBL-2003", "MFG": "LAPP", "CAT": "OLFLEX CLASSIC 110 1119304",
                "LOC": "MCC-1", "COLOR": c, "DESC1": "4G2.5 600V FLEX CABLE", "WIRENO": w})
        else:
            ins(msp, doc, "HCM2", (4, 12.8 - 0.6 * i), {"TAG2": "CBL-2003", "COLOR": c, "WIRENO": w})

    # --- C2: literal SPARE tokens in WIRENO, shield drain 2214 ---
    label(msp, "C2: CBL-PNL3-JB7-005 landed spares (SPARE tokens)", (0, 8.6))
    c2 = [("2210", "BLK", "14", "1"), ("2211", "WHT", "15", "2"), ("2212", "RED", "16", "3"),
          ("2213", "GRN", "17", "4"), ("2215", "ORN", "20", "5"),
          ("SPARE", "BLU", "18", "6"), ("spare ", "WHT/BLK", "19", "7"),
          ("2214", "SHD", "GND", "")]
    for i, (w, c, tb2, tbj7) in enumerate(c2):
        y = 8.0 - 0.5 * i
        wire(msp, doc, 1, 11, y, w)
        if i == 0:
            ins(msp, doc, "HCM1", (4, y), {
                "TAG1": "CBL-PNL3-JB7-005", "MFG": "ALPHA WIRE", "CAT": "5477C",
                "LOC": "PNL-3", "COLOR": c, "DESC1": "7C #18AWG SHIELDED", "WIRENO": w})
        else:
            ins(msp, doc, "HCM2", (4, y), {"TAG2": "CBL-PNL3-JB7-005", "COLOR": c, "WIRENO": w})
        ins(msp, doc, "HT0001", (1.2, y), {"TAGSTRIP": "TB-2", "LOC": "PNL-3", "TERMNO": tb2})
        if tbj7:
            ins(msp, doc, "HT0002", (11.2, y), {"TAGSTRIP": "TB-J7", "LOC": "JB-7", "TERMNO": tbj7})

    # --- D2 (part 1 of 3): VC1 parent for CBL-412 on the one-line ---
    label(msp, "D2: CBL-412 parent marker (children on sheets 09/10)", (0, 3.6))
    wire(msp, doc, 1, 11, 3.0, "412T1")
    ins(msp, doc, "VC1", (4, 3.0), {
        "TAG1": "CBL-412", "MFG": "BELDEN", "CAT": "29501F", "LOC": "MCC-1",
        "COLOR": "BLK", "DESC1": "VFD CABLE 4C #12AWG TO MTR-412", "WIRENO": "412T1"})

    return doc


def sheet_09():
    """D2 (part 2): CBL-412 children for 412T2/412T3."""
    doc = new_doc()
    msp = doc.modelspace()
    label(msp, "D2: CBL-412 continuation children", (0, 5.6))
    for i, w in enumerate(["412T2", "412T3"]):
        wire(msp, doc, 1, 11, 5.0 - 0.6 * i, w)
        ins(msp, doc, "VC1-CHILD", (4, 5.0 - 0.6 * i), {"TAG2": "CBL-412", "COLOR": "BLK", "WIRENO": w})
    return doc


def sheet_10():
    """D2 (part 3): 412T1 duplicate continuation + 412GND, plus near-twin CBL-413."""
    doc = new_doc()
    msp = doc.modelspace()
    label(msp, "D2: CBL-412 dup continuation + CBL-413 near-twin", (0, 5.6))
    wire(msp, doc, 1, 11, 5.0, "412T1")  # duplicate of sheet 07 -> must dedupe
    ins(msp, doc, "VC1-CHILD", (4, 5.0), {"TAG2": "CBL-412", "COLOR": "BLK", "WIRENO": "412T1"})
    wire(msp, doc, 1, 11, 4.4, "412GND")
    ins(msp, doc, "VC1-CHILD", (4, 4.4), {"TAG2": "CBL-412", "COLOR": "GRN/YEL", "WIRENO": "412GND"})
    wire(msp, doc, 1, 11, 3.2, "413T1")
    ins(msp, doc, "HC1", (4, 3.2), {
        "TAG1": "CBL-413", "MFG": "BELDEN", "CAT": "29501F", "LOC": "MCC-1",
        "COLOR": "BLK", "DESC1": "VFD CABLE 4C #12AWG TO MTR-413", "WIRENO": "413T1"})
    return doc


def sheet_11():
    """B2 (CBL-1300), C3 (CBL-MCC1-LS9-021), D1 (CBL_SCHED_12C / CBL-318)."""
    doc = new_doc()
    msp = doc.modelspace()

    # --- B2: tag != highest wire number; wires 1184/1186/1187, tag CBL-1300 ---
    label(msp, "B2: CBL-1300 (tag != max wire; 1185 NOT in cable)", (0, 13.6))
    b2 = [("1187", "BK", "+", "3"), ("1186", "WH", "-", "5"), ("1184", "SH", "S", "7")]
    ins(msp, doc, "PIT_XMTR", (0, 12.4), {
        "TAG1": "PIT-110", "LOC": "FLD-1", "MFG": "ROSEMOUNT", "CAT": "3051TG",
        "TERM01": "+", "TERM02": "-", "TERM03": "S"})
    for i, (w, c, _t, tb) in enumerate(b2):
        y = 13.0 - 0.6 * i
        wire(msp, doc, 1, 11, y, w)
        if i == 0:
            ins(msp, doc, "HCM1_INLINE", (4, y), {
                "TAG1": "CBL-1300", "COLOR": c, "DESC1": "1PR+SH #16 AWG BELDEN 1120A"})
        else:
            ins(msp, doc, "HCM2_INLINE", (4, y), {"TAGXREF": "CBL-1300", "COLOR": c})
        ins(msp, doc, "HT0001", (11.2, y), {"TAGSTRIP": "TB301", "LOC": "PNL-3", "TERMNO": tb})
    # unrelated wire 1185 inside the cable's numeric range (range-grouping trap)
    wire(msp, doc, 1, 11, 10.9, "1185")

    # --- C3: 19-pin MIL connector, TERM15..19 deleted, end-mismatch on pin P ---
    label(msp, "C3: CBL-MCC1-LS9-021 MIL connector, deleted attrs, pin P mismatch", (0, 9.8))
    contacts = ["A", "B", "C", "D", "E", "F", "G", "H", "J", "K", "L", "M", "N", "P"]
    wires_c3 = ["3301", "3302", "3303", "3304", "3305", "3306", "3307", "3308",
                "3309", "3310", "3311", "3312", "3314", "3313"]
    colors_c3 = ["BLK", "WHT", "RED", "GRN", "ORN", "BLU", "WHT/BLK", "RED/BLK",
                 "GRN/BLK", "ORN/BLK", "BLU/BLK", "BLK/WHT", "RED/WHT", "WHT/GRN"]
    pj921 = {"TAG1": "PJ921", "LOC": "MCC-1", "MFG": "AMPHENOL", "CAT": "MS3106A22-14P"}
    pl921 = {"TAG1": "PL921", "LOC": "LS-9", "MFG": "AMPHENOL", "CAT": "MS3106A22-14S"}
    # only TERM01..14 exist (15..19 deleted by the drafter)
    for n, contact in enumerate(contacts, start=1):
        pj921[f"TERM{n:02d}"] = contact
        pl921[f"TERM{n:02d}"] = contact
    ins(msp, doc, "HCN1P19", (0, 9.2), pj921)
    ins(msp, doc, "HCN1P19", (11.2, 9.2), pl921)
    for i, (w, c) in enumerate(zip(wires_c3, colors_c3)):
        y = 9.2 - 0.4 * i
        # pin P (last row): MCC-1 end says 3313, LS-9 end marker says SP
        wire(msp, doc, 1, 6, y, w)
        wire(msp, doc, 6, 11, y, "SP" if w == "3313" else w)
        blkname = "HCM1" if i == 0 else "HCM2"
        attrs = {"TAG1" if i == 0 else "TAG2": "CBL-MCC1-LS9-021", "COLOR": c, "WIRENO": w}
        if i == 0:
            attrs.update({"MFG": "GENERAL CABLE", "CAT": "236110",
                          "DESC1": "19C #16AWG 600V", "LOC": "MCC-1"})
        ins(msp, doc, blkname, (4, y), attrs)

    # --- D1: whole cable in ONE schedule block with numbered families ---
    label(msp, "D1: CBL-318 single schedule block (PIN1/WIRE1/COLOR1 families)", (0, 3.0))
    d1_colors = ["BLK", "WHT", "RED", "GRN", "ORG", "BLU", "WHT/BLK", "RED/BLK",
                 "GRN/BLK", "ORG/BLK", "BLU/BLK", "BLK/WHT"]
    sched = {"TAG1": "CBL-318", "MFG": "LAPP", "CAT": "OLFLEX-190-16/12",
             "LOC": "PNL-3", "DESC1": "12C #16AWG CONTROL TO JB-12"}
    for n in range(1, 13):
        used = n <= 10
        sched[f"PIN{n}"] = str(n) if used else ""
        sched[f"WIRE{n}"] = str(2100 + n) if used else ""
        sched[f"COLOR{n}"] = d1_colors[n - 1]
    ins(msp, doc, "CBL_SCHED_12C", (0, 0.4), sched)

    return doc


def sheet_12():
    """A3 (CBL-3101): smallest valid cable, connector to connector."""
    doc = new_doc()
    msp = doc.modelspace()
    label(msp, "A3: CBL-3101 two-conductor minimum", (0, 5.6))
    ins(msp, doc, "HCN1", (0, 5.0), {
        "TAG1": "J1", "LOC": "PNL-3", "MFG": "PHOENIX CONTACT", "CAT": "1803426", "PIN": "1"})
    ins(msp, doc, "HCN2", (0, 4.4), {"TAG2": "J1", "PIN": "2"})
    ins(msp, doc, "HCN1", (11.2, 5.0), {
        "TAG1": "P1", "LOC": "MCC-1", "MFG": "PHOENIX CONTACT", "CAT": "1803426", "PIN": "1"})
    ins(msp, doc, "HCN2", (11.2, 4.4), {"TAG2": "P1", "PIN": "2"})
    wire(msp, doc, 1, 11, 5.0, "3100")
    wire(msp, doc, 1, 11, 4.4, "3101")
    ins(msp, doc, "HCM1", (4, 5.0), {
        "TAG1": "CBL-3101", "MFG": "BELDEN", "CAT": "9463", "LOC": "PNL-3",
        "COLOR": "BLU", "DESC1": "TWINAX 2C 20AWG SHLD BLUE HOSE", "WIRENO": "3100"})
    ins(msp, doc, "HCM2", (4, 4.4), {"TAG2": "CBL-3101", "COLOR": "WHT", "WIRENO": "3101"})
    return doc


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    sheets = {
        "SHEET-04.dxf": sheet_04,
        "SHEET-07.dxf": sheet_07,
        "SHEET-09.dxf": sheet_09,
        "SHEET-10.dxf": sheet_10,
        "SHEET-11.dxf": sheet_11,
        "SHEET-12.dxf": sheet_12,
    }
    for name, build in sheets.items():
        path = os.path.join(OUT_DIR, name)
        build().saveas(path)
        print(f"wrote {path}")
    print(f"\n{len(sheets)} sheets. Open in AutoCAD and SAVEAS .dwg before running CABLESCAN")
    print("(ObjectDBX batch-opens DWG only, not DXF).")


if __name__ == "__main__":
    main()
