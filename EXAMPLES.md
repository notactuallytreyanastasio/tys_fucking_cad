# Cable Report Tool — Example Scenarios & Acceptance Spec

This file is the acceptance spec for the AutoCAD Electrical cable-report extractor.
Each example lists the block inserts (with their attribute tags/values) that exist in the
drawing set, the traps the extractor must survive, and the **exact expected summary block**.

## Summary block format (normative)

Every cable in the report renders as:

```
CABLE:  <cable name>                    <- human description (DESC1 of the cable marker)
TAG:    <cable tag>                     <- the cable identifier (TAG1/CABLENO of the parent marker — NEVER derived from wire numbers)
PART:   <MFG> <CAT>                     <- manufacturer + catalog number from the parent marker
LOC:    <from LOC> -> <to LOC>          <- end locations (and end-device tags when known)
-----------------------------------------------------------
WIRE     | COLOR + PIN
<wireno> | <color>  <end terminations / pins>
...
-----------------------------------------------------------
<conductor accounting line>
```

Rules embedded in the format:

- **TAG comes only from the parent cable-marker attribute.** The "tag = highest wire number"
  convention is a shop habit that the report may *verify* and comment on, never *assume*.
- **Rows sort by pin number when pins are numeric** (numeric compare, so 10 > 9).
  Letter pins sort by contact sequence. If only one end has numeric pins, sort by that end.
  If no pins exist, fall back to wire-number order. Sorting is NEVER inferred by sorting
  wire numbers when pin data exists.
- Spare / unpopulated pins still get rows (see Group C).

---

## Group A — Well-behaved parent + child marker cables (happy path)

### A1. 3-conductor analog instrument cable — CBL-1002 (Belden 8770)

Field transmitter LT-401 (FLD) to terminal strip TB1 in PNL-3. One sheet (SHEET-04.dwg).
Wires 1000–1002 land on TB1 pins 1–3 in order.

**Blocks:**

| Block | Key attributes |
|---|---|
| `LT_XMTR` (device) | TAG1=LT-401, LOC=FLD, MFG=ENDRESS+HAUSER, CAT=FMU40-ANB2A2, TERM01=`+`, TERM02=`-`, TERM03=`S` |
| `WD_WNH` ×3 | WIRENO=1000 / 1001 / 1002 (wire 1000 appears on TWO inserts — segments across a line break) |
| `HCM1` (parent cable marker) | TAG1=CBL-1002, MFG=BELDEN, CAT=8770, LOC=FLD, COLOR=BLK, DESC1=3C 18AWG SHLD INSTR CABLE, WIRENO=1000 |
| `HCM2` ×2 (child markers) | TAG2=CBL-1002, COLOR=RED/WHT, WIRENO=1001/1002 |
| `HT0_001` ×3 (terminals) | TAGSTRIP=TB1, LOC=PNL-3, TERM01=1/2/3, WIRENO=1000/1001/1002 |

**Traps:**
- The parent `HCM1` carries conductor #1's COLOR itself — it is conductor 1, not just a header. Miss this and you report 2 of 3.
- Duplicate `WD_WNH` inserts for wire 1000 must dedupe to one conductor row.
- Device-side pins are non-numeric (`+`, `-`, `S`); order rows by the numeric TB1 pins.

**Expected summary block:**

```
CABLE:  3C 18AWG SHLD INSTR CABLE
TAG:    CBL-1002
PART:   BELDEN 8770
LOC:    FLD (LT-401) -> PNL-3 (TB1)
-----------------------------------------------------------
WIRE  | COLOR + PIN
1000  | BLK  TB1 pin 1   (LT-401 "+")
1001  | RED  TB1 pin 2   (LT-401 "-")
1002  | WHT  TB1 pin 3   (LT-401 "S" / shield)
-----------------------------------------------------------
3 of 3 conductors assigned. Tag = highest wire no (1002): convention holds.
```

