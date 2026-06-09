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
;;;             ObjectDBX (vla-GetInterfaceObject). If a file is the
;;;             active drawing it is scanned through the active
;;;             document instead (ObjectDBX cannot open an in-use
;;;             file). Every attributed block reference in ModelSpace
;;;             is examined; a block is a cable component when one of
;;;             the CONFIG cable-tag attributes carries a value that
;;;             matches the CONFIG cable pattern (default "CBL*").
;;;             Blocks sharing one cable tag merge project-wide:
;;;             empty header fields fill in, conductor rows union and
;;;             dedupe, source drawings are tracked. Results persist
;;;             via prin1 into cable-data.lsp next to the source so
;;;             placement can happen in a DIFFERENT drawing.
;;;
;;; CABLEPLACE  Run in the target drawing. Loads the data file, asks
;;;             for a top-left point, then for EACH cable entmakes a
;;;             unique block definition (CBLRPT_<tag>, suffixed when
;;;             the name already exists) full of ATTDEFs:
;;;             name / tag / part / location header lines, then one
;;;             row per conductor in two columns — wire number at
;;;             x = 0 and "COLOR  pin N" at a configured offset.
;;;             Unpopulated wires render "(SPARE)". Rows sort by pin
;;;             number when every pin present is numeric (distof) —
;;;             pin order is NEVER inferred from wire numbers.
;;;             Blocks stack downward and wrap to a new column when
;;;             the configured max column height would be exceeded.
;;;
;;; DATA MODEL (persisted list, one record per cable)
;;;   (tag name mfg cat loc (dwg ...) ((wire color pin) ...))
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
                    out)))
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

(defun cbl:rows-from-atts (atts / slots tag val sfx idx cur rows)
  ;; Collect conductor slots from wire/color/pin families.
  ;; Suffix 0 = the bare tags on a plain marker (one conductor);
  ;; suffixes 1..n = numbered families on a schedule block.
  ;; Returns ((wire color pin) ...) — all strings, possibly "".
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
        (setq cur (cond ((cdr (assoc sfx slots)))
                        ((list "" "" ""))))
        (setq cur (cbl:list-set cur idx val))
        (if (assoc sfx slots)
          (setq slots (subst (cons sfx cur) (assoc sfx slots) slots))
          (setq slots (cons (cons sfx cur) slots))))))
  ;; numeric sort of suffixes (PIN10 after PIN9, never string sort)
  (setq slots (vl-sort slots '(lambda (a b) (< (car a) (car b)))))
  (foreach s slots
    (if (or (/= (nth 0 (cdr s)) "")
            (/= (nth 1 (cdr s)) "")
            (/= (nth 2 (cdr s)) ""))
      (setq rows (append rows (list (cdr s))))))
  rows)

;;; ---------------------- project-wide merge -------------------------
;;; cbl:*cables* : list of (tag name mfg cat loc (dwg ...) (row ...))

(defun cbl:merge-cable (tag atts rows dwg / rec name mfg cat loc dwgs rws)
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
  ;; union conductor rows, dedupe identical (wire color pin) triples;
  ;; spare-token / blank-wire rows are NOT merged across instances
  ;; unless literally identical in all three fields
  (foreach r rows
    (if (not (member r rws)) (setq rws (append rws (list r)))))
  (setq cbl:*cables*
        (cons (list tag name mfg cat loc dwgs rws)
              (vl-remove-if '(lambda (x) (= (car x) tag)) cbl:*cables*))))

;;; ---------------------- drawing scanners ---------------------------

(defun cbl:scan-doc (doc dwg / ms cnt hits atts ctag)
  ;; works identically on the active document and on a DBX document
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
            (cbl:merge-cable ctag atts (cbl:rows-from-atts atts) dwg))))))
  (princ (strcat "\n  " (cbl:pad dwg 24) (itoa cnt)
                 " attributed insert(s), " (itoa hits) " cable marker(s)"))
  T)

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

(defun c:CABLESCAN ( / mode src dir files datafile actdoc actpath
                       dbx f ff res okc skc rec rows)
  (vl-load-com)
  (setq cbl:*cables* nil)
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
     (setq actdoc  (vla-get-ActiveDocument (vlax-get-acad-object))
           actpath (strcase (strcat (vla-get-Path actdoc) "\\"
                                    (vla-get-Name actdoc)))
           dbx nil okc 0 skc 0)
     (foreach f files
       (setq ff (findfile f))
       (cond
         ((null ff)
          (setq skc (1+ skc))
          (princ (strcat "\n  SKIP (not found): " f)))
         ((= (strcase ff) actpath)
          ;; ObjectDBX cannot open the file we are sitting in
          (cbl:scan-doc actdoc (vl-filename-base ff))
          (setq okc (1+ okc)))
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

(defun cbl:sort-rows (rows / allnum pinned unpinned)
  ;; Sort by pin when EVERY non-empty pin is numeric (distof).
  ;; Pin order is NEVER inferred from wire-number order. Rows without
  ;; pins (incl. spares) follow in extraction order.
  (setq allnum T)
  (foreach r rows
    (if (and (/= (cbl:trim (caddr r)) "")
             (null (distof (caddr r) 2)))
      (setq allnum nil)))
  (setq pinned   (vl-remove-if
                   '(lambda (r) (= (cbl:trim (caddr r)) "")) rows)
        unpinned (vl-remove-if-not
                   '(lambda (r) (= (cbl:trim (caddr r)) "")) rows))
  (if (and allnum pinned)
    (append (vl-sort pinned
                     '(lambda (a b)
                        (< (distof (caddr a) 2) (distof (caddr b) 2))))
            unpinned)
    rows))

(defun cbl:layout-cells (rec / cells y dy n s srows r wire c2)
  ;; -> list of (attdef-tag text x y), local block coordinates,
  ;; first line at y=0 running downward
  (setq dy (* cbl:cfg-text-height cbl:cfg-row-factor)
        y  0.0
        n  0)
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
  (setq srows (cbl:sort-rows (nth 6 rec))
        n     0)
  (foreach r srows
    (setq n (1+ n))
    (setq wire (cond ((= (cbl:trim (car r)) "") "(SPARE)")
                     ((cbl:spare-token-p (car r)) "(SPARE)")
                     (T (car r))))
    (setq c2 (cbl:trim
               (strcat (cadr r)
                       (if (/= (cbl:trim (caddr r)) "")
                         (strcat "  pin " (caddr r))
                         ""))))
    (setq cells (cons (list (strcat "W" (itoa n)) wire 0.0 y) cells))
    (setq cells (cons (list (strcat "C" (itoa n)) c2
                            cbl:cfg-col2-offset y)
                      cells))
    (setq y (- y dy)))
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

(defun c:CABLEPLACE ( / df pt topy curx cury placed rec cells nlines
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
     (load df)
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
              (setq cells  (cbl:layout-cells rec)
                    nlines (+ 4 (length (nth 6 rec)))
                    bh     (* nlines dy))
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
