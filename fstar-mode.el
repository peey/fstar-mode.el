;;; fstar-mode.el --- Support for F* programming -*- lexical-binding: t -*-

;; Copyright (C) 2015 Clément Pit-Claudel
;; Author: Clément Pit--Claudel <clement.pitclaudel@live.com>
;; URL: https://github.com/FStarLang/fstar.el

;; Created: 27 Aug 2015
;; Version: 0.4
;; Package-Requires: ((emacs "24.3") (dash "2.11") (company "0.8.12"))
;; Keywords: convenience, languages

;; This file is not part of GNU Emacs.

;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;; http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

;;; Commentary:

;; This file implements support for F* programming in Emacs, including:
;;
;; * Syntax highlighting
;; * Unicode math (with prettify-symbols-mode)
;; * Indentation
;; * Real-time verification (requires the Flycheck package)
;; * Interactive proofs (à la Proof-General)
;;
;; See https://github.com/FStarLang/fstar-mode.el for setup and usage tips.

;;; Code:

;;; Imports

(require 'dash)
(require 'cl-lib)
(require 'eldoc)
(require 'help-at-pt)
(require 'company)
(require 'flycheck nil t)

;;; Compatibility

(defmacro fstar-assert (&rest args)
  "Call `cl-assert' on ARGS, if available."
  (declare (debug t))
  `(when (fboundp 'cl-assert)
     (cl-assert ,@args)))

(eval-and-compile
  (unless (featurep 'subr-x)
    (defsubst string-trim-left (string)
      "Remove leading whitespace from STRING."
      (if (string-match "\\`[ \t\n\r]+" string)
          (replace-match "" t t string)
        string))
    (defsubst string-trim-right (string)
      "Remove trailing whitespace from STRING."
      (if (string-match "[ \t\n\r]+\\'" string)
          (replace-match "" t t string)
        string))
    (defsubst string-trim (string)
      "Remove leading and trailing whitespace from STRING."
      (string-trim-left (string-trim-right string)))))

;;; Group

(defgroup fstar nil
  "F* mode."
  :group 'languages)

;;; Customization

(defcustom fstar-executable "fstar.exe"
  "Full path to the fstar.exe binary."
  :group 'fstar
  :type 'file
  :risky t)

(defconst fstar-known-modules
  '((font-lock   . "Syntax highlighting")
    (prettify    . "Unicode math (e.g. display forall as ∀; requires emacs 24.4 or later)")
    (indentation . "Indentation (based on control points)")
    (comments    . "Comment syntax and special comments ('(***', '(*+', etc.)")
    (flycheck    . "Real-time verification (good for small files; requires Flycheck)")
    (interactive . "Interactive verification (à la Proof-General)")
    (eldoc       . "Type annotations in the minibuffer.")
    (company     . "Completion with company-mode."))
  "Available components of F*-mode.")

(defcustom fstar-enabled-modules
  '(font-lock prettify indentation comments interactive eldoc company)
  "Which F*-mode components to load."
  :group 'fstar
  :type `(set ,@(cl-loop for (mod . desc) in fstar-known-modules
                         collect `(const :tag ,desc ,mod))))

;;; Debugging

(defvar fstar-debug nil
  "If non-nil, print debuging information in interactive mode.")

(defun fstar-toggle-debug ()
  "Toggle `fstar-debug'."
  (interactive)
  (message "F*: Debugging %s."
           (if (setq-default fstar-debug (not fstar-debug)) "enabled" "disabled")))

(define-obsolete-variable-alias 'fstar-subp-debug 'fstar-debug "0.4")
(define-obsolete-function-alias 'fstar-subp-toggle-debug 'fstar-toggle-debug "0.4")

(defun fstar--log (format &rest args)
  "Log a message, conditional on `fstar-debug'.

FORMAT and ARGS are as in `message'."
  (with-current-buffer (get-buffer-create "*fstar-debug*")
    (goto-char (point-max))
    (setq-local window-point-insertion-type t)
    (insert (apply #'format format args) "\n")))

(defmacro fstar-log (format &rest args)
  "Log a message, conditional on `fstar-debug'.

FORMAT and ARGS are as in `message'."
  (declare (debug t))
  `(when fstar-debug
     (fstar--log ,format ,@args)))

;;; Compatibility across F* versions

(defun fstar-find-executable ()
  "Compute the absolute path to the F* executable.
Check that the binary exists and is executable; if not, raise an
error."
  (let ((prog-abs (and fstar-executable (executable-find fstar-executable))))
    (unless (and prog-abs (file-exists-p prog-abs))
      (user-error "F* executable not found; please set `fstar-executable'"))
    (unless (file-executable-p prog-abs)
      (user-error "F* executable not executable; please check the value of `fstar-executable'"))
    prog-abs))

(defvar-local fstar--vernum nil
  "F*'s version number.")

(defvar-local fstar-compat--error-messages-use-absolute-linums nil
  "F* > 0.9.3.0-beta1 uses absolute line numbers in error messages.")

(defvar-local fstar-compat--can-use-info nil
  "F* >= 0.9.4.1 supports #info queries.")

(defun fstar--init-compatibility-layer ()
  "Adjust compatibility settings based on `fstar-executable''s version number."
  (let* ((version-string (car (process-lines (fstar-find-executable) "--version"))))
    (if (string-match "F\\* \\([- .[:alnum:]]+\\)" version-string)
        (setq fstar--vernum (match-string 1 version-string))
      (warn "Can't parse version number from %S" version-string)
      (setq fstar--vernum "unknown")))
  (let ((v (if (string-match-p "unknown" fstar--vernum) "1000" fstar--vernum)))
    (setq fstar-compat--error-messages-use-absolute-linums (version< "0.9.3.0-beta1" v))
    (setq fstar-compat--can-use-info (version<= "0.9.4.1" v))))

;;; Flycheck

(defconst fstar-error-patterns
  (let ((fstar-pat '((message) "near line " line ", character " column " in file " (file-name)))
        (z3-pat  '((file-name) "(" line "," column "-" (+ (any digit)) "," (+ (any digit)) ")"
                   (* (any ": ")) (? "Error" (* (any " \n")))
                   (message))))
    `((error "ERROR: " ,@fstar-pat)
      (warning "WARNING: " ,@fstar-pat)
      (error ,@z3-pat))))

(when (featurep 'flycheck)
  (defvaralias 'flycheck-fstar-executable 'fstar-executable)
  (make-obsolete-variable 'flycheck-fstar-executable 'fstar-executable "0.2" 'set)

  (flycheck-define-command-checker 'fstar
    "Flycheck checker for F*."
    :command '("fstar.exe" source-inplace)
    :error-patterns fstar-error-patterns
    :error-filter #'flycheck-increment-error-columns
    :modes '(fstar-mode))

  (add-to-list 'flycheck-checkers 'fstar))

(defun fstar-setup-flycheck ()
  "Prepare Flycheck for use with F*."
  (if (featurep 'flycheck)
      (flycheck-mode)
    (warn "Please install the Flycheck package to get real-time verification")))

;;; Build config

(defconst fstar-build-config-header "(*--build-config")
(defconst fstar-build-config-footer "--*)")

;;; Prettify symbols

(defcustom fstar-symbols-alist '(("exists" . ?∃) ("forall" . ?∀) ("fun" . ?λ)
                                 ("nat" . ?ℕ) ("int" . ?ℤ)
                                 ("True" . ?⊤) ("False" . ?⊥)
                                 ("*" . ?×) (":=" . ?≔) ("::" . ?⸬)
                                 ("<=" . ?≤) (">=" . ?≥) ("<>" . ?≠)
                                 ("/\\" . ?∧) ("\\/" . ?∨) ("~" . ?¬)
                                 ("<==>" . ?⟺) ("==>" . ?⟹) ;; ("<==" . ?⟸)
                                 ("->" . ?→) ("~>" . ?↝) ("=>" . ?⇒)
                                 ("<<" . ?≪) ;; (">>" . ?≫)
                                 ("<|" . ?◃) ("|>" . ?▹) ;; ("<||" . ?⧏) ("||>" . ?⧐)
                                 ;; ("(|" . ?⦅) ("|)" . ?⦆)
                                 ("'a" . ?α) ("'b" . ?β) ("'c" . ?γ)
                                 ("'d" . ?δ) ("'e" . ?ε))
  "Fstar symbols."
  :group 'fstar
  :type 'alist)

(defun fstar-setup-prettify ()
  "Setup prettify-symbols for use with F*."
  (when (and (boundp 'prettify-symbols-alist)
             (fboundp 'prettify-symbols-mode))
    (setq-local prettify-symbols-alist (append fstar-symbols-alist
                                               prettify-symbols-alist))
    (prettify-symbols-mode)))

;;; Font-Lock

;; Loosely derived from https://github.com/FStarLang/atom-fstar/blob/master/grammars/fstar.cson

(defconst fstar-syntax-structure
  (regexp-opt '("begin" "end"
                "let" "rec" "in" "val"
                "kind" "type" "logic" "new" "abstract"
                "unfold" "irreducible" "inline_for_extraction" "noeq" "noextract"
                "private" "opaque" "total" "default" "reifiable" "reflectable"
                "open" "module" "include")
              'symbols))

(defconst fstar-syntax-preprocessor
  (regexp-opt '("#set-options"
                "#reset-options")
              'symbols))

(defconst fstar-syntax-keywords
  (regexp-opt '("and"
                "forall" "exists"
                "assert" "assert_norm" "assume"
                "fun" "function"
                "try" "match" "with"
                "if" "then" "else"
                "ALL" "All" "DIV" "Div" "EXN" "Ex" "Exn" "GHOST" "GTot" "Ghost"
                "Lemma" "PURE" "Pure" "Tot" "ST" "STATE" "St"
                "Unsafe" "Stack" "Heap" "StackInline" "Inline")
              'symbols))

(defconst fstar-syntax-builtins
  (regexp-opt '("requires" "ensures" "modifies" "decreases" "attributes"
                "effect" "new_effect" "sub_effect" "new_effect_for_free"
                "effect_actions")
              'symbols))

(defconst fstar-syntax-ambiguous
  (regexp-opt `("\\/" "/\\")))

;; (defconst fstar-syntax-types
;;   (regexp-opt '("Type")
;;               'symbols))

(defconst fstar-syntax-constants
  (regexp-opt '("False" "True")
              'symbols))

(defface fstar-structure-face
  '((((background light)) (:bold t))
    (t :bold t :foreground "salmon"))
  "Face used to highlight structural keywords."
  :group 'fstar)

(defface fstar-subtype-face
  '((t :italic t))
  "Face used to highlight subtyping clauses."
  :group 'fstar)

(defface fstar-attribute-face
  '((t :italic t))
  "Face used to highlight attributes."
  :group 'fstar)

(defface fstar-decreases-face
  '((t :italic t))
  "Face used to highlight decreases clauses."
  :group 'fstar)

(defface fstar-subscript-face
  '((t :height 0.8))
  "Face used to use for subscripts"
  :group 'fstar)

(defface fstar-braces-face
  '((t))
  "Face to use for { and }."
  :group 'fstar)

(defface fstar-dereference-face
  '((t :inherit font-lock-negation-char-face))
  "Face to use for !."
  :group 'fstar)

(defface fstar-ambiguous-face
  '((t :inherit font-lock-negation-char-face))
  "Face to use for /\\ and \//."
  :group 'fstar)

(defface fstar-universe-face
  '((t :foreground "forest green"))
  "Face used for universe levels and variables"
  :group 'fstar)

(defun fstar-subexpr-pre-matcher (rewind-to &optional bound-to)
  "Move past REWIND-TO th group, then return end of BOUND-TO th."
  (goto-char (match-end rewind-to))
  (match-end (or bound-to 0)))

(defconst fstar-syntax-id-unwrapped (rx (? (or "#" "'"))
                                        (any "a-z_") (* (or wordchar (syntax symbol)))
                                        (? "." (* (or wordchar (syntax symbol))))))

(defconst fstar-syntax-id (concat "\\_<" fstar-syntax-id-unwrapped "\\_>"))

(defconst fstar-syntax-cs (rx symbol-start
                              (any "A-Z") (* (or wordchar (syntax symbol)))
                              symbol-end))

(defconst fstar-syntax-universe-id-unwrapped (rx "'u" (* (or wordchar (syntax symbol)))))

(defconst fstar-syntax-universe-id (concat "\\_<" fstar-syntax-universe-id-unwrapped "\\_>"))

(defconst fstar-syntax-universe (concat "\\(" fstar-syntax-universe-id
                                        "\\|u#([^)]*)\\)"))

(defconst fstar-syntax-ids (concat "\\(" fstar-syntax-id "\\(?: +" fstar-syntax-id "\\)*\\)"))

(defconst fstar-syntax-ids-and-type (concat fstar-syntax-ids " *:"))

(defun fstar-find-id-maybe-type (bound must-find-type)
  "Find var:type or var1..varN:type pair between point and BOUND.

If MUST-FIND-TYPE is nil, the :type part is not necessary."
  (let ((found t) (rejected t)
        (regexp (if must-find-type fstar-syntax-ids-and-type fstar-syntax-ids)))
    (while (and found rejected)
      (setq found (re-search-forward regexp bound t))
      (setq rejected (and found (or (eq (char-after) ?:) ; h :: t
                                    (save-excursion
                                      (goto-char (match-beginning 0))
                                      (skip-syntax-backward "-")
                                      (or (eq (char-before) ?|) ;; | X: int
                                          (save-match-data
                                            ;; val x : Y:int
                                            (re-search-forward "\\_<\\(val\\|let\\)\\_>" (match-end 0) t))))))))
    (when (and found must-find-type)
      (ignore-errors
        (goto-char (match-end 0))
        (forward-sexp)
        (let ((md (match-data)))
          (set-match-data `(,(car md) ,(point) ,@(cddr md))))))
    found))

(defun fstar-find-id (bound)
  "Find variable name between point and BOUND."
  (fstar-find-id-maybe-type bound nil))

(defun fstar-find-id-with-type (bound)
  "Find var:type pair between point and BOUND."
  (fstar-find-id-maybe-type bound t))

(defun fstar-find-fun-and-args (bound)
  "Find lambda expression between point and BOUND."
  (let ((found))
    (while (and (not found) (re-search-forward "\\_<fun\\_>" bound t))
      (-when-let* ((mdata (match-data))
                   (fnd   (search-forward "->" bound t))) ;;FIXME
        (set-match-data `(,(car mdata) ,(match-end 0)
                          ,@mdata))
        (setq found t)))
    found))

(defun fstar-find-subtype-annotation (bound)
  "Find {...} group between point and BOUND."
  (let ((found) (end))
    (while (and (not found) (re-search-forward "{[^:].*}" bound t))
      (setq end (save-excursion
                  (goto-char (match-beginning 0))
                  (ignore-errors (forward-sexp))
                  (point)))
      (setq found (and (<= end bound)
                       (<= end (point-at-eol))
                       (save-excursion
                         (backward-char)
                         (not (looking-at-p "[^ ]+ +with"))))))
    (when found
      (set-match-data `(,(1+ (match-beginning 0)) ,(1- end))))
    found))


(defconst fstar-syntax-additional
  (let ((id fstar-syntax-id))
    `((,fstar-syntax-cs
       (0 'font-lock-type-face))
      (,fstar-syntax-universe
       (1 'fstar-universe-face))
      (,(concat "{\\(:" id "\\) *\\([^}]*\\)}")
       (1 'font-lock-builtin-face append)
       (2 'fstar-attribute-face append))
      (,(concat "\\_<\\(let\\(?: +rec\\_>\\)?\\)\\(\\(?: +" id "\\)?\\)")
       (1 'fstar-structure-face)
       (2 'font-lock-function-name-face))
      (,(concat "\\_<\\(type\\|kind\\)\\( +" id "\\)")
       (1 'fstar-structure-face)
       (2 'font-lock-function-name-face))
      (,(concat "\\_<\\(val\\) +\\(" id "\\) *:")
       (1 'fstar-structure-face)
       (2 'font-lock-function-name-face))
      (fstar-find-id-with-type
       (1 'font-lock-variable-name-face))
      (fstar-find-subtype-annotation
       (0 'fstar-subtype-face append))
      ("%\\[\\([^]]+\\)\\]"
       (1 'fstar-decreases-face append))
      ("\\_<\\(forall\\|exists\\) [^.]+\."
       (0 'font-lock-keyword-face)
       (fstar-find-id (fstar-subexpr-pre-matcher 1) nil (1 'font-lock-variable-name-face)))
      (fstar-find-fun-and-args
       (1 'font-lock-keyword-face)
       (fstar-find-id (fstar-subexpr-pre-matcher 1) nil (1 'font-lock-variable-name-face)))
      ("(\\*--\\(build-config\\)"
       (1 'font-lock-preprocessor-face prepend))
      (,fstar-syntax-ambiguous
       (0 'fstar-ambiguous-face append))
      ("!"
       (0 'fstar-dereference-face))
      ("[{}]"
       (0 'fstar-braces-face append))
      (,(concat "\\_<" fstar-syntax-id-unwrapped "\\(_\\)\\([0-9]+\\)\\_>")
       (1 '(face nil invisible 'fstar-subscripts) prepend)
       (2 '(face fstar-subscript-face display (raise -0.3)) append)))))

(defconst fstar--scratchpad-name " *%s-scratchpad*")

(defvar-local fstar--scratchpad nil
  "Temporary buffer used to highlight strings.")

(defun fstar--init-scratchpad ()
  "Get or create scratchpad buffer of current F* buffer."
  (unless fstar--scratchpad
    (setq fstar--scratchpad
          (get-buffer-create (format fstar--scratchpad-name (buffer-name))))
    (with-current-buffer fstar--scratchpad
      (setq-local fstar-enabled-modules '(font-lock prettify))
      (fstar-mode))))

(defun fstar-highlight-string (str)
  "Highlight STR as F* code."
  (fstar--init-scratchpad)
  (with-current-buffer fstar--scratchpad
    (erase-buffer)
    (insert str)
    (if (fboundp 'font-lock-ensure)
        (font-lock-ensure)
      (with-no-warnings (font-lock-fontify-buffer)))
    (buffer-string)))

(defun fstar-setup-font-lock ()
  "Setup font-lock for use with F*."
  (font-lock-mode -1)
  (setq-local
   font-lock-defaults
   `(((,fstar-syntax-constants    . 'font-lock-constant-face)
      (,fstar-syntax-keywords     . 'font-lock-keyword-face)
      (,fstar-syntax-builtins     . 'font-lock-builtin-face)
      (,fstar-syntax-preprocessor . 'font-lock-preprocessor-face)
      (,fstar-syntax-structure    . 'fstar-structure-face)
      ,@fstar-syntax-additional)
     nil nil))
  (font-lock-set-defaults)
  (add-to-invisibility-spec 'fstar-subscripts)
  (add-to-list 'font-lock-extra-managed-props 'display)
  (add-to-list 'font-lock-extra-managed-props 'invisible)
  (font-lock-mode))

(defun fstar-teardown-font-lock ()
  "Disable F*-related font-locking."
  (remove-from-invisibility-spec 'fstar-subscripts)
  (when (buffer-live-p fstar--scratchpad)
    (kill-buffer fstar--scratchpad)))

;;; Syntax table

(defvar fstar-syntax-table
  (let ((table (make-syntax-table)))
    ;; Symbols
    (modify-syntax-entry ?# "_" table)
    (modify-syntax-entry ?_ "_" table)
    (modify-syntax-entry ?' "_" table)
    ;; Punctuation
    (modify-syntax-entry ?. "." table)
    (modify-syntax-entry ?+ "." table)
    (modify-syntax-entry ?- "." table)
    (modify-syntax-entry ?= "." table)
    (modify-syntax-entry ?% "." table)
    (modify-syntax-entry ?< "." table)
    (modify-syntax-entry ?> "." table)
    (modify-syntax-entry ?& "." table)
    (modify-syntax-entry ?| "." table)
    ;; Comments and strings
    (modify-syntax-entry ?\\ "\\" table)
    (modify-syntax-entry ?\" "\"" table)
    ;; ‘/’ is handled by a `syntax-propertize-function'.  For background on this
    ;; see http://lists.gnu.org/archive/html/emacs-devel/2017-01/msg00144.html.
    ;; The comment enders are left here, since they don't match the ‘(*’ openers.
    ;; (modify-syntax-entry ?/ ". 12c" table)
    (modify-syntax-entry ?\n  ">" table)
    (modify-syntax-entry ?\^m ">" table)
    (modify-syntax-entry ?\( "()1nb" table)
    (modify-syntax-entry ?*  ". 23b" table)
    (modify-syntax-entry ?\) ")(4nb" table)
    table)
  "Syntax table for F*.")

(defconst fstar-mode-syntax-propertize-function
  (let ((opener-1 (string-to-syntax ". 1"))
        (opener-2 (string-to-syntax ". 2")))
    (syntax-propertize-rules
     ("//" (0 (let* ((pt (match-beginning 0))
                     (state (syntax-ppss pt)))
                (goto-char (match-end 0)) ;; syntax-ppss adjusts point
                (unless (or (nth 3 state) (nth 4 state))
                  (put-text-property pt (+ pt 1) 'syntax-table opener-1)
                  (put-text-property (+ pt 1) (+ pt 2) 'syntax-table opener-2)
                  (ignore (goto-char (point-at-eol))))))))))

;;; Mode map

(defvar fstar-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'fstar-newline-and-indent)
    (define-key map (kbd "C-h .") #'display-local-help) ;; For Emacs < 25
    (define-key map (kbd "M-.") #'fstar-jump-to-definition)
    map))

(defun fstar-newline-and-indent (arg)
  "Call (newline ARG), and indent resulting line as the previous one."
  (interactive "*P")
  (if (save-excursion (beginning-of-line) (looking-at-p "[ \t]*$"))
      (progn (delete-region (point-at-bol) (point-at-eol))
             (newline arg)) ;; 24.3 doesn't support second argument
    (let ((indentation (current-indentation)))
      (newline arg)
      (indent-line-to indentation))))

(put 'fstar-newline-and-indent 'delete-selection t)

;;; Indentation

(defun fstar-comment-offset ()
  "Compute offset at beginning of comment."
  (comment-normalize-vars)
  (when (fstar-in-comment-p)
    (save-excursion
      (comment-beginning)
      (- (point) (point-at-bol)))))

(defun fstar-indentation-points ()
  "Find reasonable indentation points on the current line."
  (let ((points)) ;; FIXME first line?
    (save-excursion
      (forward-line -1)
      (while (re-search-forward "\\s-+" (point-at-eol) t)
        (push (current-column) points)))
    (when points
      (let ((mn (apply #'min points)))
        (push (+ 2 mn) points)
        (push (+ 4 mn) points)))
    (push 0 points)
    (push 2 points)
    (-when-let* ((comment-offset (fstar-comment-offset)))
      (setq points (-filter (lambda (pt) (>= pt comment-offset))
                            (cons comment-offset points))))
    (-distinct (sort points #'<))))

(defun fstar-indent ()
  "Cycle between vaguely relevant indentation points."
  (interactive)
  (let* ((current-ind (current-indentation))
         (points      (fstar-indentation-points))
         (remaining   (-filter (lambda (x) (> x current-ind)) points))
         (target      (car (or remaining points))))
    (if (> (current-column) current-ind)
        (save-excursion (indent-line-to target))
      (indent-line-to target))))

(defun fstar-setup-indentation ()
  "Setup indentation for F*."
  (setq-local indent-line-function #'fstar-indent)
  (when (boundp 'electric-indent-inhibit) ; Emacs ≥ 24.4
    (setq-local electric-indent-inhibit t)))

;;; Interactive proofs (fstar-subp)

(defconst fstar-subp--success "ok")
(defconst fstar-subp--failure "nok")
(defconst fstar-subp--done "\n#done-")

(defconst fstar-subp--cancel "#pop\n")
(defconst fstar-subp--footer "\n#end #done-ok #done-nok\n")

(defconst fstar-subp-statuses '(pending busy processed))

(defvar-local fstar-subp--process nil
  "Interactive F* process running in the background.")

(defvar-local fstar-subp--continuation nil
  "Indicates which continuation to run on next output from F* subprocess.")

(defvar fstar-subp--lax nil
  "Whether to process newly sent regions in lax mode.")

(defface fstar-subp-overlay-pending-face
  '((((background light)) :background "#AD7FA8")
    (((background dark))  :background "#5C3566"))
  "Face used to highlight pending sections of the buffer."
  :group 'fstar)

(defface fstar-subp-overlay-pending-lax-face
  '((t :inherit fstar-subp-overlay-pending-face))
  "Face used to highlight pending lax sections of the buffer."
  :group 'fstar)

(defface fstar-subp-overlay-busy-face
  '((((background light)) :background "mistyrose")
    (((background dark))  :background "mediumorchid"))
  "Face used to highlight busy sections of the buffer."
  :group 'fstar)

(defface fstar-subp-overlay-busy-lax-face
  '((t :inherit fstar-subp-overlay-busy-face))
  "Face used to highlight busy lax sections of the buffer."
  :group 'fstar)

(defface fstar-subp-overlay-processed-face
  '((((background light)) :background "#EAF8FF")
    (((background dark))  :background "darkslateblue"))
  "Face used to highlight processed sections of the buffer."
  :group 'fstar)

(defface fstar-subp-overlay-processed-lax-face
  '((((background light)) :background "#E5E7E9")
    (((background dark))  :background "lightgrey"))
  "Face used to highlight processed lax-checked sections of the buffer."
  :group 'fstar)

(defface fstar-subp-overlay-error-face
  '((t :underline (:color "red" :style wave)))
  "Face used to highlight errors."
  :group 'fstar)

(defface fstar-subp-overlay-warning-face
  '((t :underline (:color "orange" :style wave)))
  "Face used to highlight warnings."
  :group 'fstar)

(defmacro fstar-subp-with-process-buffer (proc &rest body)
  "If PROC is non-nil, move to PROC's buffer to eval BODY."
  (declare (indent defun) (debug t))
  `(-when-let* ((procp    ,proc)
                (buf      (process-buffer ,proc))
                (buflivep (buffer-live-p buf)))
     (with-current-buffer buf
       ,@body)))

(defmacro fstar-subp-with-source-buffer (proc &rest body)
  "If PROC is non-nil, move to parent buffer of PROC to eval BODY."
  (declare (indent defun) (debug t))
  `(-when-let* ((procp    ,proc)
                (buf      (process-get ,proc 'fstar-subp-source-buffer))
                (buflivep (buffer-live-p buf)))
     (with-current-buffer buf
       ,@body)))

;;;; Utilities

(defun fstar-in-comment-p ()
  "Return non-nil if point is inside a comment."
  (nth 4 (syntax-ppss)))

(defun fstar-in-build-config-p ()
  "Return non-nil if point is in build config comment."
  (let ((state (syntax-ppss)))
    (and (nth 4 state)
         (save-excursion
           (goto-char (nth 8 state))
           (looking-at-p (regexp-quote fstar-build-config-header))))))

(defun fstar-subp--column-number-at-pos (pos)
  "Return column number at POS."
  (save-excursion (goto-char pos) (- (point) (point-at-bol))))

(defun fstar--goto (line column)
  "Go to position indicated by LINE, COLUMN."
  (goto-char (point-min))
  (forward-line (1- line))
  ;; min makes sure that we don't spill to the next line.
  (forward-char (min (- (point-at-eol) (point-at-bol)) column)))

(defun fstar--row-col-offset (line column)
  "Convert a (LINE, COLUMN) pair into a buffer offset.

FIXME: This would be much easier if the interactive mode returned
an offset instead of a line an column.
FIXME: This doesn't do error handling."
  (save-excursion
    (fstar--goto line column)
    (point)))

(defun fstar--match-strings-no-properties (ids str)
  "Get (match-string-no-properties ID STR) for each ID in IDS."
  (mapcar (lambda (num) (match-string-no-properties num str)) ids))

(defconst fstar--fqn-at-point-syntax-table
  (let ((tbl (make-syntax-table fstar-syntax-table)))
    (modify-syntax-entry ?. "_" tbl)
    tbl))

(defun fstar--fqn-at-point (pos)
  "Return symbol at POS."
  (with-syntax-table fstar--fqn-at-point-syntax-table
    (save-excursion
      (goto-char pos)
      (symbol-name (symbol-at-point)))))

;;;; Overlay classification

(defun fstar-subp-issue-overlay-p (overlay)
  "Return non-nil if OVERLAY is an fstar-subp issue overlay."
  (overlay-get overlay 'fstar-subp-issue))

(defun fstar-subp-issue-overlays ()
  "Find all -subp issues overlays in the current buffer."
  (-filter #'fstar-subp-issue-overlay-p (overlays-in (point-min) (point-max))))

(defun fstar-subp-issue-overlays-at (pt)
  "Find all -subp issues overlays at point PT."
  (-filter #'fstar-subp-issue-overlay-p (overlays-at pt t)))

(defun fstar-subp-tracking-overlay-p (overlay)
  "Return non-nil if OVERLAY is an fstar-subp tracking overlay."
  (fstar-subp-status overlay))

(defun fstar-subp-tracking-overlays (&optional status)
  "Find all -subp tracking overlays with status STATUS in the current buffer.

If STATUS is nil, return all fstar-subp overlays."
  (sort (cl-loop for overlay being the overlays of (current-buffer)
                 when (fstar-subp-tracking-overlay-p overlay)
                 when (or (not status) (fstar-subp-status-eq overlay status))
                 collect overlay)
        (lambda (o1 o2) (< (overlay-start o1) (overlay-start o2)))))

(defun fstar-subp-remove-tracking-overlays ()
  "Remove all F* overlays in the current buffer."
  (mapcar #'delete-overlay (fstar-subp-tracking-overlays)))

(defun fstar-subp-remove-issues-overlays ()
  "Remove all F* overlays in the current buffer."
  (mapcar #'delete-overlay (fstar-subp-issue-overlays)))

;;;; Basic subprocess operations

(defun fstar-subp-live-p (&optional proc)
  "Return t if the PROC is a live F* subprocess.
If PROC is nil, use the current buffer's `fstar-subp--process'."
  (setq proc (or proc fstar-subp--process))
  (and proc (process-live-p proc)))

(defun fstar-subp-available-p ()
  "Return t if current `fstar-subp--process' is live and idle."
  (and (fstar-subp-live-p fstar-subp--process)
       (not fstar-subp--continuation)))

(defun fstar-subp--ensure-available (error-fn)
  "Raise an error with ERROR-FN if F* isn't available."
  (when fstar-subp--continuation
    (funcall error-fn "F* seems busy; please wait until processing is complete"))
  (unless (fstar-subp-live-p)
    (funcall error-fn "Please start F* before jumping to a definition")))

(defun fstar-subp--query (query continuation)
  "Send QUERY to F* subprocess; handle results with CONTINUATION."
  (fstar-log "QUERY [%s]" query)
  (fstar-assert (not fstar-subp--continuation))
  (setq fstar-subp--continuation continuation)
  (fstar-subp-start)
  (process-send-string fstar-subp--process query))

(defun fstar-subp-find-response (proc)
  "Find full response in PROC's buffer; handle it if found."
  (goto-char (point-min))
  (when (search-forward fstar-subp--done nil t)
    (let* ((status        (cond
                           ((looking-at fstar-subp--success) t)
                           ((looking-at fstar-subp--failure) nil)
                           (t 'unknown)))
           (resp-beg      (point-min))
           (resp-end      (point-at-bol))
           (resp-real-end (point-at-eol))
           (response      (string-trim (buffer-substring resp-beg resp-end))))
      (fstar-log "RESPONSE [%s] [%s]" status response)
      (delete-region resp-beg resp-real-end)
      (when (fstar-subp-live-p proc)
        (fstar-subp-with-source-buffer proc
          (unless (booleanp status)
            (fstar-subp-kill)
            (error "Unknown status [%s] from F* subprocess (response was [%s])"
                   status response))
          (fstar-subp-process-response status response))))))

(defun fstar-subp-process-response (success response)
  "Process SUCCESS and RESPONSE from F* subprocess."
  (let* ((source-buffer (current-buffer))
         (continuation fstar-subp--continuation))
    (unless continuation
      (fstar-subp-kill)
      (error "Invalid state: Received output, but no continuation was registered"))
    (setq fstar-subp--continuation nil)
    (unwind-protect
        (funcall continuation success response)
      (run-with-timer 0 nil #'fstar-subp-process-queue source-buffer))))

(defun fstar-subp-warn-unexpected-output (string)
  "Warn user about unexpected output STRING."
  (message "F*: received unexpected output from subprocess (%s)" string))

(defun fstar-subp-filter (proc string)
  "Handle PROC's output (STRING)."
  (when string
    (fstar-log "OUTPUT [%s]" string)
    (if (fstar-subp-live-p proc)
        (fstar-subp-with-process-buffer proc
          (goto-char (point-max))
          (insert string)
          (fstar-subp-find-response proc))
      (run-with-timer 0 nil #'fstar-subp-warn-unexpected-output string))))

(defun fstar-subp-sentinel (proc signal)
  "Handle PROC's SIGNAL."
  (fstar-log "SENTINEL [%s] [%s]" signal (process-status proc))
  (when (or (memq (process-status proc) '(exit signal))
            (not (process-live-p proc)))
    (message "F*: subprocess exited.")
    (fstar-subp-with-source-buffer proc
      (fstar-subp-killed))))

(defun fstar-subp-killed ()
  "Clean up current source buffer."
  (fstar-subp-with-process-buffer fstar-subp--process
    (kill-buffer))
  (fstar-subp-remove-tracking-overlays)
  (fstar-subp-remove-issues-overlays)
  (setq fstar-subp--continuation nil
        fstar-subp--process nil))

(defun fstar-subp-kill ()
  "Kill F* subprocess and clean up current buffer."
  (interactive)
  (when (fstar-subp-live-p)
    (kill-process fstar-subp--process)
    (accept-process-output fstar-subp--process 0.25 nil t))
  (fstar-subp-killed))

(defun fstar-subp-kill-all ()
  "Kill F* subprocesses in all buffers."
  (interactive)
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf) ; May have been killed by previous iterations
      (with-current-buffer buf
        (when (derived-mode-p 'fstar-mode)
          (fstar-subp-kill))))))

(defun fstar-subp-kill-one-or-many (&optional arg)
  "Kill current F* subprocess.
With prefix argument ARG, kill all F* subprocesses."
  (interactive "P")
  (if (consp arg)
      (fstar-subp-kill-all)
    (fstar-subp-kill)))

(defun fstar-subp-kill-proc (proc)
  "Same as `fstar-subp-kill', but for PROC instead of `fstar-subp--process'."
  (fstar-subp-with-source-buffer proc
    (when fstar-subp--process
      (fstar-assert (eq proc fstar-subp--process))
      (fstar-subp-kill))))

;;;; Parsing and display issues

(defun fstar-subp--overlay-continuation (overlay success response)
  "Handle the results (SUCCESS and RESPONSE) of processing OVERLAY."
  (fstar-subp-remove-issues-overlays)
  (fstar-subp-parse-and-highlight-issues success response overlay)
  (if success
      (fstar-subp-set-status overlay 'processed)
    (fstar-subp-remove-unprocessed)
    (fstar-subp--query fstar-subp--cancel nil)))

(cl-defstruct fstar-issue
  level filename line-from line-to col-from col-to message)

(defconst fstar-subp-issue-location-regexp
  "\\(.*?\\)(\\([[:digit:]]+\\),\\([[:digit:]]+\\)-\\([[:digit:]]+\\),\\([[:digit:]]+\\))")

(defconst fstar-subp-issue-regexp
  (concat "^" fstar-subp-issue-location-regexp "\\s-*:\\s-*\\(.*\\)"))

(defconst fstar-subp-also-see-regexp
  (concat "(Also see: " fstar-subp-issue-location-regexp ")"))

(defun fstar-subp-parse-issue (context)
  "Construct an issue object from the current match data and CONTEXT."
  (pcase-let* ((issue-level 'error)
               (message (match-string-no-properties 6 context))
               (`(,filename ,line-from ,col-from ,line-to ,col-to)
                (or (save-match-data
                      (when (string-match fstar-subp-also-see-regexp message)
                        (prog1 (fstar--match-strings-no-properties '(1 2 3 4 5) message)
                          (setq message (substring message 0 (match-beginning 0))))))
                    (fstar--match-strings-no-properties '(1 2 3 4 5) context))))
    (pcase-dolist (`(,marker . ,level) '(("(Warning) " . warning)
                                         ("(Error) " . error)))
      (when (string-prefix-p marker message)
        (setq issue-level level)
        (setq message (substring message (length marker)))))
    (make-fstar-issue :level issue-level
                      :filename filename
                      :line-from (string-to-number line-from)
                      :col-from (string-to-number col-from)
                      :line-to (string-to-number line-to)
                      :col-to (string-to-number col-to)
                      :message message)))

(defun fstar-subp-parse-issues (response)
  "Parse RESPONSE into a list of issues."
  (let ((start 0))
    (cl-loop while (string-match fstar-subp-issue-regexp response start)
             collect (fstar-subp-parse-issue response)
             do (setq start (match-end 0)))))

(defun fstar-subp-cleanup-issue (issue ov)
  "Fixup ISSUE: include a file name, and adjust line numbers wrt OV."
  (when (member (fstar-issue-filename issue) '("unknown" "<input>"))
    (setf (fstar-issue-filename issue) (buffer-file-name))) ;; FIXME ensure we have a file name?
  (unless fstar-compat--error-messages-use-absolute-linums
    (let ((linum (1- (line-number-at-pos (overlay-start ov)))))
      (setf (fstar-issue-line-from issue) (+ (fstar-issue-line-from issue) linum))
      (setf (fstar-issue-line-to issue) (+ (fstar-issue-line-to issue) linum))))
  issue)

(defun fstar-subp-remove-issue-overlay (overlay &rest _args)
  "Remove OVERLAY."
  (delete-overlay overlay))

(defun fstar-subp--help-echo (_window object pos)
  "Concatenate -subp messages found at POS of OBJECT."
  (-when-let* ((buf (cond ((bufferp object) object)
                          ((overlayp object) (overlay-buffer object)))))
    (with-current-buffer buf
      (mapconcat (lambda (ov) (overlay-get ov 'fstar-subp-message))
                 (fstar-subp-issue-overlays-at pos)
                 "\n"))))

(defun fstar-subp-issue-face (issue)
  "Compute a face for ISSUE's overlay."
  (pcase (fstar-issue-level issue)
    (`error 'fstar-subp-overlay-error-face)
    (`warning 'fstar-subp-overlay-warning-face)))

(defun fstar-subp-highlight-issue (issue)
  "Highlight ISSUE in current buffer."
  (let* ((from (fstar--row-col-offset (fstar-issue-line-from issue)
                                      (fstar-issue-col-from issue)))
         (to (fstar--row-col-offset (fstar-issue-line-to issue)
                                    (fstar-issue-col-to issue)))
         (overlay (make-overlay from (max to (1+ from)) (current-buffer) t nil)))
    (overlay-put overlay 'fstar-subp-issue t)
    (overlay-put overlay 'face (fstar-subp-issue-face issue))
    (overlay-put overlay 'help-echo #'fstar-subp--help-echo)
    (overlay-put overlay 'fstar-subp-message (fstar-issue-message issue))
    (overlay-put overlay 'modification-hooks '(fstar-subp-remove-issue-overlay))
    (when (fboundp 'pulse-momentary-highlight-region)
      (pulse-momentary-highlight-region from to))))

(defun fstar-subp-highlight-issues (issues)
  "Highlight ISSUES."
  (mapcar #'fstar-subp-highlight-issue issues))

(defun fstar-subp-jump-to-issue (issue)
  "Jump to ISSUE in current buffer."
  (goto-char (fstar--row-col-offset (fstar-issue-line-from issue)
                                    (fstar-issue-col-from issue))))

(defun fstar-subp--local-issue-p (issue)
  "Check if ISSUE came from the current buffer."
  (string= (expand-file-name buffer-file-name)
           (expand-file-name (fstar-issue-filename issue))))

(defun fstar-subp-parse-and-highlight-issues (success response overlay)
  "Parse issues (relative to OVERLAY) in RESPONSE and display them.
Complain if SUCCESS is nil and RESPONSE doesn't contain issues."
  (let* ((raw-issues (fstar-subp-parse-issues response))
         (issues (mapcar (lambda (i) (fstar-subp-cleanup-issue i overlay)) raw-issues))
         (partitioned (-group-by #'fstar-subp--local-issue-p issues))
         (local-issues (cdr (assq t partitioned)))
         (other-issues (cdr (assq nil partitioned))))
    (unless (or success issues)
      (warn "No issues found in response despite prover failure: [%s]" response))
    (when other-issues
      (message "F* reported issues in other files: [%S]" other-issues))
    (fstar-log "Highlighting issues: %s" issues)
    (when local-issues
      (fstar-subp-jump-to-issue (car local-issues))
      (fstar-subp-highlight-issues local-issues)
      (display-local-help))))


;;;; Tracking and updating overlays

(defun fstar-subp-status (overlay)
  "Get status of OVERLAY."
  (overlay-get overlay 'fstar-subp-status))

(defun fstar-subp-status-eq (overlay status)
  "Check if OVERLAY has status STATUS."
  (eq (fstar-subp-status overlay) status))

(defun fstar-subp-remove-unprocessed ()
  "Remove pending and busy overlays."
  (cl-loop for overlay in (fstar-subp-tracking-overlays)
           unless (fstar-subp-status-eq overlay 'processed)
           do (delete-overlay overlay)))

(defun fstar-subp-cleanup-region (buffer beg end)
  "Make a clean copy of range BEG..END in BUFFER before sending it to F*."
  (with-temp-buffer
    (set-syntax-table fstar-syntax-table)
    (fstar-setup-comments)
    (comment-normalize-vars)
    (insert-buffer-substring buffer beg end)
    (goto-char (point-min))
    (let (start)
      (while (setq start (comment-search-forward nil t))
        (let ((skip (fstar-in-build-config-p)))
          (goto-char start)
          (forward-comment 1)
          (when (not skip)
            (save-match-data
              (let* ((comment (buffer-substring-no-properties start (point)))
                     (replacement (replace-regexp-in-string "." " " comment t t)))
                (delete-region start (point))
                (insert replacement)))))))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun fstar-subp--push-header (pos lax)
  "Prepare a header for a region starting at POS.
With non-nil LAX, the region is to be processed in lax mode."
  (format "#push %d %d%s"
          (line-number-at-pos pos)
          (fstar-subp--column-number-at-pos pos)
          (if lax " #lax" "")))

(defun fstar-subp-send-region (beg end lax continuation)
  "Send the region between BEG and END to the inferior F* process.
With non-nil LAX, send region in lax mode.  Handle results with CONTINUATION."
  (interactive "r")
  (let* ((payload (fstar-subp-cleanup-region (current-buffer) beg end))
         (msg (concat (fstar-subp--push-header beg lax) "\n" payload fstar-subp--footer)))
    (fstar-subp--query msg continuation)))

(defun fstar-subp-overlay-attempt-modification (overlay &rest _args)
  "Allow or prevent attempts to modify OVERLAY.

Modifications are only allowed if it is safe to retract up to the beginning of the current overlay."
  (let ((inhibit-modification-hooks t))
    (when (overlay-buffer overlay) ;; Hooks can be called multiple times
      (cond
       ;; Always allow modifications in non-build-config comments
       ((fstar-in-comment-p)
        (when (fstar-in-build-config-p)
          (fstar-subp-kill)))
       ;; Allow modifications (after retracting) in pending overlays, and in
       ;; processed overlays provided that F* isn't busy
       ((or (not fstar-subp--continuation)
            (fstar-subp-status-eq overlay 'pending))
        (fstar-subp-retract-until (overlay-start overlay)))
       ;; Disallow modifications in processed overlays when F* is busy
       ((fstar-subp-status-eq overlay 'processed)
        (user-error "Cannot retract a processed section while F* is busy"))
       ;; Always disallow modifications in busy overlays
       ((fstar-subp-status-eq overlay 'busy)
        (user-error "Cannot retract a busy section"))))))

(defun fstar-subp-set-status (overlay status)
  "Set status of OVERLAY to STATUS."
  (fstar-assert (memq status fstar-subp-statuses))
  (let* ((inhibit-read-only t)
         (face-name (format "fstar-subp-overlay-%s-%sface" (symbol-name status)
                            (if (overlay-get overlay 'fstar-subp--lax) "lax-" ""))))
    (overlay-put overlay 'fstar-subp-status status)
    (overlay-put overlay 'priority -1)
    (overlay-put overlay 'face (intern face-name))
    (overlay-put overlay 'insert-in-front-hooks '(fstar-subp-overlay-attempt-modification))
    (overlay-put overlay 'modification-hooks '(fstar-subp-overlay-attempt-modification))))

(defun fstar-subp-process-overlay (overlay)
  "Send the contents of OVERLAY to the underlying F* process."
  (fstar-assert (not fstar-subp--continuation))
  (fstar-subp-start)
  (fstar-subp-set-status overlay 'busy)
  (let ((lax (overlay-get overlay 'fstar-subp--lax)))
    (fstar-subp-send-region (overlay-start overlay) (overlay-end overlay) lax
                            (apply-partially #'fstar-subp--overlay-continuation overlay))))

(defun fstar-subp-process-queue (buffer)
  "Process the next pending overlay of BUFFER, if any."
  (with-current-buffer buffer
    (fstar-subp-start)
    (unless fstar-subp--continuation
      (-if-let* ((overlay (car-safe (fstar-subp-tracking-overlays 'pending))))
          (progn (fstar-log "Processing queue")
                 (fstar-subp-process-overlay overlay))
        (fstar-log "Queue is empty %S" (mapcar #'fstar-subp-status (fstar-subp-tracking-overlays)))))))

;;;; Advancing and retracting

(defun fstar-subp-unprocessed-beginning ()
  "Find the beginning of the unprocessed buffer area."
  (or (cl-loop for overlay in (fstar-subp-tracking-overlays)
               maximize (overlay-end overlay))
      (point-min)))

(defun fstar-skip-spaces-backwards-from (point)
  "Go to POINT, skip spaces backwards, and return position."
  (save-excursion
    (goto-char point)
    (skip-chars-backward "\n\r\t ")
    (point)))

(defun fstar-subp-enqueue-until (end &optional no-error)
  "Mark region up to END busy, and enqueue the newly created overlay.

If NO-ERROR is set, do not report an error if the region is empty."
  (fstar-subp-start)
  (let ((beg (fstar-subp-unprocessed-beginning))
        (end (fstar-skip-spaces-backwards-from end)))
    (fstar-assert (cl-loop for overlay in (overlays-in beg end)
                           never (fstar-subp-tracking-overlay-p overlay)))
    (if (<= end beg)
        (unless no-error
          (user-error "Nothing more to process!"))
      (let ((overlay (make-overlay beg end (current-buffer) nil nil)))
        (fstar-subp-set-status overlay 'pending)
        (overlay-put overlay 'fstar-subp--lax fstar-subp--lax)
        (fstar-subp-process-queue (current-buffer))))))

(defcustom fstar-subp-block-sep "\\(\\'\\|\\s-*\\(\n\\s-*\\)\\{3,\\}\\)"
  "Regular expression used when looking for source blocks."
  :group 'fstar
  :type 'string)

(defun fstar-subp-skip-comments-and-whitespace ()
  "Skip over comments and whitespace."
  (while (or (> (skip-chars-forward " \r\n\t") 0)
             (comment-forward 1))))

(defun fstar-subp-next-block-sep (bound)
  "Find the next block separator before BOUND.
Ignores separators found in comments."
  (let (pos)
    (save-excursion
      (while (and (null pos) (re-search-forward fstar-subp-block-sep bound t))
        (unless (fstar-in-comment-p)
          (setq pos (point)))))
    (when pos
      (goto-char pos))))

(defun fstar-subp-advance-next ()
  "Process buffer until `fstar-subp-block-sep'."
  (interactive)
  (fstar-subp-start)
  (goto-char (fstar-subp-unprocessed-beginning))
  (fstar-subp-skip-comments-and-whitespace)
  (-if-let* ((next-start (fstar-subp-next-block-sep nil)))
      (fstar-subp-enqueue-until next-start)
    (user-error "Cannot find a full block to process")))

(defun fstar-sub-overlay-contains-build-config (overlay)
  "Check if OVERLAY contains a build-config header."
  (save-excursion
    (save-match-data
      (goto-char (overlay-start overlay))
      (cl-loop while (re-search-forward (regexp-quote fstar-build-config-header) (overlay-end overlay) t)
               thereis (fstar-in-build-config-p)))))

(defun fstar-subp-pop-overlay (overlay)
  "Remove overlay OVERLAY and issue the corresponding #pop command."
  (fstar-assert (fstar-subp-available-p))
  (if (fstar-sub-overlay-contains-build-config overlay)
      (fstar-subp-kill)
    (fstar-subp--query fstar-subp--cancel nil))
  (delete-overlay overlay))

(defun fstar-subp-retract-one (overlay)
  "Retract OVERLAY, with some error checking."
  (cond
   ((not (fstar-subp-live-p)) (user-error "F* subprocess not started"))
   ((not overlay) (user-error "Nothing to retract"))
   ((fstar-subp-status-eq overlay 'pending) (delete-overlay overlay))
   ((fstar-subp-status-eq overlay 'busy) (user-error "Cannot retract busy region"))
   ((fstar-subp-status-eq overlay 'processed) (fstar-subp-pop-overlay overlay))))

(defun fstar-subp-retract-last ()
  "Retract last processed block."
  (interactive)
  (fstar-subp-retract-one (car-safe (last (fstar-subp-tracking-overlays)))))

(defun fstar-subp-retract-until (pos)
  "Retract blocks until POS is in unprocessed region."
  (cl-loop for overlay in (reverse (fstar-subp-tracking-overlays))
           when (> (overlay-end overlay) pos) ;; End point is not inclusive
           do (fstar-subp-retract-one overlay)))

(defun fstar-subp-advance-until (pos)
  "Submit or retract blocks to/from prover until POS."
  (fstar-subp-start)
  (save-excursion
    (goto-char (fstar-subp-unprocessed-beginning))
    (let ((found (cl-loop do (fstar-subp-skip-comments-and-whitespace)
                          while (and (< (point) pos) (fstar-subp-next-block-sep pos))
                          do (fstar-subp-enqueue-until (point))
                          collect (point))))
      (fstar-subp-enqueue-until pos found))))

(defun fstar-subp-advance-or-retract-to-point (&optional arg)
  "Advance or retract proof state to reach point.

With prefix argument ARG, when advancing, do not split region
into blocks; process it as one large block instead."
  (interactive "P")
  (fstar-subp-start)
  (let ((limit (fstar-subp-unprocessed-beginning)))
    (cond
     ((<= (point) limit) (fstar-subp-retract-until (point)))
     ((>  (point) limit) (if (consp arg)
                             (fstar-subp-enqueue-until (point))
                           (fstar-subp-advance-until (point)))))))

(defun fstar-subp-advance-or-retract-to-point-lax (&optional arg)
  "Like `fstar-subp-advance-or-retract-to-point' with ARG, in lax mode."
  (interactive "P")
  (let ((fstar-subp--lax t))
    (fstar-subp-advance-or-retract-to-point arg)))

;;;; Info queries

(defun fstar-subp--positional-info-query (pos)
  "Prepare a header for an info query at POS."
  (format "#info %s <input> %d %d\n"
          (or (fstar--fqn-at-point pos) "")
          (line-number-at-pos pos)
          (fstar-subp--column-number-at-pos pos)))

(defconst fstar-subp--info-response-regex
  "^(defined at \\(.+?\\)(\\([0-9]+\\),\\([0-9]+\\)-\\([0-9]+\\),\\([0-9]+\\)))")

(cl-defstruct fstar-pos-info
  source-file def-start def-end type)

(defun fstar-subp--info-continuation (continuation pos success response)
  "Handle the results (SUCCESS and RESPONSE) of an #info query at POS.
If response is valid, forward results to CONTINUATION.  With nil
POS, this function can also handle results of position-less #info queries."
  (if (and success
           (or (null pos) (eq (point) pos)) ;; Point didn't move since request
           (string-match fstar-subp--info-response-regex response))
      (funcall continuation
               (make-fstar-pos-info
                :source-file (match-string 1 response)
                :def-start (cons (string-to-number (match-string 2 response))
                                 (string-to-number (match-string 3 response)))
                :def-end (cons (string-to-number (match-string 4 response))
                               (string-to-number (match-string 5 response)))
                :type (string-trim (substring response (match-end 0)))))
    (funcall continuation nil)))

(defun fstar--eldoc-continuation (info)
  "Display INFO as an eldoc message."
  (when info
    (eldoc-message (fstar-highlight-string (fstar-pos-info-type info)))))

(defun fstar--eldoc-function ()
  "Issue a #info query for current point.
Results are displayed asynchronously, so this function returns
nil and the corresponding continuation calls `eldoc-message'."
  (when (and fstar-compat--can-use-info (fstar-subp-available-p))
    (fstar-subp--query (fstar-subp--positional-info-query (point))
                  (apply-partially #'fstar-subp--info-continuation
                                   #'fstar--eldoc-continuation
                                   (point)))
    ;; FIXME: use pos-tip for errors, or show errors in eldoc
    nil))

(defun fstar-setup-eldoc ()
  "Set up eldoc support."
  ;; Incompatible with Emacs < 25
  ;; (add-function :before-until (local 'eldoc-documentation-function)
  ;;               #'fstar--eldoc-function)
  (setq-local eldoc-documentation-function #'fstar--eldoc-function)
  (eldoc-mode))

(defun fstar-teardown-eldoc ()
  "Tear down eldoc support."
  ;; Incompatible with Emacs < 25
  ;; (remove-function (local 'eldoc-documentation-function)
  ;;                  #'fstar--eldoc-function)
  (kill-local-variable 'eldoc-documentation-function))

;;;; xref-like features

(defun fstar--save-point ()
  "Save current position in mark ring and xref stack."
  (push-mark nil t)
  (when (fboundp 'xref-push-marker-stack)
    (xref-push-marker-stack)))

(defun fstar--jump-to-definition-continuation (info)
  "Jump to position in INFO."
  (if info
      (pcase-let* ((target-fname (fstar-pos-info-source-file info))
                   (`(,target-row . ,target-col) (fstar-pos-info-def-start info)))
        (fstar--save-point)
        (catch 'not-found
          (unless (equal target-fname "<input>")
            (unless (file-exists-p target-fname)
              (message "File not found: %S" target-fname)
              (throw 'not-found nil))
            (find-file target-fname))
          (fstar--goto target-row target-col)
          (recenter)
          (pulse-momentary-highlight-one-line (point))))
    (message "No definition found")))

(defun fstar-jump-to-definition ()
  "Jump to definition of identifier at point, if any."
  (interactive)
  (fstar-subp--ensure-available #'user-error)
  (unless fstar-compat--can-use-info
    (user-error "This feature isn't available in F* < 0.9.4.1"))
  (fstar-subp--query (fstar-subp--positional-info-query (point))
                (apply-partially #'fstar-subp--info-continuation
                                 #'fstar--jump-to-definition-continuation
                                 (point))))

;;;; Company

(defun fstar-subp--completion-query (prefix)
  "Prepare a #completions query from PREFIX."
  (fstar-assert (not (string-match-p " " prefix)))
  (format "#completions %s #\n" prefix))

(defun fstar-subp-company--parse-candidate (line)
  "Extract a candidate from LINE."
  (unless (string= line "")
    (pcase-let ((`(,match-end ,ns ,candidate) (split-string line " ")))
      (setq match-end (string-to-number match-end))
      (add-text-properties 0 (length candidate) `(match ,match-end ns ,ns) candidate)
      candidate)))

(defun fstar-subp-company--candidates-continuation (callback success response)
  "Handle the results (SUCCESS and RESPONSE) of a #completion query for PREFIX.
CALLBACK is the company-mode asynchronous candidates callback."
  (when success
    (save-match-data
      (let* ((lines (split-string response "\n"))
             (candidates (mapcar #'fstar-subp-company--parse-candidate lines)))
        (funcall callback (delq nil candidates))))))

(defun fstar-subp-company--async-candidates (prefix callback)
  "Find completions for PREFIX and pass them to CALLBACK."
  (fstar-log "fstar-subp-company--async-candidates: %S" prefix)
  ;; (unless fstar-compat--can-use-info ;; FIXME
  ;;   (user-error "This feature isn't available in F* < ???"))
  (if (fstar-subp-available-p)
      (fstar-subp--query (fstar-subp--completion-query prefix)
                    (apply-partially #'fstar-subp-company--candidates-continuation
                                     callback))
    (funcall callback nil)))

(defun fstar-subp--positionless-info-query (fqn)
  "Prepare a header for an info query for FQN."
  (format "#info %s\n" fqn))

(defun fstar-subp-company--candidate-fqn (candidate)
  "Compute the fully qualified name of CANDIDATE."
  (let* ((ns (get-text-property 0 'ns candidate)))
    (if (string= ns "") candidate
      (concat ns "." candidate))))

(defun fstar-subp-company--async-info (candidate continuation)
  "Pass info about CANDIDATE to CONTINUATION.
If F* is busy, call CONTINUATION directly with BUSY."
  (if (fstar-subp-available-p)
      (fstar-subp--query
       (fstar-subp--positionless-info-query (fstar-subp-company--candidate-fqn candidate))
       (apply-partially #'fstar-subp--info-continuation continuation nil))
    (funcall continuation 'busy)))

(defun fstar-subp-company--meta-continuation (callback info)
  "Forward type INFO to CALLBACK.
CALLBACK is the company-mode asynchronous meta callback."
  (funcall callback (pcase info
                      (`nil nil)
                      (`busy "F* subprocess unavailable")
                      (_ (fstar-highlight-string (fstar-pos-info-type info))))))

(defun fstar-subp-company--async-meta (candidate callback)
  "Find type of CANDIDATE and pass it to CALLBACK."
  (fstar-subp-company--async-info
   candidate (apply-partially #'fstar-subp-company--meta-continuation callback)))

(defun fstar-subp-company--location-continuation (callback info)
  "Forward type INFO to CALLBACK.
CALLBACK is the company-mode asynchronous meta callback."
  (pcase info
    ((or `nil `busy) (funcall callback nil))
    (_ (pcase-let* ((fname (fstar-pos-info-source-file info))
                    (`(,row . ,col) (fstar-pos-info-def-start info)))
         (funcall callback (if (string= fname "<input>")
                               (cons (current-buffer) (fstar--row-col-offset row col))
                             (cons fname row)))))))

(defun fstar-subp-company--async-location (candidate callback)
  "Find location of CANDIDATE and pass it to CALLBACK."
  (fstar-subp-company--async-info
   candidate (apply-partially #'fstar-subp-company--location-continuation callback)))

(defun fstar-subp-company-candidates (prefix)
  "Compute candidates for PREFIX.
Briefly tries to get results synchronously to reduce flicker (see
URL https://github.com/company-mode/company-mode/issues/654), and
then returns an :async cons, as required by company-mode."
  (let ((company-callback nil)
        (results-received nil)
        (completion-results nil)
        (max-synchronous-delay 0.03)
        (start (current-time)))
    ;; Launch completion immediately, storing results in a shared reference.
    (fstar-subp-company--async-candidates
     prefix (lambda (results)
              (setq results-received t)
              (setq completion-results results)
              (when company-callback (funcall company-callback results))))
    ;; Wait for a bit, hoping to get candidates quickly.  We need a loop,
    ;; because output may come in chunks.  If `--async-candidates' returns early
    ;; (i.e. if subprocess isn't available), results-received will be t.
    (while (and (not results-received)
                (< (float-time (time-since start)) max-synchronous-delay))
      (accept-process-output fstar-subp--process 0.01 nil 0))
    ;; Check for results
    (cond
     (results-received ;; Got results in time!
      (fstar-log "Fetching %d completions for %S took %.2fms"
            (length completion-results) prefix (* 1000 (float-time (time-since start))))
      completion-results)
     (t ;; Results are late.  Set callback to company-supplied one.
      (fstar-log "Completions for %S are late" prefix)
      `(:async . ,(lambda (cb) (setq company-callback cb)))))))

(defun fstar-subp-company-backend (command &optional arg &rest _)
  "Company backend for F*.
Candidates are provided by the F* subprocess.
COMMAND, ARG: see `company-backends'."
  (interactive '(interactive))
  ;; (fstar-log "fstar-subp-company-backend: %S %S" command arg)
  (pcase command
    (`interactive
     (company-begin-backend #'fstar-subp-company-backend))
    (`prefix
     (with-syntax-table fstar--fqn-at-point-syntax-table
       (-when-let* ((prefix (company-grab-symbol)))
         (substring-no-properties prefix))))
    (`candidates
     (fstar-subp-company-candidates arg))
    (`meta
     `(:async . ,(apply-partially #'fstar-subp-company--async-meta arg)))
    (`location
     `(:async . ,(apply-partially #'fstar-subp-company--async-location arg)))
    (`sorted t)
    (`no-cache t)
    (`duplicates nil)
    (`match (get-text-property 0 'match arg))
    (`annotation (get-text-property 0 'ns arg))))

(defun fstar-setup-company ()
  "Set up Company support."
  (setq-local company-backends
              (cons #'fstar-subp-company-backend company-backends))
  (company-mode))

(defun fstar-teardown-company ()
  "Tear down Company support."
  (kill-local-variable 'company-backends)
  (company-mode -1))

;;;; Starting the F* subprocess

(defun fstar-subp-buffer-killed ()
  "Kill F* process associated to current buffer."
  (-when-let* ((proc (get-buffer-process (current-buffer))))
    (run-with-timer 0 nil #'fstar-subp-kill-proc proc)))

(defun fstar-subp-make-buffer ()
  "Create a buffer for the F* subprocess."
  (with-current-buffer (generate-new-buffer
                        (format " *F* interactive for %s*" (buffer-name)))
    (add-hook 'kill-buffer-hook #'fstar-subp-buffer-killed t t)
    (buffer-disable-undo)
    (current-buffer)))

(defcustom fstar-subp-prover-args nil
  "Used for computing arguments to pass to F* in interactive mode.

If set to a string, that string is considered to be a single
argument to pass to F*.  If set to a list of strings, each element
of the list is passed to F*.  If set to a function, that function
is called in the current buffer without arguments, and expected
to produce a string or a list of strings.

Some examples:

- (setq fstar-subp-prover-args \"--ab\") results in F* being
called as 'fstar.exe --in --ab'.

- (setq fstar-subp-prover-args '(\"--ab\" \"--cd\")) results in
F* being called as 'fstar.exe --in --ab --cd'.

- (setq fstar-subp-prover-args (lambda () '(\"--ab\" \"--cd\")))
results in F* being called as 'fstar.exe --in --ab --cd'.

To debug unexpected behaviours with this variable, try
evaluating (fstar-subp-get-prover-args).  Note that passing
multiple arguments as one string will not work: you should use
'(\"--aa\" \"--bb\"), not \"--aa --bb\""
  :group 'fstar
  :type '(repeat string))

(defun fstar-subp-get-prover-args ()
  "Compute prover arguments from `fstar-subp-prover-args'."
  (let ((args (if (functionp fstar-subp-prover-args)
                  (funcall fstar-subp-prover-args)
                fstar-subp-prover-args)))
    (cond ((listp args) args)
          ((stringp args) (list args))
          (t (user-error "Interpreting fstar-subp-prover-args led to invalid value [%s]" args)))))

(defun fstar-subp-with-interactive-args (args)
  "Return ARGS precedeed by --in and the filename of the current buffer."
  (let ((file-name
         (if (eq system-type 'cygwin)
             (string-trim-right
              (shell-command-to-string
               (format "cygpath -w %s" buffer-file-name)))
           buffer-file-name)))
    (append `(,file-name "--in") args)))

(defun fstar-subp-adjust-path (fn buf prog args)
  "Run FN with PATH extended to contain directory of PROG.
Forward BUF, PROG, and ARGS to FN."
  (let* ((prog-dir (file-name-directory prog))
         (path (concat prog-dir path-separator (getenv "PATH")))
         (process-environment (cons (concat "PATH=" path) process-environment)))
    (funcall fn buf prog args)))

(defun fstar-subp-start-process (buf prog args)
  "Start an F* subprocess PROG in BUF with ARGS."
  (apply #'start-process "F* interactive" buf prog args))

(defun fstar-subp-start ()
  "Start an F* subprocess attached to the current buffer, if none exists."
  (unless (and buffer-file-name (file-exists-p buffer-file-name))
    (error "Can't start F* subprocess without a backing file (save this buffer first)"))
  (unless fstar-subp--process
    (let ((prog-abs (fstar-find-executable)))
      (fstar--init-compatibility-layer)
      (let* ((buf (fstar-subp-make-buffer))
             (process-connection-type nil)
             (args (fstar-subp-with-interactive-args (fstar-subp-get-prover-args)))
             (proc (fstar-subp-start-process buf prog-abs args)))
        (fstar-log "Started F* interactive: %S" (cons prog-abs args))
        (set-process-query-on-exit-flag proc nil)
        (set-process-filter proc #'fstar-subp-filter)
        (set-process-sentinel proc #'fstar-subp-sentinel)
        (process-put proc 'fstar-subp-source-buffer (current-buffer))
        (setq fstar-subp--process proc)))))

;;;; Keybindings

(defconst fstar-subp-keybindings-table
  '(("C-c C-n"        "C-S-n" fstar-subp-advance-next)
    ("C-c C-u"        "C-S-p" fstar-subp-retract-last)
    ("C-c C-p"        "C-S-p" fstar-subp-retract-last)
    ("C-c RET"        "C-S-i" fstar-subp-advance-or-retract-to-point)
    ("C-c <C-return>" "C-S-i" fstar-subp-advance-or-retract-to-point)
    ("C-c C-l"        "C-S-l" fstar-subp-advance-or-retract-to-point-lax)
    ("C-c C-x"        "C-M-c" fstar-subp-kill-one-or-many))
  "Proof-General and Atom bindings table.")

(defun fstar-subp-refresh-keybinding (bind target unbind)
  "Bind BIND to TARGET, and unbind UNBIND."
  (define-key fstar-mode-map (kbd bind) target)
  (define-key fstar-mode-map (kbd unbind) nil))

(defun fstar-subp-refresh-keybindings (style)
  "Adjust keybindings to match STYLE."
  (cl-loop for (pg atom target) in fstar-subp-keybindings-table
           do (pcase style
                (`pg   (fstar-subp-refresh-keybinding pg target atom))
                (`atom (fstar-subp-refresh-keybinding atom target pg))
                (other (user-error "Invalid keybinding style: %S" other)))))

(defun fstar-subp-set-keybinding-style (var style)
  "Set VAR to STYLE and update keybindings."
  (set-default var style)
  (fstar-subp-refresh-keybindings style))

(defcustom fstar-interactive-keybinding-style 'pg
  "Which style of bindings to use in F* interactive mode."
  :group 'fstar
  :set #'fstar-subp-set-keybinding-style
  :type '(choice (const :tag "Proof-General style bindings" pg)
                 (const :tag "Atom-style bindings" atom)))

;;;; Main entry point

(defun fstar-setup-interactive ()
  "Setup interactive F* mode."
  (fstar-subp-refresh-keybindings fstar-interactive-keybinding-style)
  (setq-local help-at-pt-display-when-idle t)
  (setq-local help-at-pt-timer-delay 0.2)
  (help-at-pt-cancel-timer)
  (help-at-pt-set-timer)
  (when (featurep 'flycheck)
    (add-to-list 'flycheck-disabled-checkers 'fstar)))

(defun fstar-teardown-interactive ()
  "Cleanup F* interactive mode."
  (help-at-pt-cancel-timer))

;;; Comment syntax

(defun fstar-syntactic-face-function (args)
  "Choose face to display based on ARGS."
  (pcase-let ((`(_ _ _ ,in-string _ _ _ _ ,comment-start-pos _) args))
    (cond (in-string ;; Strings
           font-lock-string-face)
          (comment-start-pos ;; Comments ('//' doesnt have a comment-depth
           (save-excursion
             (goto-char comment-start-pos)
             (cond
              ((looking-at (regexp-quote fstar-build-config-header)) font-lock-doc-face)
              ((looking-at (regexp-quote "(*** ")) '(:inherit font-lock-doc-face :height 2.5))
              ((looking-at (regexp-quote "(**+ ")) '(:inherit font-lock-doc-face :height 1.8))
              ((looking-at (regexp-quote "(**! ")) '(:inherit font-lock-doc-face :height 1.5))
              ((looking-at (regexp-quote "(** "))  font-lock-doc-face)
              (t font-lock-comment-face)))))))

(defun fstar-setup-comments ()
  "Set comment-related variables for F*."
  (setq-local comment-multi-line t)
  (setq-local comment-use-syntax t)
  (setq-local comment-start      "(*")
  (setq-local comment-continue   " *")
  (setq-local comment-end        "*)")
  (setq-local comment-start-skip "\\(//+\\|(\\*+\\)[ \t]*")
  (setq-local font-lock-syntactic-face-function #'fstar-syntactic-face-function)
  (setq-local syntax-propertize-function fstar-mode-syntax-propertize-function))

;;; Main mode

(defun fstar-setup-hooks ()
  "Setup hooks required by F*-mode."
  (add-hook 'before-revert-hook #'fstar-subp-kill nil t))

(defun fstar-teardown-hooks ()
  "Remove hooks required by F*-mode."
  (remove-hook 'before-revert-hook #'fstar-subp-kill))

(defun fstar-enable-disable (enable)
  "ENABLE or disable F* mode components."
  (dolist (module (cons 'hooks fstar-enabled-modules))
    (let* ((prefix (if enable "fstar-setup-" "fstar-teardown-"))
           (fsymb  (intern (concat prefix (symbol-name module)))))
      (when (fboundp fsymb)
        (funcall fsymb)))))

;;;###autoload
(define-derived-mode fstar-mode prog-mode "F✪"
  :syntax-table fstar-syntax-table
  (fstar-enable-disable t))

(defun fstar-mode-unload-function ()
  "Unload F* mode components."
  (fstar-enable-disable nil))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.fsti?\\'" . fstar-mode))

;;; Footer

;; Local Variables:
;; checkdoc-verb-check-experimental-flag: nil
;; End:

(provide 'fstar-mode)
;;; fstar-mode.el ends here