### A2. 4-conductor motor feed — CBL-2003 (Lapp OLFLEX CLASSIC 110)

Starter M-201 (MCC-1, block `HMS1`) to motor MTR-201 (FLD, block `HMO1`) on SHEET-07.dwg.
TERM attributes live on the device parents themselves (no separate terminal blocks).

**Blocks:**

| Block | Key attributes |
|---|---|
| `HMS1` (starter) | TAG1=M-201, LOC=MCC-1, MFG=ALLEN-BRADLEY, CAT=509-BOD, TERM01..03=T1/T2/T3 |
| `HMO1` (motor) | TAG1=MTR-201, LOC=FLD, MFG=BALDOR, CAT=EM3611T, TERM01..04=1/2/3/4 |
| `WD_WNH` ×4 | WIRENO=2000..2003 |
| `HCM1` | TAG1=CBL-2003, MFG=LAPP, CAT=`OLFLEX CLASSIC 110 1119304`, LOC=MCC-1, COLOR=BK1, DESC1=4G2.5 600V FLEX CABLE, WIRENO=2000 |
| `HCM2` ×3 | TAG2=CBL-2003, COLOR=BK2/BK3/GNYE, WIRENO=2001/2002/2003 |

**Traps:**
- Colors are numbered blacks (BK1/BK2/BK3) plus GNYE — no fixed solid-color whitelist.
- Ground conductor 2003 has no T-pin on the starter side (PE lug) — still a full row.
- CAT contains spaces ("OLFLEX CLASSIC 110 1119304") — must survive whitespace parsing.

**Expected summary block:**

```
CABLE:  4G2.5 600V FLEX CABLE
TAG:    CBL-2003
PART:   LAPP OLFLEX CLASSIC 110 1119304
LOC:    MCC-1 (M-201) -> FLD (MTR-201)
-----------------------------------------------------------
WIRE  | COLOR + PIN
2000  | BK1   M-201 T1 -> MTR-201 pin 1
2001  | BK2   M-201 T2 -> MTR-201 pin 2
2002  | BK3   M-201 T3 -> MTR-201 pin 3
2003  | GNYE  M-201 PE -> MTR-201 pin 4
-----------------------------------------------------------
4 of 4 conductors assigned. Tag = highest wire no (2003): convention holds.
```

### A3. 2-conductor comm pair between connectors — CBL-3101 (Belden 9463)

Connector J1 (PNL-3) to connector P1 (MCC-1) on SHEET-12.dwg. Smallest valid cable:
one parent + one child marker. Smoke-test scenario.

**Blocks:**

| Block | Key attributes |
|---|---|
| `HCN1` / `HCN2` (J1) | TAG1=J1, LOC=PNL-3, MFG=PHOENIX CONTACT, CAT=1803426, PIN=1; child TAG2=J1, PIN=2 |
| `HCN1` / `HCN2` (P1) | TAG1=P1, LOC=MCC-1, same MFG/CAT, PIN=1; child TAG2=P1, PIN=2 |
| `WD_WNH` ×2 | WIRENO=3100/3101 |
| `HCM1` | TAG1=CBL-3101, MFG=BELDEN, CAT=9463, LOC=PNL-3, COLOR=BLU, DESC1=TWINAX 2C 20AWG SHLD BLUE HOSE, WIRENO=3100 |
| `HCM2` | TAG2=CBL-3101, COLOR=WHT, WIRENO=3101 |

