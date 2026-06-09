;;; ============================================================
;;; CableCensus.lsp — zero-config attribute discovery for
;;; AutoCAD Electrical drawing sets.
;;;
;;; You do NOT need to click any cable or know any attribute tag.
;;; One command batch-reads every drawing (nothing visibly opens),
;;; records every attributed block it finds, and then:
;;;
;;;   1. writes attribute-census.csv  (drawing, block, tag, value)
;;;   2. prints a per-block summary of tags with sample values
;;;   3. flags which block/attribute combos look like cable tags
;;;      (values matching CBL*) and prints a suggested CONFIG
;;;      for CableReport.lsp
;;;
;;; Usage:  (load "C:/path/CableCensus.lsp") at the command line
;;;         (no APPLOAD needed), run CABLECENSUS, pick Project (.wdp)
;;;         or Folder, then send attribute-census.csv back.
;;; ============================================================

(vl-load-com)

;; Value pattern that marks an attribute as a cable identifier
(setq *census-pattern* "CBL*")

;; ---------------- helpers ----------------

(defun census:trim (s) (vl-string-trim " \t\r\n" s))

(defun census:basename (p) (strcat (vl-filename-base p) ".dwg"))

(defun census:dbx-progid ()
  (strcat "ObjectDBX.AxDbDocument." (itoa (atoi (getvar "ACADVER")))))

(defun census:effname (obj / r)
  (setq r (vl-catch-all-apply 'vla-get-EffectiveName (list obj)))
  (if (vl-catch-all-error-p r) (vla-get-Name obj) r))

(defun census:attrs (obj / r)
  ;; list of (TAG . value), tags upper-cased; nil on failure
  (setq r (vl-catch-all-apply 'vlax-invoke (list obj 'GetAttributes)))
  (if (vl-catch-all-error-p r)
      nil
      (mapcar '(lambda (a) (cons (strcase (vla-get-TagString a))
                                 (vla-get-TextString a)))
              r)))

(defun census:replace-all (s find rep / pos out flen)
  (setq out "" flen (strlen find))
  (while (setq pos (vl-string-search find s))
    (setq out (strcat out (substr s 1 pos) rep)
          s   (substr s (+ pos flen 1))))
  (strcat out s))

(defun census:csv-esc (s)
  (if (or (vl-string-search "," s)
          (vl-string-search "\"" s)
          (vl-string-search "\n" s))
      (strcat "\"" (census:replace-all s "\"" "\"\"") "\"")
      s))

(defun census:join (lst sep / out)
  (setq out "")
  (foreach x lst
    (setq out (if (= out "") x (strcat out sep x))))
  out)

(defun census:unique (lst / out)
  (foreach x lst
    (if (not (member x out)) (setq out (append out (list x)))))
  out)

;; ---------------- per-drawing scan ----------------

(defun census:tally (bname tag val / key rec samples)
  ;; *census-stats*: ((bname . tag) count samples)
  (setq key (cons bname tag)
        rec (assoc key *census-stats*))
  (if rec
      (progn
        (setq samples (caddr rec))
        (if (and (/= (census:trim val) "")
                 (< (length samples) 3)
                 (not (member val samples)))
            (setq samples (append samples (list val))))
        (setq *census-stats*
              (subst (list key (1+ (cadr rec)) samples) rec *census-stats*)))
      (setq *census-stats*
            (append *census-stats*
                    (list (list key 1
                                (if (/= (census:trim val) "") (list val) nil))))))
  ;; remember (block . tag) combos whose values look like cable tags
  (if (and (wcmatch (strcase val) (strcase *census-pattern*))
           (not (member key *census-cabletags*)))
      (setq *census-cabletags* (append *census-cabletags* (list key)))))

(defun census:scan-doc (doc dwg csvf / obj bname n)
  (setq n 0)
  (vlax-for obj (vla-get-ModelSpace doc)
    (if (and (= (vla-get-ObjectName obj) "AcDbBlockReference")
             (= :vlax-true (vla-get-HasAttributes obj)))
        (progn
          (setq bname (census:effname obj))
          (foreach a (census:attrs obj)
            (setq n (1+ n))
            (write-line
              (strcat (census:csv-esc dwg) ","
                      (census:csv-esc bname) ","
                      (census:csv-esc (car a)) ","
                      (census:csv-esc (cdr a)))
              csvf)
            (census:tally bname (car a) (cdr a))))))
  (princ (strcat " " (itoa n) " attribute(s)")))

;; ---------------- drawing list sources ----------------

