;;; ===================================================================
;;; CableReport.lsp — Cable extraction & report-block placement
;;; for AutoCAD Electrical 2026 (R25). Plain Visual LISP, no DCL,
;;; no acet-*, no dos_lib. See README.md and EXAMPLES.md.
;;;
;;; COMMANDS
;;; --------
;;; CABLEDUMP   Discovery tool. Select any block insert; prints its
;;;             effective block name and every attribute TAG = VALUE
;;;             to the command line. Run this FIRST on a real cable
;;;             marker (parent and child) and on a terminal/connector,
;;;             then correct the CONFIG section below to match the
;;;             tags your library actually uses.
;;;
;;; CABLESCAN   Batch extraction. Prompts [Project/Folder]:
;;;               Project = pick an AcadE .wdp file; its drawing list
;;;                         is parsed (directive lines starting with
;;;                         + = ? * ; [ ~ are skipped, relative paths
;;;                         resolve against the .wdp folder, ".dwg"
;;;                         appended when missing).
;;;               Folder  = pick any DWG in a folder; every *.dwg in
;;;                         that folder is scanned.
;;;             Drawings are read WITHOUT opening them on screen via
;;;             ObjectDBX (vla-GetInterfaceObject). If a file is
;;;             already open in this session (ANY tab, not just the
;;;             active one) it is scanned through that open document
;;;             instead (ObjectDBX cannot open an in-use file).
;;;             Every attributed block reference in ModelSpace
;;;             is examined; a block is a cable component when one of
;;;             the CONFIG cable-tag attributes carries a value that
;;;             matches the CONFIG cable pattern (default "CBL*").
;;;             Blocks sharing one cable tag merge project-wide:
;;;             empty header fields fill in, conductor rows dedupe by
;;;             (cable tag, wire number) with field-wise fill of
;;;             blanks (blank/spare-wire rows merge only when
;;;             literally identical), and pins are picked up from
;;;             NON-cable blocks (terminals/schedules) that pair a
;;;             WIRENO with a pin on the same insert. Source drawings
;;;             are tracked per cable. Results persist
;;;             via prin1 into cable-data.lsp next to the source so
;;;             placement can happen in a DIFFERENT drawing.
;;;
;;; CABLEPLACE  Run in the target drawing. Loads the data file, asks
;;;             for a top-left point, then for EACH cable entmakes a
;;;             unique block definition (CBLRPT_<tag>, suffixed when
;;;             the name already exists) full of ATTDEFs:
;;;             name / tag / part / location header lines, separator
;;;             + WIRE / COLOR + PIN column header, then one row per
;;;             conductor in two columns — wire number at x = 0 and
;;;             "COLOR  pin N" at a configured offset — closed by a
;;;             separator, a conductor accounting line and (when
;;;             computable) a tag-convention verdict. Spare flavors
;;;             render distinctly: "SPARE ... (unpopulated)",
;;;             "SPARE ... landed", "SPARE ... (slot n)". Numeric
;;;             pins sort numerically (distof), letter pins sort by
;;;             contact sequence (string order); on a mix the numeric
;;;             pins lead — pin order is NEVER inferred from wire
;;;             numbers. Blocks stack downward and wrap to a new
;;;             column when the configured max column height would be
;;;             exceeded.
;;;
;;; DATA MODEL (persisted list, one record per cable)
;;;   (tag name mfg cat loc (dwg ...) ((wire color pin slot flavor) ...))
;;;   slot   = numeric attribute suffix (0 = bare WIRENO/COLOR/PIN
;;;            tags); nil on rows loaded from legacy data files
;;;   flavor = nil      normal conductor
;;;            "LANDED" spare token in the wire field (landed spare)
;;;            "UNPOP"  a pin-family attribute exists on the insert
;;;                     but the whole slot is blank (unpopulated pin)
;;; ===================================================================

(vl-load-com)

;;; ===================================================================
;;; CONFIG — every tunable lives here. Edit after running CABLEDUMP.
;;; ===================================================================

;; Attributes that may hold the cable identifier (parent: CABLENO/TAG1,
;; child cross-ref: TAGXREF/TAG2/XREF). Exact tag-name match. A block
;; whose first non-empty value from this list matches
;; cbl:cfg-cable-pattern is treated as part of that cable.
(setq cbl:cfg-cable-tag-atts '("CABLENO" "TAGXREF" "TAG2" "XREF" "TAG1"))

;; wcmatch pattern(s) a cable tag value must match. Comma-separates
;; alternatives, e.g. "CBL*,W-*". Compared case-insensitively.
(setq cbl:cfg-cable-pattern "CBL*")

;; Header attributes (first non-empty wins; fill-if-empty across blocks)
(setq cbl:cfg-name-atts '("DESC1" "DESC2" "DESC3"))
(setq cbl:cfg-mfg-atts  '("MFG"))
(setq cbl:cfg-cat-atts  '("CAT"))
(setq cbl:cfg-loc-atts  '("LOC"))

;; Conductor attribute families. PREFIX matching: the bare tag
;; ("WIRENO", "COLOR", "PIN") and numbered tags ("WIRE1".."WIRE12",
;; "PIN1".."PIN12", "TERM01".."TERM12") both work. Numeric suffixes
;; zip together by number (PIN10 sorts after PIN9, never string sort).
;; KEEP LONGEST-FIRST: "WIRENO" before "WIRE", "TERMNO" before "TERM",
;; otherwise the shorter prefix swallows the longer tag.
(setq cbl:cfg-wire-prefixes  '("WIRENO" "WIRE"))
(setq cbl:cfg-color-prefixes '("COLOR" "CLR"))
(setq cbl:cfg-pin-prefixes   '("TERMNO" "TERM" "PIN"))

;; Tokens in the WIRE field meaning "spare" (case-insensitive, trimmed).
;; Applied to the wire field ONLY — a pin named "S" or "SP" is legal.
(setq cbl:cfg-spare-tokens '("SPARE" "SP"))

;; Name of the persisted data file (written next to the .wdp / folder)
(setq cbl:cfg-data-file "cable-data.lsp")

;; ---- CABLEPLACE geometry (drawing units) ----
(setq cbl:cfg-text-height    0.09375) ; ATTDEF text height
(setq cbl:cfg-row-factor     1.6)     ; line spacing = height * factor
(setq cbl:cfg-col2-offset    1.25)    ; x offset of the COLOR/PIN column
(setq cbl:cfg-block-gap-rows 2.0)     ; blank rows between stacked cables
(setq cbl:cfg-max-col-height 22.0)    ; wrap to a new column past this
(setq cbl:cfg-col-spacing    6.0)     ; x distance between columns
(setq cbl:cfg-layer          "0")     ; layer for ATTDEF/ATTRIB/SEQEND

;;; ================== END CONFIG =====================================


;;; ---------------------- small string helpers ----------------------

(defun cbl:trim (s)
  (if s (vl-string-trim " \t\r\n" s) ""))

(defun cbl:nz (s d)
  ;; s when non-blank, else default d
  (if (and s (/= (cbl:trim s) "")) s d))

(defun cbl:pad (s w)
  (while (< (strlen s) w) (setq s (strcat s " ")))
  s)

(defun cbl:join (lst sep / out)
  (foreach x lst (setq out (if out (strcat out sep x) x)))
  (if out out ""))

(defun cbl:starts-with (s pre)
  (and (>= (strlen s) (strlen pre))
       (= (strcase (substr s 1 (strlen pre))) (strcase pre))))

(defun cbl:all-digits (s / i ok c)
  (setq ok (> (strlen s) 0)
        i  1)
  (while (and ok (<= i (strlen s)))
    (setq c (ascii (substr s i 1)))
    (if (or (< c 48) (> c 57)) (setq ok nil))
    (setq i (1+ i)))
  ok)

(defun cbl:prefix-suffix (tag prefixes / res rest)
  ;; If TAG = <prefix> return 0 (bare). If TAG = <prefix><digits>
  ;; return the digits as an integer. Else nil. First prefix wins —
  ;; keep config lists longest-first.
  (foreach p prefixes
    (if (and (null res) (cbl:starts-with tag p))
      (progn
        (setq rest (substr tag (1+ (strlen p))))
        (cond
          ((= rest "") (setq res 0))
          ((cbl:all-digits rest) (setq res (atoi rest)))))))
  res)

(defun cbl:list-set (lst i v / n out)
  (setq n 0)
  (foreach x lst
    (setq out (cons (if (= n i) v x) out)
          n   (1+ n)))
  (reverse out))

(defun cbl:spare-token-p (s / r)
  ;; spare-token test for the WIRE field only
  (setq s (strcase (cbl:trim s)))
  (foreach tk cbl:cfg-spare-tokens
    (if (= s (strcase tk)) (setq r T)))
  r)

(defun cbl:sanitize (s / i ch out)
  ;; block-name-safe version of a cable tag
  (setq out "" i 1)
  (while (<= i (strlen s))
    (setq ch (substr s i 1))
    (if (wcmatch ch "[A-Za-z0-9_$-]")
      (setq out (strcat out ch))
      (setq out (strcat out "_")))
    (setq i (1+ i)))
  (if (= out "") (setq out "X"))
  out)

(defun cbl:tag-tail-digits (s / i out)
  ;; trailing digit run of a tag ("CBL-1002" -> "1002"); nil when none
  (setq i (strlen s) out "")
  (while (and (> i 0) (wcmatch (substr s i 1) "#"))
    (setq out (strcat (substr s i 1) out)
          i   (1- i)))
  (if (= out "") nil out))

;;; ---------------------- VLA / block helpers -----------------------

(defun cbl:effname (vobj / r)
  ;; effective name (resolves dynamic/anonymous blocks); falls back
  (setq r (vl-catch-all-apply 'vla-get-EffectiveName (list vobj)))
  (if (vl-catch-all-error-p r) (vla-get-Name vobj) r))

(defun cbl:read-attribs (vobj / lst out)
  ;; ((TAG . value) ...) from THIS insert (never definition defaults)
  (setq lst (vl-catch-all-apply 'vlax-invoke (list vobj 'GetAttributes)))
  (if (vl-catch-all-error-p lst) (setq lst nil))
  (foreach a lst
    (setq out (cons (cons (strcase (vla-get-TagString a))
                          (vla-get-TextString a))
                    out))
    ;; drop the COM reference as soon as it is read so long DBX scans
    ;; do not pin every attribute object until garbage collection
    (vl-catch-all-apply 'vlax-release-object (list a)))
  (reverse out))

;;; ---------------------- classification ----------------------------

(defun cbl:cable-tag-of (atts / v tv)
  ;; first non-empty configured cable-tag attribute whose value
  ;; matches the cable pattern; exact-match grouping key
  (foreach tg cbl:cfg-cable-tag-atts
    (if (null v)
      (progn
        (setq tv (cdr (assoc (strcase tg) atts)))
        (if (and tv
                 (/= (cbl:trim tv) "")
                 (wcmatch (strcase (cbl:trim tv))
                          (strcase cbl:cfg-cable-pattern)))
          (setq v (cbl:trim tv))))))
  v)

(defun cbl:getatt (atts taglist / v tv)
  ;; first non-empty value among the listed attribute tags
  (foreach tg taglist
    (if (null v)
      (progn
        (setq tv (cdr (assoc (strcase tg) atts)))
        (if (and tv (/= (cbl:trim tv) "")) (setq v (cbl:trim tv))))))
  v)

(defun cbl:rows-from-atts (atts / slots pinslots tag val sfx idx cur rows
                                  w c p fl)
  ;; Collect conductor slots from wire/color/pin families.
  ;; Suffix 0 = the bare tags on a plain marker (one conductor);
  ;; suffixes 1..n = numbered families on a schedule block.
  ;; Returns ((wire color pin slot flavor) ...): wire/color/pin are
  ;; strings (possibly ""), slot is the numeric tag suffix, flavor is
  ;; nil, "LANDED" (spare token in the wire field) or "UNPOP" (a
  ;; pin-family attribute physically exists on the insert but the
  ;; whole slot is blank — unpopulated pins must stay visible).
  (foreach pr atts
    (setq tag (car pr)
          val (cbl:trim (cdr pr))
          idx nil
          sfx nil)
    (cond
      ((setq sfx (cbl:prefix-suffix tag cbl:cfg-wire-prefixes))  (setq idx 0))
      ((setq sfx (cbl:prefix-suffix tag cbl:cfg-color-prefixes)) (setq idx 1))
      ((setq sfx (cbl:prefix-suffix tag cbl:cfg-pin-prefixes))   (setq idx 2)))
    (if idx
      (progn
        (if (and (= idx 2) (not (member sfx pinslots)))
          (setq pinslots (cons sfx pinslots)))
        (setq cur (cond ((cdr (assoc sfx slots)))
                        ((list "" "" ""))))
        (setq cur (cbl:list-set cur idx val))
        (if (assoc sfx slots)
          (setq slots (subst (cons sfx cur) (assoc sfx slots) slots))
          (setq slots (cons (cons sfx cur) slots))))))
  ;; numeric sort of suffixes (PIN10 after PIN9, never string sort)
  (setq slots (vl-sort slots '(lambda (a b) (< (car a) (car b)))))
  (foreach s slots
    (setq w (nth 0 (cdr s))
          c (nth 1 (cdr s))
          p (nth 2 (cdr s)))
    (setq fl (cond ((cbl:spare-token-p w) "LANDED")
                   ((and (= w "") (= c "") (= p "")
                         (member (car s) pinslots))
                    "UNPOP")))
    ;; keep populated slots, plus all-blank slots whose pin attribute
    ;; exists on the insert (C1-style unpopulated pins)
    (if (or (/= w "") (/= c "") (/= p "") (= fl "UNPOP"))
      (setq rows (append rows (list (list w c p (car s) fl))))))
  rows)

;;; ---------------------- project-wide merge -------------------------
;;; cbl:*cables* : list of (tag name mfg cat loc (dwg ...) (row ...))

(defun cbl:fld (a b)
  ;; a unless blank/nil, else b, else ""
  (cond ((and a (/= (cbl:trim a) "")) a)
        (b)
        ("")))

(defun cbl:row-fill (a b)
  ;; field-wise merge of two rows for the SAME wire number: keep a's
  ;; fields, fill blanks/nils from b (so a marker carrying wire+color
  ;; and a block carrying wire+pin become ONE complete row)
  (list (cbl:fld (nth 0 a) (nth 0 b))
        (cbl:fld (nth 1 a) (nth 1 b))
        (cbl:fld (nth 2 a) (nth 2 b))
        (cond ((nth 3 a)) ((nth 3 b)))
        (cond ((nth 4 a)) ((nth 4 b)))))

(defun cbl:merge-cable (tag atts rows dwg / rec name mfg cat loc dwgs rws
                                            w ex)
  (setq rec (assoc tag cbl:*cables*))
  (if (null rec) (setq rec (list tag "" "" "" "" nil nil)))
  (setq name (nth 1 rec) mfg (nth 2 rec) cat (nth 3 rec)
        loc  (nth 4 rec) dwgs (nth 5 rec) rws (nth 6 rec))
  ;; fill empty header fields only — parent wins, children inherit
  (if (= name "") (setq name (cbl:nz (cbl:getatt atts cbl:cfg-name-atts) "")))
  (if (= mfg "")  (setq mfg  (cbl:nz (cbl:getatt atts cbl:cfg-mfg-atts)  "")))
  (if (= cat "")  (setq cat  (cbl:nz (cbl:getatt atts cbl:cfg-cat-atts)  "")))
  (if (= loc "")  (setq loc  (cbl:nz (cbl:getatt atts cbl:cfg-loc-atts)  "")))
  (if (not (member dwg dwgs)) (setq dwgs (append dwgs (list dwg))))
  ;; conductor identity = (cable tag, wire number): rows with a real
  ;; wire number merge by wire, filling blank color/pin fields, so a
  ;; continuation marker seen with different attribute completeness
  ;; never inflates the conductor count. Blank-wire / spare-token
  ;; rows merge only when literally identical (same slot/flavor too).
  (foreach r rows
    (setq w (cbl:trim (car r)))
    (cond
      ((and (/= w "") (not (cbl:spare-token-p w)))
       (setq ex nil)
       (foreach x rws
         (if (and (null ex) (= (cbl:trim (car x)) w)) (setq ex x)))
       (if ex
         (setq rws (subst (cbl:row-fill ex r) ex rws))
         (setq rws (append rws (list r)))))
      (T
       (if (not (member r rws)) (setq rws (append rws (list r)))))))
  (setq cbl:*cables*
        (cons (list tag name mfg cat loc dwgs rws)
              (vl-remove-if '(lambda (x) (= (car x) tag)) cbl:*cables*))))

;;; ---------------------- pin cross-reference ------------------------
;;; cbl:*pins* : ((wireno . termination-text) ...) harvested from
;;; NON-cable-tagged blocks (terminals, connectors, schedules) that
;;; carry both a wire number and a pin on the same insert. Purely
;;; attribute-based: TERMxx pins that pair with wires only by drawing
;;; geometry (insertion point touching the wire) are NOT recovered.

(defun cbl:add-pin (w p / pr)
  (setq pr (cons w p))
  (if (not (member pr cbl:*pins*))
    (setq cbl:*pins* (append cbl:*pins* (list pr)))))

(defun cbl:harvest-pins (atts / ctx rows wonly ponly w p)
  ;; Two attribute-only patterns:
  ;;   1. schedule-style: wire and pin share a numbered slot
  ;;   2. terminal-style (HT0_001: WIRENO=1000 + TERM01=1): exactly
  ;;      one wire value and exactly one pin value in separate slots
  ;; The termination is prefixed with TAGSTRIP/TAG1 context when known
  ;; ("TB1:1") so CABLEPLACE can show where the conductor lands.
  (setq ctx (cond ((cbl:getatt atts '("TAGSTRIP")))
                  ((cbl:getatt atts '("TAG1")))))
  (setq rows (cbl:rows-from-atts atts))
  (foreach r rows
    (setq w (cbl:trim (car r))
          p (cbl:trim (caddr r)))
    (cond
      ((or (= w "") (cbl:spare-token-p w))
       (if (/= p "") (setq ponly (cons p ponly))))
      ((/= p "")
       (cbl:add-pin w (if ctx (strcat ctx ":" p) p)))
      (T (setq wonly (cons w wonly)))))
  (if (and (= (length wonly) 1) (= (length ponly) 1))
    (cbl:add-pin (car wonly)
                 (if ctx
                   (strcat ctx ":" (car ponly))
                   (car ponly)))))

(defun cbl:pins-for (w / out)
  (foreach pr cbl:*pins*
    (if (and (= (car pr) w) (not (member (cdr pr) out)))
      (setq out (append out (list (cdr pr))))))
  out)

(defun cbl:apply-pins ( / )
  ;; after every drawing is scanned, fill EMPTY pin fields on real
  ;; conductors from the project-wide wireno -> termination map; pins
  ;; already present on the cable-tagged block are never overwritten
  (setq cbl:*cables*
        (mapcar
          '(lambda (rec)
             (cbl:list-set rec 6
               (mapcar
                 '(lambda (r / w hits)
                    (setq w (cbl:trim (car r)))
                    (if (and (/= w "")
                             (not (cbl:spare-token-p w))
                             (= (cbl:trim (cond ((caddr r)) (""))) "")
                             (setq hits (cbl:pins-for w)))
                      (cbl:list-set r 2 (cbl:join hits " -> "))
                      r))
                 (nth 6 rec))))
          cbl:*cables*)))

;;; ---------------------- drawing scanners ---------------------------

(defun cbl:scan-doc (doc dwg / ms cnt hits atts ctag)
  ;; works identically on an open document and on a DBX document
  (setq cnt 0 hits 0)
  (setq ms (vla-get-ModelSpace doc))
  (vlax-for obj ms
    (if (and (= (vla-get-ObjectName obj) "AcDbBlockReference")
             (= (vla-get-HasAttributes obj) :vlax-true))
      (progn
        (setq cnt (1+ cnt))
        (setq atts (cbl:read-attribs obj))
        (setq ctag (cbl:cable-tag-of atts))
        (if ctag
          (progn
            (setq hits (1+ hits))
            (cbl:merge-cable ctag atts (cbl:rows-from-atts atts) dwg))
          ;; non-cable blocks may still pair a wire with a pin
          (cbl:harvest-pins atts)))))
  ;; drop the ModelSpace reference so the previous DBX database is not
  ;; pinned in memory while the next drawing is opened
  (vl-catch-all-apply 'vlax-release-object (list ms))
  (princ (strcat "\n  " (cbl:pad dwg 24) (itoa cnt)
                 " attributed insert(s), " (itoa hits) " cable marker(s)"))
  T)

(defun cbl:open-doc-for (ff / d fn r)
  ;; the AcadDocument already open in THIS session (any MDI tab) whose
  ;; full path matches ff, else nil. ObjectDBX cannot open ANY file
  ;; the current editor has open — not just the active one — so every
  ;; open drawing must be scanned through its document object.
  (setq ff (strcase ff))
  (vlax-for d (vla-get-Documents (vlax-get-acad-object))
    (if (null r)
      (progn
        (setq fn (vl-catch-all-apply 'vla-get-FullName (list d)))
        (if (and (not (vl-catch-all-error-p fn))
                 (= (strcase fn) ff))
          (setq r d)))))
  r)

(defun cbl:get-dbx ( / ver r)
  ;; ObjectDBX document factory. AutoCAD 2026 ACADVER = "25.x" -> ".25"
  (setq ver (atoi (getvar "ACADVER")))
  (setq r (vl-catch-all-apply
            'vla-GetInterfaceObject
            (list (vlax-get-acad-object)
                  (if (< ver 16)
                    "ObjectDBX.AxDbDocument"
                    (strcat "ObjectDBX.AxDbDocument." (itoa ver))))))
  (if (vl-catch-all-error-p r) nil r))

;;; ---------------------- .wdp project parsing -----------------------

(defun cbl:abs-path-p (p)
  (or (and (>= (strlen p) 2) (= (substr p 2 1) ":"))   ; C:\...
      (= (substr p 1 2) "\\\\")                          ; UNC \\srv\...
      (= (substr p 1 1) "/")))

(defun cbl:wdp-paths (wdp / f line dir out ch p)
  ;; Drawing paths from an AcadE project file. Heuristic: skip empty
  ;; lines and directive lines starting with + = ? * ; [ ~ ; every
  ;; other line is a drawing path. Relative paths resolve against the
  ;; .wdp folder; ".dwg" is appended when missing.
  (setq dir (vl-filename-directory wdp))
  (setq f (open wdp "r"))
  (if f
    (progn
      (while (setq line (read-line f))
        (setq line (cbl:trim line))
        (if (> (strlen line) 0)
          (progn
            (setq ch (substr line 1 1))
            (if (not (member ch '("+" "=" "?" "*" ";" "[" "~")))
              (progn
                (setq p line)
                (if (not (wcmatch (strcase p) "*`.DWG"))
                  (setq p (strcat p ".dwg")))
                (if (not (cbl:abs-path-p p))
                  (setq p (strcat dir "\\" p)))
                (setq out (cons p out)))))))
      (close f)))
  (reverse out))

;;; ---------------------- persistence --------------------------------

(defun cbl:save-data (path / f)
  (setq f (open path "w"))
  (if f
    (progn
      (princ ";; Generated by CABLESCAN. Load via CABLEPLACE." f)
      (princ "\n(setq cbl:loaded-data (quote " f)
      (prin1 cbl:*cables* f)
      (princ "))\n" f)
      (close f)
      (princ (strcat "\nData written: " path)))
    (princ (strcat "\nERROR: cannot write " path)))
  (princ))

;;; ===================================================================
;;; COMMAND: CABLEDUMP — attribute discovery
;;; ===================================================================

(defun c:CABLEDUMP ( / es vobj atts catts)
  (vl-load-com)
  (setq es (entsel "\nSelect a block to dump: "))
  (cond
    ((null es)
     (princ "\nNothing selected."))
    ((/= (cdr (assoc 0 (entget (car es)))) "INSERT")
     (princ "\nThat entity is not a block reference."))
    (T
     (setq vobj (vlax-ename->vla-object (car es)))
     (princ "\n=================== CABLEDUMP ===================")
     (princ (strcat "\nEffective block name : " (cbl:effname vobj)))
     (princ (strcat "\nInserted block name  : " (vla-get-Name vobj)))
     (setq atts (cbl:read-attribs vobj))
     (if atts
       (progn
         (princ "\n--- Attributes on this insert ---")
         (foreach a atts
           (princ (strcat "\n  " (cbl:pad (car a) 16) "= " (cdr a)))))
       (princ "\n(no editable attributes on this insert)"))
     (setq catts (vl-catch-all-apply 'vlax-invoke
                                     (list vobj 'GetConstantAttributes)))
     (if (and (not (vl-catch-all-error-p catts)) catts)
       (progn
         (princ "\n--- Constant attributes (from definition) ---")
         (foreach a catts
           (princ (strcat "\n  " (cbl:pad (vla-get-TagString a) 16)
                          "= " (vla-get-TextString a))))))
     (princ "\n=================================================")
     (princ "\nPaste this output back so CONFIG can be locked to your real tags.")))
  (princ))

;;; ===================================================================
;;; COMMAND: CABLESCAN — batch extraction via ObjectDBX
;;; ===================================================================

(defun c:CABLESCAN ( / *error* mode src dir files datafile odoc
                       dbx f ff res okc skc rec rows)
  (vl-load-com)
  ;; local handler: release the DBX document even on Esc or a hard
  ;; error so it does not leak for the rest of the session; the prior
  ;; *error* restores automatically because *error* is a local here
  (defun *error* (msg)
    (if dbx (vl-catch-all-apply 'vlax-release-object (list dbx)))
    (setq dbx nil)
    (if (and msg
             (not (wcmatch (strcase msg) "*BREAK*,*CANCEL*,*EXIT*,*QUIT*")))
      (princ (strcat "\nCABLESCAN error: " msg))
      (princ "\nCABLESCAN cancelled."))
    (princ))
  (setq cbl:*cables* nil
        cbl:*pins*   nil)
  (initget "Project Folder")
  (setq mode (getkword "\nScan source [Project/Folder] <Folder>: "))
  (if (null mode) (setq mode "Folder"))
  (cond
    ((= mode "Project")
     (setq src (getfiled "Select AutoCAD Electrical project file" "" "wdp" 0))
     (if src
       (progn
         (setq files (cbl:wdp-paths src))
         (setq datafile (strcat (vl-filename-directory src)
                                "\\" cbl:cfg-data-file)))))
    (T
     (setq src (getfiled "Select ANY drawing in the folder to scan" "" "dwg" 0))
     (if src
       (progn
         (setq dir (vl-filename-directory src))
         (setq files (mapcar '(lambda (x) (strcat dir "\\" x))
                             (vl-directory-files dir "*.dwg" 1)))
         (setq datafile (strcat dir "\\" cbl:cfg-data-file))))))
  (cond
    ((null src)
     (princ "\nCancelled."))
    ((null files)
     (princ "\nNo drawings found to scan."))
    (T
     (princ (strcat "\nScanning " (itoa (length files)) " drawing(s)..."))
     (setq dbx nil okc 0 skc 0)
     (foreach f files
       (setq ff (findfile f))
       (cond
         ((null ff)
          (setq skc (1+ skc))
          (princ (strcat "\n  SKIP (not found): " f)))
         ((setq odoc (cbl:open-doc-for ff))
          ;; ObjectDBX cannot open a file this session already has
          ;; open (ANY tab) — scan through the open document instead
          (setq res (vl-catch-all-apply
                      'cbl:scan-doc
                      (list odoc (vl-filename-base ff))))
          (if (vl-catch-all-error-p res)
            (progn
              (setq skc (1+ skc))
              (princ (strcat "\n  SKIP (scan failed): " f " ["
                             (vl-catch-all-error-message res) "]")))
            (setq okc (1+ okc))))
         (T
          (if (null dbx) (setq dbx (cbl:get-dbx)))
          (if (null dbx)
            (progn
              (setq skc (1+ skc))
              (princ (strcat "\n  SKIP (ObjectDBX unavailable): " f)))
            (progn
              (setq res (vl-catch-all-apply 'vla-open (list dbx ff)))
              (if (vl-catch-all-error-p res)
                (progn
                  (setq skc (1+ skc))
                  (princ (strcat "\n  SKIP (open failed): " f " ["
                                 (vl-catch-all-error-message res) "]")))
                (progn
                  (setq res (vl-catch-all-apply
                              'cbl:scan-doc
                              (list dbx (vl-filename-base ff))))
                  (if (vl-catch-all-error-p res)
                    (progn
                      (setq skc (1+ skc))
                      (princ (strcat "\n  SKIP (scan failed): " f " ["
                                     (vl-catch-all-error-message res) "]")))
                    (setq okc (1+ okc))))))))))
     (if dbx (vlax-release-object dbx))
     (setq dbx nil)
     ;; fill empty pin fields from terminal/connector data project-wide
     (cbl:apply-pins)
     ;; ---- summary table ----
     (princ "\n\n================== CABLE SUMMARY ==================")
     (princ (strcat "\nDrawings scanned: " (itoa okc)
                    "   skipped: " (itoa skc)
                    "   cables found: " (itoa (length cbl:*cables*))))
     (if cbl:*cables*
       (progn
         (princ (strcat "\n" (cbl:pad "TAG" 26) (cbl:pad "COND" 6) "DRAWINGS"))
         (foreach rec (vl-sort cbl:*cables*
                               '(lambda (a b) (< (car a) (car b))))
           (setq rows (nth 6 rec))
           (princ (strcat "\n" (cbl:pad (car rec) 26)
                          (cbl:pad (itoa (length rows)) 6)
                          (cbl:join (nth 5 rec) ", ")))
           (if (null rows)
             (princ "   <- marker only, no conductor data")))
         (cbl:save-data datafile)
         (princ "\nNow open the target drawing and run CABLEPLACE."))
       (princ "\nNo cable markers matched CONFIG. Run CABLEDUMP on a real cable block and adjust CONFIG."))
     (princ "\n===================================================")))
  (princ))

;;; ===================================================================
;;; COMMAND: CABLEPLACE — entmake report blocks in the target drawing
;;; ===================================================================

(defun cbl:sort-rows (rows / pinned unpinned numr alpr)
  ;; Numeric pins sort numerically (distof, so 10 > 9). Non-numeric
  ;; pins sort by contact sequence — case-insensitive string order,
  ;; which is the MIL lettering order with I/O/Q simply absent. On a
  ;; mixed cable the numeric pins lead. Pin order is NEVER inferred
  ;; from wire numbers; rows without pins (incl. spares) keep
  ;; extraction order at the end.
  (setq pinned   (vl-remove-if
                   '(lambda (r) (= (cbl:trim (caddr r)) "")) rows)
        unpinned (vl-remove-if-not
                   '(lambda (r) (= (cbl:trim (caddr r)) "")) rows)
        numr     (vl-remove-if-not
                   '(lambda (r) (distof (caddr r) 2)) pinned)
        alpr     (vl-remove-if
                   '(lambda (r) (distof (caddr r) 2)) pinned))
  (append
    (vl-sort numr '(lambda (a b)
                     (< (distof (caddr a) 2) (distof (caddr b) 2))))
    (vl-sort alpr '(lambda (a b)
                     (< (strcase (caddr a)) (strcase (caddr b)))))
    unpinned))

(defun cbl:layout-cells (rec / cells y dy n s srows r wire c2 w p fl slot
                               pinp sep used spare maxw tail acct conv)
  ;; -> list of (attdef-tag text x y), local block coordinates,
  ;; first line at y=0 running downward. Emits the normative block:
  ;; 4 header lines, separator, column header, conductor rows,
  ;; separator, conductor accounting line, tag-convention verdict.
  (setq dy  (* cbl:cfg-text-height cbl:cfg-row-factor)
        y   0.0
        n   0
        sep "-----------------------------------------------")
  (foreach s (list (strcat "CABLE: " (cbl:nz (nth 1 rec) "(no name)"))
                   (strcat "TAG:   " (car rec))
                   (strcat "PART:  "
                           (cbl:nz (cbl:trim (strcat (nth 2 rec) " "
                                                     (nth 3 rec)))
                                   "(none on marker)"))
                   (strcat "LOC:   " (cbl:nz (nth 4 rec) "(unknown)")))
    (setq n (1+ n))
    (setq cells (cons (list (strcat "HDR" (itoa n)) s 0.0 y) cells))
    (setq y (- y dy)))
  (setq cells (cons (list "SEP1" sep 0.0 y) cells)
        y     (- y dy))
  (setq cells (cons (list "CHW" "WIRE" 0.0 y) cells))
  (setq cells (cons (list "CHC" "COLOR + PIN" cbl:cfg-col2-offset y) cells))
  (setq y (- y dy))
  (setq srows (cbl:sort-rows (nth 6 rec))
        n     0
        used  0
        spare 0
        maxw  nil)
  (foreach r srows
    (setq n    (1+ n)
          w    (cbl:trim (car r))
          p    (cbl:trim (cond ((caddr r)) ("")))
          slot (nth 3 r)
          fl   (nth 4 r))
    ;; merged terminations ("TB1:1 -> ...") render as-is; bare pin
    ;; values get the "pin " prefix
    (setq pinp (cond ((= p "") "")
                     ((wcmatch p "*[: ]*") p)
                     (T (strcat "pin " p))))
    (cond
      ((= fl "UNPOP")
       (setq wire "SPARE"
             c2   (cbl:trim
                    (strcat "--  "
                            (cond ((/= pinp "") pinp)
                                  ((and slot (> slot 0))
                                   (strcat "pin " (itoa slot)))
                                  (T ""))
                            "  (unpopulated)"))
             spare (1+ spare)))
      ((= fl "LANDED")
       (setq wire "SPARE"
             c2   (cbl:trim
                    (strcat (cadr r) "  landed"
                            (if (/= pinp "") (strcat ": " pinp) "")))
             spare (1+ spare)))
      ((or (= w "") (cbl:spare-token-p w))
       ;; legacy-data blank/spare rows and schedule slots with color
       ;; but no wire. Slot 0 = a bare inline child marker whose wire
       ;; identity is geometric — a real conductor, not a spare.
       (if (and slot (= slot 0))
         (setq wire "(no wire no)"
               c2   (cbl:trim (strcat (cadr r)
                                      (if (/= pinp "")
                                        (strcat "  " pinp) "")))
               used (1+ used))
         (setq wire "SPARE"
               c2   (cbl:trim
                      (strcat (cadr r)
                              (if (/= pinp "") (strcat "  " pinp) "")
                              (if (and (= pinp "") slot (> slot 0))
                                (strcat "  (slot " (itoa slot) ")")
                                "")))
               spare (1+ spare))))
      (T
       (setq wire w
             c2   (cbl:trim (strcat (cadr r)
                                    (if (/= pinp "")
                                      (strcat "  " pinp)
                                      "  (no pin data)")))
             used (1+ used))
       (if (and (cbl:all-digits w)
                (or (null maxw) (> (atoi w) maxw)))
         (setq maxw (atoi w)))))
    (setq cells (cons (list (strcat "W" (itoa n)) wire 0.0 y) cells))
    (setq cells (cons (list (strcat "C" (itoa n)) c2
                            cbl:cfg-col2-offset y)
                      cells))
    (setq y (- y dy)))
  ;; closing separator + conductor accounting + tag-convention check
  (setq cells (cons (list "SEP2" sep 0.0 y) cells)
        y     (- y dy))
  (setq acct (if (> spare 0)
               (strcat (itoa (+ used spare)) " conductors, "
                       (itoa used) " used, " (itoa spare) " spare.")
               (strcat (itoa used) " of " (itoa used)
                       " conductors assigned.")))
  (setq cells (cons (list "FTR1" acct 0.0 y) cells)
        y     (- y dy))
  ;; verify-never-assume: compare the tag's trailing digits with the
  ;; highest all-digit wire number actually found
  (setq tail (cbl:tag-tail-digits (car rec)))
  (if (and maxw tail)
    (progn
      (setq conv (if (= (atoi tail) maxw)
                   (strcat "Tag = highest wire no (" (itoa maxw)
                           "): convention holds.")
                   (strcat "Highest wire = " (itoa maxw) " but TAG = "
                           (car rec) ": convention DOES NOT hold.")))
      (setq cells (cons (list "FTR2" conv 0.0 y) cells))
      (setq y (- y dy))))
  (reverse cells))

(defun cbl:make-blockdef (rec cells / base bname i c)
  ;; entmake an attribute-bearing block definition; unique name
  (setq base  (strcat "CBLRPT_" (cbl:sanitize (car rec)))
        bname base
        i     0)
  (while (tblsearch "BLOCK" bname)
    (setq i     (1+ i)
          bname (strcat base "_" (itoa i))))
  (entmake (list '(0 . "BLOCK")
                 (cons 2 bname)
                 '(70 . 2)
                 '(10 0.0 0.0 0.0)))
  (foreach c cells
    (entmake (list '(0 . "ATTDEF")
                   (cons 8 cbl:cfg-layer)
                   (cons 10 (list (caddr c) (cadddr c) 0.0))
                   (cons 40 cbl:cfg-text-height)
                   (cons 1 (cadr c))   ; default value
                   (cons 3 (car c))    ; prompt
                   (cons 2 (car c))    ; tag
                   '(70 . 0))))
  (entmake (list '(0 . "ENDBLK") (cons 8 cbl:cfg-layer)))
  bname)

(defun cbl:insert-block (bname cells ins / c)
  ;; INSERT (66 . 1) + ATTRIBs at insertion + local offsets + SEQEND
  (entmake (list '(0 . "INSERT")
                 '(66 . 1)
                 (cons 2 bname)
                 (cons 10 ins)))
  (foreach c cells
    (entmake (list '(0 . "ATTRIB")
                   (cons 8 cbl:cfg-layer)
                   (cons 10 (list (+ (car ins) (caddr c))
                                  (+ (cadr ins) (cadddr c))
                                  0.0))
                   (cons 40 cbl:cfg-text-height)
                   (cons 1 (cadr c))
                   (cons 2 (car c))
                   '(70 . 0))))
  (entmake (list '(0 . "SEQEND") (cons 8 cbl:cfg-layer))))

(defun c:CABLEPLACE ( / df pt topy curx cury placed rec cells miny c
                        bh dy bname recs)
  (vl-load-com)
  (setq df (getfiled "Select cable data file"
                     (cbl:nz cbl:*last-data-file* cbl:cfg-data-file)
                     "lsp" 0))
  (cond
    ((null df)
     (princ "\nCancelled."))
    (T
     (setq cbl:loaded-data nil)
     ;; onfailure argument: a malformed/truncated data file must fall
     ;; through to the clean "No cable data" message, not a raw error
     (load df "cbl-data-load-failed")
     (cond
       ((null cbl:loaded-data)
        (princ "\nNo cable data found in that file (run CABLESCAN first)."))
       (T
        (setq cbl:*last-data-file* df)
        (setq recs (vl-sort cbl:loaded-data
                            '(lambda (a b) (< (car a) (car b)))))
        (setq pt (getpoint "\nTop-left insertion point for report column: "))
        (if (null pt)
          (princ "\nCancelled.")
          (progn
            (setq topy   (cadr pt)
                  curx   (car pt)
                  cury   topy
                  dy     (* cbl:cfg-text-height cbl:cfg-row-factor)
                  placed 0)
            (foreach rec recs
              ;; block height from the cells actually laid out
              ;; (headers + separators + rows + accounting lines)
              (setq cells (cbl:layout-cells rec)
                    miny  0.0)
              (foreach c cells
                (if (< (cadddr c) miny) (setq miny (cadddr c))))
              (setq bh (+ (- miny) dy))
              ;; wrap to a new column when this block would overflow
              (if (and (< cury topy)
                       (> (+ (- topy cury) bh) cbl:cfg-max-col-height))
                (setq curx (+ curx cbl:cfg-col-spacing)
                      cury topy))
              (setq bname (cbl:make-blockdef rec cells))
              (cbl:insert-block bname cells (list curx cury 0.0))
              (setq cury   (- cury bh (* cbl:cfg-block-gap-rows dy))
                    placed (1+ placed)))
            (princ (strcat "\nPlaced " (itoa placed)
                           " cable report block(s)."))))))))
  (princ))

;;; ===================================================================
(princ "\nCableReport.lsp loaded. Commands: CABLEDUMP, CABLESCAN, CABLEPLACE")
(princ "\nRun CABLEDUMP on a real cable marker FIRST, then fix CONFIG.")
(princ)