**Traps:**
- 2-conductor minimum: grouping must not assume 3+ conductors.
- Tag must be CBL-3101 (from the parent's TAG1), not "CBL-3100" derived from the parent's own WIRENO.
- Both connectors share MFG/CAT (mating halves) — ends distinguished by TAG1/LOC only.

**Expected summary block:**

```
CABLE:  TWINAX 2C 20AWG SHLD BLUE HOSE
TAG:    CBL-3101
PART:   BELDEN 9463
LOC:    PNL-3 (J1) -> MCC-1 (P1)
-----------------------------------------------------------
WIRE  | COLOR + PIN
3100  | BLU  J1 pin 1 -> P1 pin 1
3101  | WHT  J1 pin 2 -> P1 pin 2
-----------------------------------------------------------
2 of 2 conductors assigned. Tag = highest wire no (3101): convention holds.
```

### A4. Stock AcadE marker family variant — CBL-204 (HC1 / HC1-CHILD, CABLENO/XREF tags)

Same topology as A1, but the marker family uses **different attribute tags**: the parent
keys on `CABLENO` and children point back via `XREF` (instead of TAG1/TAG2). This is why
all grouping tags must be configurable lists, not single names. SHEET-04.dwg.

**Blocks:**

| Block | Key attributes |
|---|---|
| `HC1` (parent) | CABLENO=CBL-204, MFG=BELDEN, CAT=9534, LOC=MCC-1, DESC1=4C #24AWG OAS PLC ANALOG, COLOR=BLK, WIRENO=1001 |
| `HC1-CHILD` ×3 | XREF=CBL-204, COLOR=RED/WHT/GRN, WIRENO=1002/1003/1004 |

**Traps:**
- Parent marks conductor #1 (BLK/1001) — count it.
- Children carry `XREF`, not `CABLENO` — parent and child grouping keys differ by tag name.
- Same child block definition inserted 3× with different values — read INSERT attributes, not block-definition defaults.
- Shield/drain of the 9534 has no marker — report 4 conductors, do not invent a 5th from catalog data.
- MFG/CAT/DESC1 exist only on the parent; children inherit in the report.

**Expected summary block:**

```
CABLE:  4C #24AWG OAS PLC ANALOG
TAG:    CBL-204
PART:   BELDEN 9534
LOC:    MCC-1
-----------------------------------------------------------
WIRE  | COLOR + PIN
1001  | BLK   (no pin data)
1002  | RED   (no pin data)
1003  | WHT   (no pin data)
1004  | GRN   (no pin data)
-----------------------------------------------------------
4 of 4 conductors assigned (no termination symbols in drawing set).
```

---

## Group B — Cables where wire-number heuristics FAIL

### B1. Scrambled pin map — CBL-2041 (4C SOOW, plug to terminal strip)

Wires 2038–2041 are consecutive but land on plug PJ4 pins **7, 2, 9, 4** and TB2 terminals
**14, 11, 18, 12** — no arithmetic relationship anywhere. Pin assignment is purely geometric
(TERMxx attribute insertion point touches the wire). SHEET-04.dwg.
Marker variant: `HCM1_INLINE` parent (TAG1) + `HCM2_INLINE` children (`TAGXREF`), and the
**children carry no WIRENO at all** — conductor wire numbers come from the wire the marker sits on.

**Blocks:**

| Block | Key attributes |
|---|---|
| `HCM1_INLINE` | TAG1=CBL-2041, COLOR=BK, DESC1=4C #18 AWG SOOW (on wire 2041) |
| `HCM2_INLINE` ×3 | TAGXREF=CBL-2041, COLOR=RD/WH/GN (on wires 2040/2039/2038) |
| `WD_WNH` ×4 | WIRENO=2041/2040/2039/2038 |
| `HCN1P12` (plug) | TAG1=PJ4, LOC=PNL-3, MFG=TE CONNECTIVITY, CAT=206036-1, TERM01..04=7/2/9/4 (touching wires 2041/2040/2039/2038) |
| `HT0001` ×4 (terminals) | TAGSTRIP=TB2, LOC=MCC-1, TERMNO=14/11/18/12 |

**Traps:**
- Sorting wires and counting pins up gives a wrong pinout for **every** conductor.
- Plug uses pins 2/4/7/9 of 12 — sparse; pins 1,3,5,6,8,10–12 are legitimately absent and must NOT appear (no full-complement inference configured here).
- TB2 numbers scramble in a *different* order than plug pins — ends pair only by following the wire.
- Children carry only TAGXREF + COLOR; wire identity is geometric.

**Expected summary block (sorted by plug pin, numeric):**

```
CABLE:  4C #18 AWG SOOW
TAG:    CBL-2041
PART:   (none on marker)
LOC:    PNL-3 (PJ4) -> MCC-1 (TB2)
-----------------------------------------------------------
WIRE  | COLOR + PIN
2040  | RD  PJ4 pin 2 -> TB2-11
2038  | GN  PJ4 pin 4 -> TB2-12
2041  | BK  PJ4 pin 7 -> TB2-14
2039  | WH  PJ4 pin 9 -> TB2-18
-----------------------------------------------------------
4 of 4 conductors assigned. Tag = highest wire no (2041): convention holds.
```

### B2. Cable tag ≠ highest wire number — CBL-1300 (1PR+SH, Belden 1120A)

PIT-110 (FLD-1) to TB301 (PNL-3) on SHEET-11.dwg. Wires are 1184, 1186, 1187 but the cable
was reserved on the schedule as **CBL-1300**. Wire 1185 exists elsewhere on the project in an
unrelated circuit.

**Blocks:**

| Block | Key attributes |
|---|---|
| `HCM1_INLINE` | TAG1=CBL-1300, COLOR=BK, DESC1=1PR+SH #16 AWG BELDEN 1120A (on wire 1187) |
| `HCM2_INLINE` ×2 | TAGXREF=CBL-1300, COLOR=WH/SH (on wires 1186/1184) |
| `WD_WNH` ×3 | WIRENO=1187/1186/1184 |
| `PIT_XMTR` (custom device block) | TAG1=PIT-110, LOC=FLD-1, MFG=ROSEMOUNT, CAT=3051TG, TERM01..03=`+`/`-`/`S` |
| `HT0001` ×3 | TAGSTRIP=TB301, LOC=PNL-3, TERMNO=3/5/7 |

**Traps:**
- max(WIRENO)=1187: a derive-from-wires tool invents phantom "CBL-1187". Tag exists in exactly one place: parent TAG1.
- Wire 1185 sits inside the cable's numeric range but is NOT in the cable — range grouping absorbs it wrongly.
- Pins `+`/`-`/`S` are strings; never int-parse pin designators.
- Highest wire (1187) lands on the LOWEST terminal (TB301-3) — order inverted.
- Shield (COLOR=SH, wire 1184) is a real conductor, must appear.

**Expected summary block (sorted by the numeric-pin end, TB301):**

```
CABLE:  1PR+SH #16 AWG BELDEN 1120A
TAG:    CBL-1300
PART:   (BELDEN 1120A via DESC1; no MFG/CAT attributes on marker)
LOC:    FLD-1 (PIT-110) -> PNL-3 (TB301)
-----------------------------------------------------------
WIRE  | COLOR + PIN
1187  | BK  PIT-110 "+" -> TB301-3
1186  | WH  PIT-110 "-" -> TB301-5
1184  | SH  PIT-110 "S" -> TB301-7
-----------------------------------------------------------
3 of 3 conductors assigned. Highest wire = 1187 but TAG = CBL-1300:
convention DOES NOT hold — tag taken from parent marker TAG1.
```

### B3. Interleaved wire numbers across two cables, spanning sheets — CBL-3120 + CBL-3118

VFD-3 (MCC-1, SHEET-07) to pendant connector PJ7 and speed-pot connector PJ8 (both FLD-2,
SHEET-08). Wires 3116–3120 numerically **alternate** between the two cables. Sheets joined by
`HA1S1` source / `HA1D1` destination arrows matched on SIGCODE. Parent markers on SHEET-07;
some child markers on SHEET-08 — `TAGXREF` resolves **project-wide**.

**Membership (only recoverable from markers):**
- CBL-3120: wires 3117, 3119, 3120 → PJ7 pins 6, 1, 3; VFD terminals 19, 13, 27
- CBL-3118: wires 3116, 3118 → PJ8 pins 8, 4; VFD terminals ACM, AI1

**Blocks (abridged):** `HCM1_INLINE`(TAG1=CBL-3120, BK) + `HCM2_INLINE`(WH on 07, RD on 08);
`HCM1_INLINE`(TAG1=CBL-3118, BK) + `HCM2_INLINE`(WH on 08); `WD_WNH`×5 (3116–3120);
`VFD_U1`(TAG1=VFD-3, TERM01..05=13/27/19/AI1/ACM); 5× `HA1S1` + 5× `HA1D1` matched on
SIGCODE (PEND-3117/3119/3120, POT-3116/3118); `HCN1P08`×2 (PJ7 TERM=1/3/6, PJ8 TERM=4/8 —
same CAT, same LOC).

**Traps:**
- Any contiguity/range heuristic shreds both cables (3116=3118's, 3117=3120's, ...).
- Each cable *individually* satisfies tag=max-wire — must still not be used for grouping.
- No single polyline end-to-end: continuity flows through SIGCODE-matched arrows.
- Alphanumeric pins (AI1, ACM) on one end, numeric (4, 8) on the other.
- PJ7/PJ8 share LOC and CAT — conductors assigned by actual wire endpoint only.

**Expected summary blocks (each sorted by its numeric connector-pin end):**

```
CABLE:  3C #16 AWG TC
TAG:    CBL-3120
PART:   (none on marker)
LOC:    MCC-1 (VFD-3) -> FLD-2 (PJ7)
-----------------------------------------------------------
WIRE  | COLOR + PIN
3119  | WH  VFD-3:13 -> PJ7 pin 1
3120  | BK  VFD-3:27 -> PJ7 pin 3
3117  | RD  VFD-3:19 -> PJ7 pin 6
-----------------------------------------------------------
3 of 3 conductors assigned. Tag = highest wire no (3120): convention holds.
```

```
CABLE:  1PR #18 AWG SHLD
TAG:    CBL-3118
PART:   (none on marker)
LOC:    MCC-1 (VFD-3) -> FLD-2 (PJ8)
-----------------------------------------------------------
WIRE  | COLOR + PIN
3118  | BK  VFD-3:AI1 -> PJ8 pin 4
3116  | WH  VFD-3:ACM -> PJ8 pin 8
-----------------------------------------------------------
2 of 2 conductors assigned. Tag = highest wire no (3118): convention holds
(but wires 3117/3119 inside this numeric range belong to CBL-3120).
```

---

## Group C — Spare and unpopulated conductors

Three distinct spare flavors. The report must distinguish all of them:

| Flavor | Evidence in DWG | Report representation |
|---|---|---|
| **Unpopulated pin** | TERMxx attribute exists but value is `""`, no wire/marker | `SPARE (unpopulated)` |
| **Landed spare** | WIRENO attribute contains a spare token (`SPARE`, `spare `, `SP`) on a real terminal | `SPARE (landed)` + the termination |
| **Missing attribute** | TERMxx deleted from insert entirely; pin known only from CAT lookup | `SPARE (unterminated, inferred from CAT)` |

### C1. 12-pin connector, 8 conductors landed, 4 empty-string pins — CBL-MCC1-PNL3-012

Connectors PJ412 (MCC-1) / PL412 (PNL-3), both with TERM01..TERM12 present; TERM09..12 = `""`.
HCM1 parent (TAG1=CBL-MCC1-PNL3-012, BELDEN 27331A, 12C) + HCM2 children — note these
children key on `TAG1` (not TAG2/TAGXREF): one more grouping-tag variant. SHEET-04.dwg.

**Traps:**
- Empty TERM value = spare, not a pin named `""`.
- Marker count (8) disagrees with catalog count (12C) — reconcile, don't error.
- Do NOT extrapolate wires 1109–1112 onto spare pins.
- Both ends declare the same spares — ONE spare row per pin, not per end.

**Expected summary block:**

```
CABLE:  12C #16AWG 600V TC
TAG:    CBL-MCC1-PNL3-012
PART:   BELDEN 27331A
LOC:    MCC-1 (PJ412) -> PNL-3 (PL412)
-----------------------------------------------------------
WIRE  | COLOR + PIN
1101  | BLK      pin 1  PJ412-1  -> PL412-1
1102  | RED      pin 2  PJ412-2  -> PL412-2
1103  | WHT      pin 3  PJ412-3  -> PL412-3
1104  | GRN      pin 4  PJ412-4  -> PL412-4
1105  | ORN      pin 5  PJ412-5  -> PL412-5
1106  | BLU      pin 6  PJ412-6  -> PL412-6
1107  | WHT/RED  pin 7  PJ412-7  -> PL412-7
1108  | WHT/BLK  pin 8  PJ412-8  -> PL412-8
SPARE | --       pin 9  (unpopulated)
SPARE | --       pin 10 (unpopulated)
SPARE | --       pin 11 (unpopulated)
SPARE | --       pin 12 (unpopulated)
-----------------------------------------------------------
12 conductors in cable, 8 used, 4 spare (33% spare capacity).
```

### C2. Literal "SPARE" tokens in the wire-number field — CBL-PNL3-JB7-005

7C Alpha Wire 5477C, PNL-3 to JB-7, terminating on `HT0001`/`HT0002` terminal symbols.
Conductors 6 and 7 are physically landed (TB-2:18, TB-2:19, TB-J7:6) but their WIRENO reads
`SPARE` / `spare ` (mixed case, trailing space). Shield drain has real wire 2214, COLOR=SHD,
lands on the ground bar. SHEET-07.dwg.

**Traps:**
- Spare-token matching: case-insensitive, trimmed; family = {SPARE, SP, spare…}.
- Landed spares must print their terminations (different from C1's unpopulated pins).
- Two conductors both reading "SPARE" must NOT merge into one net.
- Shield (2214) is neither spare nor one of the 7 numbered conductors twice.
- `2210` parses as wire number; `SPARE` falls through to the spare classifier, never a parse error.

**Expected summary block:**

```
CABLE:  7C #18AWG SHIELDED
TAG:    CBL-PNL3-JB7-005
PART:   ALPHA WIRE 5477C
LOC:    PNL-3 (TB-2) -> JB-7 (TB-J7)
-----------------------------------------------------------
WIRE  | COLOR + PIN
2210  | BLK      PNL-3:TB-2:14 -> JB-7:TB-J7:1
2211  | WHT      PNL-3:TB-2:15 -> JB-7:TB-J7:2
2212  | RED      PNL-3:TB-2:16 -> JB-7:TB-J7:3
2213  | GRN      PNL-3:TB-2:17 -> JB-7:TB-J7:4
2215  | ORN      PNL-3:TB-2:20 -> JB-7:TB-J7:5
SPARE | BLU      landed: PNL-3:TB-2:18 / JB-7:TB-J7:6
SPARE | WHT/BLK  landed: PNL-3:TB-2:19 / JB-7:TB-J7:7
2214  | SHD      shield/drain: PNL-3:GND bar (floats at JB-7)
-----------------------------------------------------------
7 conductors, 5 used, 2 spare (landed); shield grounded at PNL-3 only.
```

### C3. 19-pin MIL connector with DELETED pin attributes — CBL-MCC1-LS9-021

Amphenol MS3106A22-14S/-14P (19 contacts, lettered A–V skipping I/O/Q per MIL-DTL-5015).
The drafter deleted TERM15..TERM19 — only 14 pin attributes exist on each insert. One contact
(P) reads wire 3313 at the MCC-1 end but `SP` at the LS-9 end. SHEET-11.dwg.

**Traps:**
- Full pin complement (19) must come from CAT lookup, with rows for the absent contacts R, S, T, U, V.
- Three spare flavors on ONE connector: used pin (3313), `SP`-labeled pin, missing attribute.
- `SP` is a spare token only in the WIRE field; a pin *named* `S` is a legitimate MIL contact letter.
- Letter pins sort by contact order, not numerically, and skip I/O/Q.
- End mismatch on contact P → WARNING row, never silently pick a winner.
- Spare-capacity math uses catalog count (19), not max(observed pins).

**Expected summary block:**

```
CABLE:  19C #16AWG 600V
TAG:    CBL-MCC1-LS9-021
PART:   GENERAL CABLE 236110
LOC:    MCC-1 (PJ921) -> LS-9 (PL921)
-----------------------------------------------------------
WIRE  | COLOR + PIN
3301  | BLK      pin A  PJ921-A -> PL921-A
3302  | WHT      pin B  PJ921-B -> PL921-B
3303  | RED      pin C  PJ921-C -> PL921-C
3304  | GRN      pin D  PJ921-D -> PL921-D
3305  | ORN      pin E  PJ921-E -> PL921-E
3306  | BLU      pin F  PJ921-F -> PL921-F
3307  | WHT/BLK  pin G  PJ921-G -> PL921-G
3308  | RED/BLK  pin H  PJ921-H -> PL921-H
3309  | GRN/BLK  pin J  PJ921-J -> PL921-J
3310  | ORN/BLK  pin K  PJ921-K -> PL921-K
3311  | BLU/BLK  pin L  PJ921-L -> PL921-L
3312  | BLK/WHT  pin M  PJ921-M -> PL921-M
3314  | RED/WHT  pin N  PJ921-N -> PL921-N
3313  | WHT/GRN  pin P  WARNING: end mismatch — MCC-1 end wire 3313, LS-9 end marked SP
SPARE | --       pin R  (no attribute on insert — unterminated, inferred from CAT MS3106A22-14)
SPARE | --       pin S  (no attribute on insert — unterminated, inferred from CAT MS3106A22-14)
SPARE | --       pin T  (no attribute on insert — unterminated, inferred from CAT MS3106A22-14)
SPARE | --       pin U  (no attribute on insert — unterminated, inferred from CAT MS3106A22-14)
SPARE | --       pin V  (no attribute on insert — unterminated, inferred from CAT MS3106A22-14)
-----------------------------------------------------------
19 contacts: 13 used clean, 1 conflicted (pin P), 5 spare unterminated.
```

---

## Group D — Alternate block patterns

### D1. Single custom schedule block with numbered attribute families — CBL-318

The ENTIRE cable lives in one block reference (`CBL_SCHED_12C`) with numbered families
`PIN1/WIRE1/COLOR1` .. `PIN12/WIRE12/COLOR12`. No markers, no children. SHEET-11.dwg.
Lapp OLFLEX 190 12C, PNL-3 to JB-12. Conductors 11–12 are spares: COLORn populated,
PINn/WIREn blank.

**Traps:**
- Numbered-tag discovery: no count attribute; enumerate until tags stop existing; sort
  **numerically** by suffix (PIN10 after PIN9, not after PIN1).
- Spare slots (blank PIN/WIRE, populated COLOR) still get rows so count matches the 12C catalog.
- Tag is in `TAG1`, not `CABLENO` — identifier tag list must accept both.
- Slash colors (WHT/BLK) must survive any '/'-splitting.
- Zero-children code path must not crash or emit a 1-conductor cable.

**Expected summary block:**

```
CABLE:  12C #16AWG CONTROL TO JB-12
TAG:    CBL-318
PART:   LAPP OLFLEX-190-16/12
LOC:    PNL-3
-----------------------------------------------------------
WIRE  | COLOR + PIN
2101  | BLK      pin 1
2102  | WHT      pin 2
2103  | RED      pin 3
2104  | GRN      pin 4
2105  | ORG      pin 5
2106  | BLU      pin 6
2107  | WHT/BLK  pin 7
2108  | RED/BLK  pin 8
2109  | GRN/BLK  pin 9
2110  | ORG/BLK  pin 10
SPARE | BLU/BLK  (slot 11)
SPARE | BLK/WHT  (slot 12)
-----------------------------------------------------------
12 conductors, 10 used, 2 spare.
```

### D2. Cross-drawing cable with duplicate continuation markers — CBL-412 (+ CBL-413)

`VC1` (vertical marker family) parent on the power one-line (SHEET-07.dwg); `VC1-CHILD`
conductor markers on SHEET-09.dwg and SHEET-10.dwg. Wire 412T1 is marked on TWO sheets
(parent on 07 + continuation child on 10). An unrelated near-twin cable `CBL-413` (same CAT,
HC1 parent only) also sits on SHEET-10.

**Traps:**
- Single-drawing extraction yields 1–2 conductors; only project-wide aggregation gives 4.
- Dedupe by (cable tag, WIRENO): 412T1 twice → one row, 4 conductors not 5.
- Three identical BLK colors — COLOR is never an identity key; WIRENO is.
- Alphanumeric wire numbers (412T1, 412GND) — never int-parse WIRENO.
- CBL-412 vs CBL-413: grouping is EXACT-match on tag, never prefix/fuzzy.
- HC* and VC* marker families are equivalent.

**Expected summary blocks:**

```
CABLE:  VFD CABLE 4C #12AWG TO MTR-412
TAG:    CBL-412
PART:   BELDEN 29501F
LOC:    MCC-1
-----------------------------------------------------------
WIRE   | COLOR + PIN
412T1  | BLK      (SHEET-07, SHEET-10)
412T2  | BLK      (SHEET-09)
412T3  | BLK      (SHEET-09)
412GND | GRN/YEL  (SHEET-10)
-----------------------------------------------------------
4 of 4 conductors assigned across sheets 07, 09, 10 (412T1 deduped).
```

```
CABLE:  VFD CABLE 4C #12AWG TO MTR-413
TAG:    CBL-413
PART:   BELDEN 29501F
LOC:    MCC-1
-----------------------------------------------------------
WIRE   | COLOR + PIN
413T1  | BLK      (SHEET-10)
-----------------------------------------------------------
1 conductor found (parent marker only) — likely incomplete; flag for review.
```

---

## Cross-cutting acceptance rules (deduplicated from all scenarios)

1. **Cable identity** comes only from the parent marker's identifier attribute
   (TAG1 / CABLENO / configured). Never derived from, validated against requires-flagging-only, wire numbers.
2. **Grouping keys** (parent: TAG1/CABLENO; child: TAG2/TAGXREF/XREF/TAG1) are exact-match,
   project-wide, configurable lists.
3. **The parent marker is conductor #1** when it carries COLOR/WIRENO.
4. **Dedupe** conductors by (cable tag, wire number) across segments, sheets, and continuation markers.
5. **WIRENO is a string**: 4-digit ints, alphanumerics (412T1), and spare tokens all valid.
6. **Pin designators are strings**: numeric pins sort numerically, letter pins by contact
   sequence; mixed ends sort by the numeric end; row order is NEVER inferred from wire numbers.
7. **Spare flavors** are distinct: unpopulated (empty attr), landed (spare token + termination),
   missing-attribute (inferred from catalog).
8. **End mismatches** produce WARNING rows; the tool never silently picks a winner.
9. **Conductor accounting** line always closes the block: used / spare / conflicted vs catalog
   count when known, plus a tag-convention check (holds / does not hold).