(defun census:wdp-files (wdp / f line files dir c1)
  ;; Heuristic parse of an AcadE project file: keep lines that look like
  ;; drawing entries, skip directive lines.
  (setq dir (vl-filename-directory wdp)
        files nil
        f (open wdp "r"))
  (if f
      (progn
        (while (setq line (read-line f))
          (setq line (census:trim line))
          (if (> (strlen line) 0)
              (progn
                (setq c1 (substr line 1 1))
                (if (not (member c1 '("+" "=" "?" "*" ";" "[" "~")))
                    (progn
                      (if (not (wcmatch (strcase line) "*`.DWG"))
                          (setq line (strcat line ".dwg")))
                      (if (not (or (= (substr line 2 1) ":")
                                   (= (substr line 1 2) "\\\\")))
                          (setq line (strcat dir "\\" line)))
                      (setq files (append files (list line))))))))
        (close f)))
  files)

;; ---------------- report ----------------

(defun census:report (csvpath / bnames rec bn tags)
  (princ "\n\n================ ATTRIBUTE CENSUS ================")
  (setq bnames nil)
  (foreach rec *census-stats*
    (if (not (member (caar rec) bnames))
        (setq bnames (append bnames (list (caar rec))))))
  (foreach bn bnames
    (princ (strcat "\n\nBLOCK: " bn))
    (foreach rec *census-stats*
      (if (= (caar rec) bn)
          (princ (strcat "\n   " (cdar rec)
                         "  (x" (itoa (cadr rec)) ")"
                         (if (caddr rec)
                             (strcat "   e.g. " (census:join (caddr rec) " | "))
                             ""))))))
  (if *census-cabletags*
      (progn
        (princ (strcat "\n\n--- LIKELY CABLE IDENTIFIERS (values match "
                       *census-pattern* ") ---"))
        (foreach rec *census-cabletags*
          (princ (strcat "\n   block " (car rec)
                         "  ->  attribute " (cdr rec))))
        (princ "\n\nSuggested CONFIG line for CableReport.lsp:")
        (princ (strcat "\n   (setq *cbl-tag-attrs* '("
                       (census:join
                         (mapcar '(lambda (s) (strcat "\"" s "\""))
                                 (census:unique (mapcar 'cdr *census-cabletags*)))
                         " ")
                       "))")))
      (princ (strcat "\n\nNo attribute values matched " *census-pattern*
                     " — if your cables use a different prefix, edit"
                     "\n*census-pattern* at the top of CableCensus.lsp and rerun.")))
  (princ (strcat "\n\nFull dump: " csvpath))
  (princ "\nSend that CSV back and the CableReport CONFIG can be locked to your real blocks.")
  (princ))

;; ---------------- main command ----------------

(defun c:CABLECENSUS (/ mode pick wdp dir files csvpath csvf activepath f dbx r)
  (vl-load-com)
  (setq *census-stats* nil
        *census-cabletags* nil)
  (initget "Project Folder")
  (setq mode (cond ((getkword "\nCensus drawings from [Project/Folder] <Folder>: "))
                   ("Folder")))
  (if (= mode "Project")
      (progn
        (setq wdp (getfiled "Select AcadE project file" "" "wdp" 0))
        (if wdp
            (setq files (census:wdp-files wdp)
                  dir   (vl-filename-directory wdp))))
      (progn
        (setq pick (getfiled "Pick ANY drawing in the folder to census" "" "dwg" 0))
        (if pick
            (setq dir   (vl-filename-directory pick)
                  files (mapcar '(lambda (f) (strcat dir "\\" f))
                                (vl-directory-files dir "*.dwg" 1))))))
  (cond
    ((not files)
     (princ "\nNothing to scan."))
    (t
     (setq csvpath (strcat dir "\\attribute-census.csv")
           csvf    (open csvpath "w"))
     (if (not csvf)
         (princ (strcat "\nCannot write " csvpath))
         (progn
           (write-line "drawing,block,tag,value" csvf)
           (setq activepath (strcase (strcat (getvar "DWGPREFIX")
                                             (getvar "DWGNAME"))))
           (foreach f files
             (princ (strcat "\nScanning " (census:basename f) " ..."))
             (cond
               ((= (strcase f) activepath)
                (census:scan-doc
                  (vla-get-ActiveDocument (vlax-get-acad-object))
                  (census:basename f) csvf))
               ((not (findfile f))
                (princ " MISSING"))
               (t
                (setq dbx (vl-catch-all-apply
                            'vla-GetInterfaceObject
                            (list (vlax-get-acad-object) (census:dbx-progid))))
                (if (vl-catch-all-error-p dbx)
                    (princ " (ObjectDBX unavailable)")
                    (progn
                      (setq r (vl-catch-all-apply 'vla-Open (list dbx f)))
                      (if (vl-catch-all-error-p r)
                          (princ " SKIPPED (open failed)")
                          (census:scan-doc dbx (census:basename f) csvf))
                      (vlax-release-object dbx))))))
           (close csvf)
           (census:report csvpath)))))
  (princ))

(princ "\nCableCensus loaded. Command: CABLECENSUS")
(princ)
