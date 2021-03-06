;;; sallet.el --- Select candidates in a buffer -*- lexical-binding: t -*-

;; Copyright (C) 2014-2015 Matúš Goljer <matus.goljer@gmail.com>

;; Author: Matúš Goljer <matus.goljer@gmail.com>
;; Maintainer: Matúš Goljer <matus.goljer@gmail.com>
;; Version: 0.0.1
;; Created: 31st December 2014
;; Package-requires: ((dash "2.10.0") (s "1.9.0") (flx "0.4") (async "1.2") (shut-up "0.3.2") (ov "1.0"))
;; Keywords: convenience

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 3
;; of the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;; Code:
(require 'dash)
(require 's)
(require 'async)
(require 'flx)
(require 'ov)

(require 'eieio)
(require 'ibuffer)
(require 'imenu)

(defgroup sallet ()
  "Select candidates in a buffer."
  :group 'convenience
  :prefix "sallet-")

(defun sallet-vector-logical-length (vector)
  "Return logical length of VECTOR.

Logical length is the number of non-nil elements from start."
  (let ((i 0))
    (catch 'end
      (mapc (lambda (x) (if x (setq i (1+ i)) (throw 'end i))) vector)
      (length vector))))

(defun sallet-make-candidate-indices (candidates)
  "Create the indices list for CANDIDATES.

This is a list from 0 to (1- logical-length-of-candidates).  This
list is used in the filtering pipeline and at the end the
remaining indices point to the candidates structure and designate
valid candidates."
  (number-sequence 0 (1- (sallet-vector-logical-length candidates))))

(defun sallet-car-maybe (cons-or-thing)
  "Return `car' of CONS-OR-THING if it is a cons or itself otherwise."
  (if (consp cons-or-thing) (car cons-or-thing) cons-or-thing))

(defun sallet-aref (candidates index)
  "Return element of CANDIDATES at INDEX.

If INDEX is a number behaves just like `aref'.

If INDEX is a cons, take its `car' and then behaves like `aref'."
  (if (numberp index)
      (aref candidates index)
    (aref candidates (car index))))

(defun sallet-candidate-aref (candidates index)
  "Return candidate from CANDIDATES at INDEX.

CANDIDATES is a vector of candidates.  If the element at index is
a list, return its `car', otherwise return the element without change.

INDEX is a number, index into the CANDIDATES array.  If the index
is a list, take its `car'."
  (sallet-car-maybe (aref candidates (sallet-car-maybe index))))

(defun sallet-plist-update (plist property data update-function)
  "Take PLIST and append DATA to PROPERTY.

The value at PROPERTY is a list.

UPDATE-FUNCTION is used to compute the new value inserted into
the plist.  It takes two arguments, DATA and old value of
PROPERTY."
  (let ((old-data (plist-get plist property)))
    (plist-put plist property (funcall update-function data old-data))))

(defun sallet-update-index (index &rest properties)
  "Update INDEX with PROPERTIES.

PROPERTIES is a list of properties (PROPERTY NEW-VALUE UPDATE-FUNCTION).

PROPERTY is the key under which the value is stored.

NEW-VALUE is the value to combine with the old value.

UPDATE-FUNCTION is used to compute the new value inserted into
the plist.  It takes two arguments, NEW-VALUE and old value of
PROPERTY.

If UPDATE-FUNCTION is omitted the old value is replaced with NEW-VALUE."
  (cons
   (sallet-car-maybe index)
   (--reduce-from (let* ((property (car it))
                         (new-value (cadr it))
                         (update-function (or (nth 2 it) (lambda (x _) x))))
                    (sallet-plist-update acc property new-value update-function))
                  (cdr-safe index)
                  properties)))

(defun sallet--predicate-flx (candidate index pattern matches-property score-property)
  "Match CANDIDATE at INDEX against PATTERN and update its properties.

MATCHES-PROPERTY is the name of property where matching positions
of candidate are stored.

SCORE-PROPERTY is the score of the flx match of this CANDIDATE
against PATTERN. "
  (-when-let (flx-data (flx-score candidate pattern))
    (sallet-update-index
     index
     (list matches-property (cdr flx-data) '-concat)
     (list score-property (car flx-data)))))

(defun sallet-predicate-flx (candidate index pattern)
  "Match and score CANDIDATE at INDEX against PATTERN."
  (sallet--predicate-flx candidate index pattern :flx-matches :flx-score))

(defun sallet-predicate-path-flx (candidate index pattern)
  "Match and score path CANDIDATE at INDEX against PATTERN."
  (sallet--predicate-flx candidate index pattern :flx-matches-path :flx-score-path))

(defun sallet-predicate-buffer-major-mode (candidate index pattern)
  "Match and score CANDIDATE buffer's `major-mode' at INDEX against PATTERN.

Matching is done using flx alogrithm."
  (sallet--predicate-flx candidate index pattern :flx-matches-mm :flx-score-mm))

(defun sallet--predicate-regexp (candidate index pattern matches-property)
  "Match CANDIDATE at INDEX against PATTERN and update its properties.

MATCHES-PROPERTY is the name of property where matching positions
of candidate are stored."
  (save-match-data
    (when (string-match pattern candidate)
      (sallet-update-index
       index
       (list matches-property (cons (match-beginning 0) (match-end 0)) 'cons)))))

(defun sallet-predicate-regexp (candidate index pattern)
  "Match and score CANDIDATE at INDEX against PATTERN."
  (sallet--predicate-regexp candidate index pattern :regexp-matches))

(defun sallet-predicate-path-regexp (candidate index pattern)
  "Match and score path CANDIDATE at INDEX against PATTERN."
  (sallet--predicate-regexp candidate index pattern :regexp-matches-path))

;; TODO: figure out how the caching works
(defun sallet-filter-flx (candidates indices pattern)
  "Match PATTERN against CANDIDATES at INDICES.

CANDIDATES is a vector of candidates.

INDICES is a list of processed candidates.

Uses the `flx' algorithm."
  (if (equal "" pattern) indices
    (--keep (sallet-predicate-flx (sallet-candidate-aref candidates it) it pattern) indices)))

(defun sallet-filter-substring (candidates indices pattern)
  "Match PATTERN against CANDIDATES at INDICES.

CANDIDATES is a vector of candidates.

INDICES is a list of processed candidates.

Uses substring matching."
  (let ((quoted-pattern (regexp-quote pattern)))
    (--keep (sallet-predicate-regexp (sallet-candidate-aref candidates it) it quoted-pattern) indices)))

(defun sallet-predicate-buffer-imenu (candidate index pattern)
  "Check if buffer contains `imenu' item flx-matching PATTERN.

CANDIDATE is a buffer or buffer name.

INDEX is its index and associated meta data.

PATTERN is a string flx-matched against imenu items.

Returns updated INDEX with optional added metadata or nil if this
candidate should not pass the filter."
  (when (with-current-buffer candidate
          (let ((imenu-alist-flat
                 ;; TODO: cache the flattened
                 ;; alists so we don't have to
                 ;; recomute on every inserted letter.
                 (-flatten (--tree-map (if (stringp it) nil (car it))
                                       ;; TODO: make sure the alist is initialized
                                       imenu--index-alist))))
            ;; TODO: add list of matching imenu items as metadata so
            ;; we can render that somehow in the list?
            (--any? (flx-score it pattern) imenu-alist-flat)))
    index))

(defun sallet-filter-buffer-imenu (candidates indices pattern)
  "Keep buffer CANDIDATES flx-matching PATTERN against an imenu item."
  (--keep (sallet-predicate-buffer-imenu (sallet-candidate-aref candidates it) it pattern) indices))

(defun sallet-filter-buffer-major-mode (candidates indices pattern)
  "Keep buffer CANDIDATES flx-matching PATTERN against current `major-mode'."
  (--keep (sallet-predicate-buffer-major-mode
           (with-current-buffer (sallet-candidate-aref candidates it) (symbol-name major-mode))
           it pattern) indices))

(defun sallet-predicate-buffer-fulltext (candidate index pattern)
  "Check if buffer's `buffer-string' regexp-matches PATTERN.

CANDIDATE is a buffer or buffer name.

INDEX is its index and associated meta data.

PATTERN is a regexp matched against `buffer-string'.

Returns updated INDEX with optional added metadata or nil if this
candidate should not pass the filter."
  (when (with-current-buffer candidate
          (save-excursion
            (goto-char (point-min))
            (re-search-forward pattern nil t)))
    index))

(defun sallet-filter-buffer-fulltext (candidates indices pattern)
  "Keep buffer CANDIDATES regexp-matching PATTERN against `buffer-string'."
  (--keep (sallet-predicate-buffer-fulltext (sallet-candidate-aref candidates it) it pattern) indices))

(defun sallet-filter-buffer-default-directory-flx (candidates indices pattern)
  "Keep buffer CANDIDATES flx-matching PATTERN against `default-directory'."
  (--keep (sallet-predicate-path-flx
           (with-current-buffer (sallet-candidate-aref candidates it) default-directory)
           it pattern) indices))

(defun sallet-filter-buffer-default-directory-substring (candidates indices pattern)
  "Keep buffer CANDIDATES substring-matching PATTERN against `default-directory'."
  (let ((quoted-pattern (regexp-quote pattern)))
    (--keep (sallet-predicate-path-regexp
             (with-current-buffer (sallet-candidate-aref candidates it) default-directory)
             it quoted-pattern) indices)))

(defun sallet-filter-flx-then-substring (candidates indices pattern)
  "Match PATTERN against CANDIDATES with flx- or substring-matching.

CANDIDATES are strings.

We use following check to determine which algorithm to use:
1. Pick the first index from INDICES.
2. If it contains metadata related to flx-matching, we substring
   match, otherwise flx-matching was never performed so we flx-match."
  (if (or (not (consp (car indices)))
          (not (plist-member (cdar indices) :flx-score)))
      (sallet-filter-flx candidates indices pattern)
    (sallet-filter-substring candidates indices (regexp-quote pattern))))

;; TODO: turn into a transformer returning a filter closure
(defun sallet-pipe-filters (filters candidates indices pattern)
  "Run all FILTERS in sequence, filtering CANDIDATES against PATTERN."
  (--reduce-from (funcall it candidates acc pattern) indices filters))

;; TODO: maybe we can add support for "... ..." patterns by "spliting
;; as sexps" in a temporary buffer where we set everything to word
;; syntax except spaces and quotes. Then each sexp is one token
;; (symbols converted to strings first)
;; TODO: Add optimization where we only re-run changed tokens.  We can
;; keep the index from the last update and just work on that
;; (similarly as we keep the pattern from one update ago).
;; TODO: turn into a transformer returning a filter closure
(defun sallet-compose-filters-by-pattern (filter-alist candidates indices pattern)
  "Filter CANDIDATES using rules from FILTER-ALIST.

FILTER-ALIST is an alist of (SUBPATTERN . FILTERS) or (SUBPATTERN
MATCH-GROUP . FILTERS).

SUBPATTERN is a regular expression, FILTERS is a list of filters,
MATCH-GROUP is a match group of SUBPATTERN.

First, PATTERN is split on whitespace into a list of TOKENS.

Then for each TOKEN we find first SUBPATTERN that matches it and
filter INDICES through the associated list of filters.  The
pattern passed to the filter is the value of first match group of
SUBPATTERN or MATCH-GROUP if specified.

The special SUBPATTERN `t' signifies a default branch.  As soon
as this SUBPATTERN is found the search stops and its filters are
applied.

Return INDICES filtered in this manner by all the TOKENS."
  (let* ((input (split-string pattern)))
    (-each input
      (lambda (token)
        (-when-let ((input . filters)
                    (--some
                     (let ((subpattern (car it))
                           (match-group (if (numberp (cadr it)) (cadr it) 0))
                           (filters (if (numberp (cadr it)) (cddr it) (cdr it))))
                       (if (eq t subpattern)
                           (cons token filters)
                         (when (string-match subpattern token)
                           (cons (match-string match-group token) filters))))
                     filter-alist))
          (unless (equal input "")
            (setq indices (sallet-pipe-filters filters candidates indices input))))))
    indices))

(defun sallet-make-tokenized-filter (filter)
  "Return a variant of FILTER which matches each token from input pattern separately.

Input pattern is split on whitespace to create list of tokens.
Each candidate is then matched against each token.  Only
candidates matching all tokens will pass the test."
  (lambda (candidates indices pattern)
    (let ((tokens (split-string pattern)))
      (--reduce-from (funcall filter candidates acc it) indices tokens))))

(defun sallet-ignore-first-token-filter (filter)
  "Return a variant of FILTER which ignores first token of prompt.

Input pattern is split on whitespace to create list of tokens.
The first token is dropped and then the resulting strings are
concatenated again and passed to FILTER.

This is useful in asyncio sources where we pass the first token
to the asyncio process and the rest to the matcher."
  (lambda (candidates indices pattern)
    (let* ((tokens (split-string pattern " "))
           (new-pattern (mapconcat 'identity (cdr tokens) " ")))
      (if (equal new-pattern "") indices
        (funcall filter candidates indices new-pattern)))))

(defun sallet-make-matcher (filter)
  "Make a sallet matcher from a filter."
  (lambda (candidates state)
    (let ((prompt (sallet-state-get-prompt state))
          (indices (sallet-make-candidate-indices candidates)))
      (funcall filter candidates indices prompt))))

(defun sallet-matcher-default (candidates state)
  "Default matcher.

The prompt is split on whitespace, then candidate must
substring-match each token to pass the test."
  (let ((prompt (sallet-state-get-prompt state))
        (indices (sallet-make-candidate-indices candidates)))
    (funcall (sallet-make-tokenized-filter 'sallet-filter-substring) candidates indices prompt)))

;; TODO: write a "defmatcher" macro which would automatically define
;; prompt and indices variables
(defun sallet-matcher-flx (candidates state)
  "Match candidates using flx matching."
  (let ((prompt (sallet-state-get-prompt state))
        (indices (sallet-make-candidate-indices candidates)))
    (sallet-filter-flx candidates indices prompt)))

;; TODO: figure out how to compose this when multiple filters are in
;; place and not all of them provide the sorting attribute
(defun sallet-sorter-flx (processed-candidates _)
  "Sort PROCESSED-CANDIDATES by :flx-score."
  (sort processed-candidates
        (lambda (a b)
          ;; UGLY!!!!
          (if (and (consp a) (consp b))
              (-when-let* (((_ &keys :flx-score sa) a)
                           ((_ &keys :flx-score sb) b))
                (> sa sb))
            (> a b)))))

;; TODO: add docs
(defmacro sallet-defsource (name parents &optional docstring &rest body)
  (declare (doc-string 3)
           (debug (&define name (&rest arg) [&optional stringp] def-body))
           (indent defun))
  (unless (stringp docstring) (setq body (cons docstring body)))
  `(defclass ,(intern (concat "sallet-source-" (symbol-name name)))
     ,(--map (intern (concat "sallet-source-" (symbol-name it)))
             (if (and (not (memq name '(-default default)))
                      (not parents))
                 (list 'default) parents))
     ,(-map (lambda (arg)
              (let (re)
                (push (list (car arg) :initform (cadr arg)) re)
                (when (plist-member arg :documentation)
                  (push (list :documentation (plist-get arg :documentation)) re))
                (apply '-concat (nreverse re))))
            body)
     ,@(when (stringp docstring) (list :documentation docstring))))

(font-lock-add-keywords 'emacs-lisp-mode `(("(\\(sallet-defsource\\)\\>[[:blank:]]+\\(.*?\\)[[:blank:]]"
                                            (1 font-lock-keyword-face)
                                            (2 font-lock-type-face))))

(sallet-defsource -default ()
  "The absolute parent of the source hierarchy.

This is an internal class.

This source defines internal variables used to hold state during
the picking process."
  (processed-candidates nil))

;; TODO: add a simple interface to create an interactive transient
;; "source" with just a static list of candidates (i.e. support for
;; anonymous sources)
;; TODO: remake all the functions to take source as first
;; argument... this allows us to save state inside the source as with
;; normal objects.
(sallet-defsource default (-default)
  "Default source.

Every user or package-defined source must inherit from this
source.  If the user does not specify any source to inherit from,
this is added automatically!

Sets default matcher `sallet-matcher-default', identity renderer
and identity action."
  (matcher sallet-matcher-default
           :documentation "write what a matcher is. function matching and ranking/sorting candidates")
  (sorter (lambda (x _) x)
          :documentation "Sorter.")
  (renderer (lambda (candidate state user-data) candidate)
            :documentation "write what a renderer is.")
  ;; action: TODO: (cons action-name action-function)
  ;; TODO: add support for actions which do not kill the session
  (action identity)
  ;; A function generating candidates, a list or vector of candidates.
  ;; Candidates can be either strings or any lists with first element
  ;; being used for matching (usually a string, but can be anything as
  ;; long as the matcher and renderer and action know how to handle
  ;; it).
  (candidates nil)
  ;; function generating candidates, takes source and state, returns a
  ;; vector The difference with `candidates' is that `candidates' run
  ;; only when we first enter the session while `generator' takes
  ;; input interactively.
  (generator nil)
  ;; If t, this source is asynchronous and processing takes place in a
  ;; different emacs instance.  The source must be written with this in mind.
  (async nil)
  ;; Header.  Is either a string or a function.  In case of a string,
  ;; it is rendered in sallet-source-header face with a counter
  ;; showing number of filtered/all candidates.  If a function, it is
  ;; passed current source as argument and its output is used verbatim
  ;; as the header text (newline is added *automatically*)
  (header "Select a candidate"))

(sallet-defsource asyncio (default)
  "Default asyncio source."
  (process nil
           :documentation "Process generating candidates"))

(defgroup sallet-faces nil
  "Sallet faces."
  :group 'sallet)

(defface sallet-source-header
  '((t (:inherit highlight)))
  "Face used to fontify source header."
  :group 'sallet-faces)

(defface sallet-buffer-ordinary
  '((t (:inherit font-lock-type-face)))
  "Face used to fontify ordinary buffers."
  :group 'sallet-faces)

(defface sallet-buffer-modified
  '((t (:inherit font-lock-warning-face)))
  "Face used to fontify modified (unsaved) buffers."
  :group 'sallet-faces)

(defface sallet-buffer-compressed
  '((t (:inherit font-lock-doc-face)))
  "Face used to fontify buffers representing compressed files.

Compressed files are those matching
`ibuffer-compressed-file-name-regexp'."
  :group 'sallet-faces)

(defface sallet-buffer-read-only
  '((t (:inherit font-lock-constant-face)))
  "Face used to fontify read-only buffers."
  :group 'sallet-faces)

(defface sallet-buffer-special
  '((t (:inherit font-lock-keyword-face)))
  "Face used to fontify special buffers.

Special buffers are those prefixed by *."
  :group 'sallet-faces)

(defface sallet-buffer-help
  '((t (:inherit font-lock-comment-face)))
  "Face used to fontify help buffers.

Help buffers are those whose major mode matches
`ibuffer-help-buffer-modes'."
  :group 'sallet-faces)

(defface sallet-buffer-directory
  '((t (:inherit font-lock-function-name-face)))
  "Face used to fontify directory buffers.

Directory buffers are those whose major mode is `dired-mode'."
  :group 'sallet-faces)

(defface sallet-buffer-size
  '((t (:foreground "RosyBrown")))
  "Face used to fontify buffer size."
  :group 'sallet-faces)

(defface sallet-buffer-default-directory
  '((t (:foreground "Sienna3")))
  "Face used to fontify buffer's default directory or process."
  :group 'sallet-faces)

(defun sallet-buffer-fontify-buffer-name (candidate)
  "Fontify buffer name."
  (with-current-buffer candidate
    (let ((face (cond
                 ((and (buffer-file-name)
                       (buffer-modified-p))
                  'sallet-buffer-modified)
                 ((eq major-mode (quote dired-mode)) 'sallet-buffer-directory)
                 ((memq major-mode ibuffer-help-buffer-modes) 'sallet-buffer-help)
                 ((string-match-p "^*" (buffer-name)) 'sallet-buffer-special)
                 ((and buffer-file-name
                       (string-match-p ibuffer-compressed-file-name-regexp buffer-file-name))
                  'sallet-buffer-compressed)
                 (buffer-read-only 'sallet-buffer-read-only)
                 (t 'sallet-buffer-ordinary))))
      (propertize (buffer-name) 'face face))))

(defface sallet-regexp-match
  '((t (:inherit font-lock-variable-name-face :weight bold)))
  "Face used to fontify regexp matches."
  :group 'sallet-faces)

(defface sallet-substring-match
  '((t (:inherit font-lock-variable-name-face :weight bold)))
  "Face used to fontify substring matches."
  :group 'sallet-faces)

(defface sallet-flx-match
  '((t (:inherit font-lock-variable-name-face :weight bold
        :underline (:color foreground-color :style line))))
  "Face used to fontify flx matches."
  :group 'sallet-faces)

(defun sallet--fontify-regions (regions string face)
  "Highlight regions.

REGIONS is a list of conses (BEG . END) where each cons delimits the region.

STRING is the string we want to fontify."
  (let ((new-string (copy-sequence string)))
    (-each regions
      (-lambda ((beg . end))
        (add-text-properties beg end (list 'face face) new-string)))
    new-string))

(defun sallet-fontify-regexp-matches (matches string)
  "Highlight regexp matches.

MATCHES is a list of conses (BEG . END) where each cons delimits the matched region.

STRING is the string we want to fontify."
  (sallet--fontify-regions matches string 'sallet-regexp-match))

(defun sallet-fontify-substring-matches (matches string)
  "Highlight substring matches.

MATCHES is a list of conses (BEG . END) where each cons delimits the matched region.

STRING is the string we want to fontify."
  (sallet--fontify-regions matches string 'sallet-substring-match))

(defun sallet-fontify-flx-matches (matches string)
  "Highlight flx matches.

MATCHES is a list of indices where flx matched a letter to the input pattern.

STRING is the string we want to fontify."
  (let ((new-string (copy-sequence string)))
    (--each matches
      (add-text-properties it (1+ it) (list 'face 'sallet-flx-match) new-string))
    new-string))

(defun sallet-compose-fontifiers (string user-data &rest fontifiers)
  "Fontify STRING using information from USER-DATA, applying FONTIFIERS in sequence.

FONTIFIERS is an list of (FONTIFIER . ATTRIBUTE) or FONTIFIER.

ATTRIBUTE is key into the USER-DATA.

FONTIFIER is a function of one or two arguments.  If it has
associated ATTRIBUTE, its value in USER-DATA is passed as first
argument, the string to be fontified as second.  Otherwise just
the string is passed to the function."
  (--reduce-from (let ((user-value (when (consp it) (plist-get user-data (cdr it))))
                       (fn (if (consp it) (car it) it)))
                   (if (consp it)
                       (funcall fn user-value acc)
                     (funcall fn acc)))
                 string fontifiers))

(defun sallet-buffer-renderer (candidate _ user-data)
  "Render a buffer CANDIDATE."
  (with-current-buffer candidate
    ;; TODO: make the column widths configurable
    (format "%-50s%10s  %20s  %s"
            (truncate-string-to-width
             (sallet-compose-fontifiers
              candidate user-data
              'sallet-buffer-fontify-buffer-name
              '(sallet-fontify-regexp-matches . :regexp-matches)
              '(sallet-fontify-flx-matches . :flx-matches))
             50 nil nil t)
            (propertize (file-size-human-readable (buffer-size)) 'face 'sallet-buffer-size)
            (truncate-string-to-width
             (s-chop-suffix "-mode"
                            (sallet-fontify-flx-matches
                             (plist-get user-data :flx-matches-mm)
                             (symbol-name major-mode)))
             20 nil nil t)
            (format (propertize
                     (concat "(" (or (and (buffer-file-name) (concat "in %s"))
                                     (-when-let (process (get-buffer-process (current-buffer)))
                                       (concat (process-name process)
                                               " run in %s"))
                                     "%s")
                             ")")
                     'face
                     'sallet-buffer-default-directory)
                    (sallet-compose-fontifiers
                     default-directory user-data
                     '(sallet-fontify-regexp-matches . :regexp-matches-path)
                     '(sallet-fontify-flx-matches . :flx-matches-path))))))

(defun sallet-buffer-matcher (candidates state)
  "Match a buffer candidate using special rules.

CANDIDATES are buffer names.

First, the prompt is split on whitespace.  This creates a list of
patterns.

A pattern starting with * is flx-matched against the `major-mode'.

A pattern starting with @ is flx-matched against the
`imenu--index-alist' entries.  These are usually names of
classes, functions, variables defined in the file.

A pattern starting with # does a full-text regexp search inside
the buffer.

A pattern starting with / flx-matches against the default directory.

Any other non-prefixed pattern is matched using the following rules:

- If the pattern is first of this type at the prompt, it is
  flx-matched against the buffer name.
- All the following patterns are substring matched against the
  buffer name."
  (let* ((prompt (sallet-state-get-prompt state))
         (indices (sallet-make-candidate-indices candidates)))
    ;; TODO: add . prefix to match on file extension
    ;; TODO: add gtags filter?
    (sallet-compose-filters-by-pattern
     '(("\\`\\*\\(.*\\)" 1 sallet-filter-buffer-major-mode)
       ("\\`@\\(.*\\)" 1 sallet-filter-buffer-imenu)
       ("\\`#\\(.*\\)" 1 sallet-filter-buffer-fulltext)
       ("\\`//\\(.*\\)" 1 sallet-filter-buffer-default-directory-substring)
       ("\\`/\\(.*\\)" 1 sallet-filter-buffer-default-directory-flx)
       (t sallet-filter-flx-then-substring))
     candidates
     indices
     prompt)))

;; TODO: sorting is now done the same way as `buffer-list' returns the
;; results, in LRU order.  We should also try to add some weight to
;; the flx score.  One possibility is to add +100, and decreasing, to
;; the flx-score for more recent buffers.
(sallet-defsource buffer nil
  "Buffer source."
  (candidates (lambda ()
                (let ((buffers
                       ;; TODO: preprocess candidates to include
                       ;; major-mode and directory so we don't have to
                       ;; query it multiple times (in filtering and
                       ;; rendering)
                       (--keep (let ((name (buffer-name it)))
                                 ;; TODO: add a variable where users
                                 ;; can write regexps to exclude
                                 ;; buffers
                                 (unless (string-match-p "^ " name) name))
                               (buffer-list))))
                  (if (< 1 (length buffers))
                      ;; swap the current buffer with the last
                      ;; recently visited other buffer, so we default
                      ;; to toggling
                      (-cons* (cadr buffers) (car buffers) (cddr buffers))
                    buffers))))
  (matcher sallet-buffer-matcher)
  (action switch-to-buffer)
  (header "Buffers")
  (renderer sallet-buffer-renderer))

;; TODO: define source for files in the current directory

(defface sallet-recentf-buffer-name
  '((t (:inherit font-lock-builtin-face)))
  "Face used to fontify recentf buffer name."
  :group 'sallet-faces)

(defface sallet-recentf-file-path
  '((t (:inherit sallet-buffer-default-directory)))
  "Face used to fontify recentf file path."
  :group 'sallet-faces)

;; TODO: faces should come as optional parameters, this should be called "bookmark cons" renderer
(defun sallet-recentf-renderer (candidate _ user-data)
  "Render a recentf candidate."
  (-let (((name . file) candidate))
    (format "%-50s%s"
            (sallet-fontify-flx-matches
             (plist-get user-data :flx-matches)
             (propertize name 'face 'sallet-recentf-buffer-name))
            (propertize (abbreviate-file-name file) 'face 'sallet-recentf-file-path))))

(sallet-defsource recentf nil
  "Files saved on `recentf-list'."
  (candidates (lambda ()
                (unless recentf-mode (recentf-mode 1))
                (--map
                 (let ((name (file-name-nondirectory it)))
                   (cons name it))
                 recentf-list)))
  ;; TODO: add matching on path with /
  (matcher sallet-matcher-flx)
  (renderer sallet-recentf-renderer)
  (action (-lambda ((_ . file)) (find-file file)))
  (header "Recently opened files"))

(sallet-defsource recentf-closed-only (recentf)
  "Files saved on `recentf-list', but without those whose buffer is already opened."
  (candidates (lambda ()
                (unless recentf-mode (recentf-mode 1))
                (--keep
                 (let ((name (file-name-nondirectory it)))
                   (unless (get-file-buffer it)
                     (cons name it)))
                 recentf-list))))

(defun sallet-filter-autobookmark-path-substring (candidates indices pattern)
  "Keep autobookmark CANDIDATES substring-matching PATTERN against file path."
  (let ((quoted-pattern (regexp-quote pattern)))
    (--keep (sallet-predicate-path-regexp (cadr (sallet-aref candidates it)) it quoted-pattern) indices)))

(defun sallet-filter-autobookmark-path-flx (candidates indices pattern)
  "Keep autobookmark CANDIDATES flx-matching PATTERN against file path."
  (--keep (sallet-predicate-path-flx (cadr (sallet-aref candidates it)) it pattern) indices))

;; TODO: add a matcher for major mode based on extension and
;; auto-mode-alist
(defun sallet-autobookmarks-matcher (candidates state)
  "Match an autobookmark candidate using special rules.

First, the prompt is split on whitespace.  This creates a list of
patterns.

A pattern starting with / flx-matches against the path to the
file bookmark represents.

A pattern starting with // substring-matches against the path to the
file bookmark represents.

Any other non-prefixed pattern is matched using the following rules:

- If the pattern is first of this type at the prompt, it is
  flx-matched against the bookmark name.
- All the following patterns are substring matched against the
  bookmark name."
  (let* ((prompt (sallet-state-get-prompt state))
         (indices (sallet-make-candidate-indices candidates)))
    (sallet-compose-filters-by-pattern
     '(("\\`//\\(.*\\)" 1 sallet-filter-autobookmark-path-substring)
       ("\\`/\\(.*\\)" 1 sallet-filter-autobookmark-path-flx)
       (t sallet-filter-flx-then-substring))
     candidates
     indices
     prompt)))

;; TODO: improve
(defun sallet-autobookmarks-renderer (candidate _ user-data)
  "Render an `autobookmarks-mode' candidate."
  (-let* (((name path . data) candidate)
          ((&alist 'visits visits) data))
    (format "%-55s%5s  %s"
            (sallet-compose-fontifiers
             ;; TODO: create a "fontify flx after regexp" function to
             ;; simplify this common pattern
             (propertize name 'face 'sallet-recentf-buffer-name) user-data
             '(sallet-fontify-regexp-matches . :regexp-matches)
             '(sallet-fontify-flx-matches . :flx-matches))
            (propertize (if visits (int-to-string visits) "0") 'face 'sallet-buffer-size)
            (abbreviate-file-name
             (sallet-compose-fontifiers
              (propertize path 'face 'sallet-recentf-file-path) user-data
              '(sallet-fontify-regexp-matches . :regexp-matches-path)
              '(sallet-fontify-flx-matches . :flx-matches-path))))))

(sallet-defsource autobookmarks nil
  "Files saved with `autobookmarks-mode'."
  (candidates (lambda ()
                (require 'autobookmarks)
                (-keep
                 (lambda (bookmark)
                   (-when-let (name
                               (cond
                                ((assoc 'defaults (cdr bookmark))
                                 (cadr (assoc 'defaults (cdr bookmark))))
                                ((assoc 'filename (cdr bookmark))
                                 (f-filename
                                  (cdr (assoc 'filename (cdr bookmark)))))))
                     (cons name bookmark)))
                 (-sort (-lambda ((_ . (&alist 'time a))
                                  (_ . (&alist 'time b)))
                          (time-less-p b a))
                        (abm-recent-buffers)))))
  (matcher sallet-autobookmarks-matcher)
  (renderer sallet-autobookmarks-renderer)
  (action (-lambda ((_ . x)) (abm-restore-killed-buffer x)))
  (header "Autobookmarks"))

(defun sallet--imenu-flatten (alist)
  "Compute imenu candidates."
  (--mapcat (if (imenu--subalist-p it)
                (-map (-lambda ((name pos . tags)) (-cons* name pos (car it) tags)) (sallet--imenu-flatten (cdr it)))
              (list (list (car it) (cdr it))))
            alist))

(defun sallet-filter-imenu-tags-flx (candidates indices pattern)
  "Keep buffer CANDIDATES flx-matching PATTERN against imenu tags."
  (--keep (sallet-predicate-path-flx
           (mapconcat 'identity (cddr (sallet-aref candidates it)) ", ")
           it pattern) indices))

(defun sallet-imenu-renderer (c _ user-data)
  (-let* (((x _ . tags) c)
          (face (cond ((member "Variables" tags)
                       'font-lock-variable-name-face)
                      ((member "Types" tags)
                       'font-lock-type-face)
                      (t 'font-lock-function-name-face))))
    (format "%-80s%s"
            (sallet-compose-fontifiers
             (propertize x 'face face) user-data
             '(sallet-fontify-regexp-matches . :regexp-matches)
             '(sallet-fontify-flx-matches . :flx-matches))
            (sallet-compose-fontifiers
             (mapconcat 'identity tags ", ") user-data
             '(sallet-fontify-regexp-matches . :regexp-matches-path)
             '(sallet-fontify-flx-matches . :flx-matches-path)))))

(defun sallet-imenu-matcher (a b)
  (funcall (sallet-make-matcher (lambda (c i p)
                          (sallet-compose-filters-by-pattern
                           '(("\\`/\\(.*\\)" 1 sallet-filter-imenu-tags-flx)
                             (t sallet-filter-flx-then-substring)) c i p))) a b))

(defun sallet-imenu-candidates ()
  (let ((initial (symbol-name (symbol-at-point)))
        (cands (--map (if (cddr it) it (-snoc it ""))
                      (--remove (< (cadr it) 0) (sallet--imenu-flatten (imenu--make-index-alist))))))
    (if initial
        (-if-let (initial (--first (equal (car it) initial) cands))
            (cons initial (--remove (equal initial it) cands))
          cands)
      cands)))

(sallet-defsource imenu nil
  "Imenu."
  (candidates sallet-imenu-candidates)
  (matcher sallet-imenu-matcher)
  (sorter sallet-sorter-flx)
  (renderer sallet-imenu-renderer)
  (action (-lambda ((_ pos))
            (cond
             ((eq major-mode 'org-mode)
              (goto-char pos)
              (org-show-context)
              (org-show-entry))
             (t (goto-char pos)))))
  (header "Imenu"))

;; TODO: this depends on bookmark+ (`bmkp-file-alist-only',
;; `bmkp-jump-1'), should probably be moved to a different file.
(sallet-defsource bookmarks-file-only nil
  "Bookmarks source, files only."
  (candidates (lambda () (--map
                          (cons
                           (substring-no-properties (car it))
                           (cdr (assoc 'filename (cdr it))))
                          (bmkp-file-alist-only))))
  ;; TODO: enable matching on paths with /
  (matcher sallet-matcher-flx)
  ;; TODO: extract into generic "flx fontify string candidate"
  ;; renderer
  (renderer sallet-recentf-renderer ;; TODO: directory bookmarks should have different color
            ;; (lambda (c _ user-data)
            ;;   (sallet-fontify-flx-matches
            ;;    (plist-get user-data :flx-matches)
            ;;    (car c)))
            )
  (action (-lambda ((name))
            ;; TODO: doesn't seem to work
            (bmkp-jump-1 name 'switch-to-buffer nil)))
  (header "Bookmarks"))

(sallet-defsource bookmarks-file-only-closed-only (bookmarks-file-only)
  "Bookmarks source, files only, closed files only."
  (candidates (lambda () (--keep
                          (let ((path (cdr (assoc 'filename (cdr it)))))
                            (unless (get-file-buffer path)
                              (cons (substring-no-properties (car it)) path)))
                          (bmkp-file-alist-only)))))

;; TODO: write docstring
(defun sallet-occur-get-lines (buffer prompt &optional mode no-font-lock)
  "Mode: :normal, :fuzzy, :regexp (default)"
  (let ((pattern
         (concat "\\("
                 (cond
                  ((eq mode :normal)
                   (regexp-quote prompt))
                  ((eq mode :fuzzy)
                   (mapconcat 'identity
                              (mapcar 'char-to-string (string-to-list prompt))
                              ".*"))
                  (t prompt))
                 "\\)"))
        re)
    (with-current-buffer buffer
      (goto-char (point-min))
      (while (re-search-forward pattern nil t)
        (let* ((lb (line-beginning-position))
               (le (line-end-position))
               (line (save-excursion
                       (if no-font-lock
                           (buffer-substring-no-properties lb le)
                         (font-lock-fontify-region lb le)
                         (buffer-substring lb le)))))
          (push (list line (point) (line-number-at-pos)) re)))
      (vconcat (nreverse re)))))

(sallet-defsource occur nil
  "Occur source."
  (candidates nil)
  (matcher nil)
  (renderer (-lambda ((line-string _ line-number) _ _)
              ;; TODO: add face to the number
              (format "%5d:%s" line-number line-string)))
  (generator '(let ((buffer (current-buffer)))
                (lambda (_ state)
                  (let ((prompt (sallet-state-get-prompt state)))
                    ;; TODO: move this into a separate setting... this
                    ;; is going to be quite common for "computing"
                    ;; sources
                    (when (>= (length prompt) 2)
                      (sallet-occur-get-lines buffer prompt :normal))))))
  (action (lambda (c)
            ;; TODO: why isn't it enough to use `goto-char'?  Probably
            ;; active window is badly re-set after candidate window is
            ;; disposed
            (set-window-point (selected-window) (cadr c)))))

(sallet-defsource occur-async (occur)
  "Async occur source."
  (async t)
  (renderer (-lambda ((line-string _ line-number) _ _)
              ;; TODO: add face to the number
              ;; TODO: fontify the result line here instead of in the async process
              (format "%5d:%s" line-number line-string)))
  ;; the buffer we search is the current buffer in the async instance
  (generator (lambda (_ state)
               (let ((prompt (sallet-state-get-prompt state)))
                 ;; TODO: move this into a separate setting... this
                 ;; is going to be quite common for "computing"
                 ;; sources
                 (when (>= (length prompt) 2)
                   (sallet-occur-get-lines (current-buffer) prompt :normal :no-font-lock))))))

(sallet-defsource occur-fuzzy (occur)
  "Fuzzy occur source."
  ;; matcher is used to rank & reorder best matches on top ...
  (matcher sallet-matcher-flx)
  (sorter sallet-sorter-flx)
  ;; ... while generator is the stupidest matcher possible
  (generator '(let ((buffer (current-buffer)))
                (lambda (_ state)
                  (let ((prompt (sallet-state-get-prompt state)))
                    (when (>= (length prompt) 2)
                      (sallet-occur-get-lines buffer prompt :fuzzy)))))))

;; TODO: better name, put it somewhere in the pipeline
;; TODO: here, filter shouldn't be called filter but... line
;; transformer? candidate generator?... filter has different meaning
;; in sallet
(defun sallet-create-line-asyncio-generator (process-creator filter &optional min-prompt-length)
  "Create a source from program producing lines of candidates.

PROCESS-CREATOR is a function which when called returns a process which
produces the candidates.  It takes one argument, the current prompt.

FILTER is a function taking one line of output and producing a
candidate.

MIN-PROMPT-LENGTH is the length of prompt when we spawn the
process for the first time."
  (setq min-prompt-length (or min-prompt-length 3))
  (lambda (source state)
    (let ((prompt (sallet-state-get-prompt state)))
      (when (>= (length prompt) min-prompt-length)
        (-when-let (proc (funcall process-creator prompt))
          (-when-let (old-proc (sallet-source-get-process source))
            (ignore-errors (kill-process old-proc)))
          (set-process-filter
           proc
           (sallet-linereader
            (sallet-linebased-candidate-generator filter source state)))
          (sit-for 0.01)
          proc)))))

(defun sallet-source-get-matcher (source)
  (oref source matcher))
(defun sallet-source-get-sorter (source)
  (oref source sorter))
(defun sallet-source-get-renderer (source)
  (oref source renderer))
(defun sallet-source-get-candidates (source)
  (oref source candidates))
(defun sallet-source-get-generator (source)
  (oref source generator))
(defun sallet-source-get-header (source)
  (oref source header))
(defun sallet-source-get-action (source)
  (oref source action))
(defun sallet-source-get-processed-candidates (source)
  (oref source processed-candidates))
(defun sallet-source-is-async (source)
  (oref source async))
(defun sallet-source-get-process (source)
  (oref source process))

(defun sallet-source-set-candidates (source candidates)
  (oset source candidates candidates))
(defun sallet-source-set-generator (source generator)
  (oset source generator generator))
(defun sallet-source-set-processed-candidates (source processed-candidates)
  (oset source processed-candidates processed-candidates))
(defun sallet-source-set-process (source process)
  (oset source process process))

(defun sallet-source-get-candidate (source n)
  (elt (sallet-source-get-candidates source) n))

(defun sallet-init-source (source)
  "Initiate the source."
  (-when-let (instance (funcall source (symbol-name source)))
    (let ((candidates (sallet-source-get-candidates instance)))
      (cond
       ((functionp candidates)
        (setq candidates (funcall candidates)))
       ((or (listp candidates)
            (vectorp candidates)
            (-when-let (sv (ignore-errors (symbol-value candidates)))
              (when (or (listp sv) (vectorp sv))
                (setq candidates sv)))))
       ((functionp (sallet-source-get-generator instance))
        (setq candidates nil))
       (t (error "Invalid source: no way to generate candidates")))
      (when (and candidates
                 (not (vectorp candidates)))
        (setq candidates (vconcat candidates)))
      (sallet-source-set-candidates instance candidates)
      ;; no filtering at start
      (sallet-source-set-processed-candidates instance (sallet-make-candidate-indices candidates)))
    (let ((generator (sallet-source-get-generator instance)))
      (unless (functionp generator)
        (sallet-source-set-generator instance (eval generator t))))
    instance))

;; TODO: make this into eieio object?
;; TODO: add documentation for the futures thing (and write/figure
;; out how the async works)
(defvar sallet-state nil
  "Current state.

SOURCES is a list of initialized sources.

CURRENT-BUFFER is the buffer from which sallet was executed.

PROMPT is the current prompt.

SELECTED-CANDIDATE is the currently selected candidate.

FUTURES is a plist mapping source id to the `async' future that
computes it.")

(defun sallet-state-get-sources (state)
  (cdr (assoc 'sources state)))
(defun sallet-state-get-current-buffer (state)
  (cdr (assoc 'current-buffer state)))
(defun sallet-state-get-prompt (state)
  (cdr (assoc 'prompt state)))
(defun sallet-state-get-selected-candidate (state)
  (cdr (assoc 'selected-candidate state)))
(defun sallet-state-get-candidate-buffer (state)
  (cdr (assoc 'candidate-buffer state)))
(defun sallet-state-get-futures (state)
  (cdr (assoc 'futures state)))

(defun sallet-state-set-sources (state sources)
  (setf (cdr (assoc 'sources state)) sources))
(defun sallet-state-set-prompt (state prompt)
  (setf (cdr (assoc 'prompt state)) prompt))
(defun sallet-state-set-selected-candidate (state selected-candidate)
  (setf (cdr (assoc 'selected-candidate state)) selected-candidate))
(defun sallet-state-set-futures (state futures)
  (setf (cdr (assoc 'futures state)) futures))

(defun sallet-state-incf-selected-candidate (state)
  (incf (cdr (assoc 'selected-candidate state))))
(defun sallet-state-decf-selected-candidate (state)
  (decf (cdr (assoc 'selected-candidate state))))

(defun sallet-state-get-number-of-all-candidates (state)
  (-sum (--map (length (sallet-source-get-processed-candidates it))
               (sallet-state-get-sources state))))

(defun sallet-state-get-selected-source (state)
  "Return the currently selected source and candidate.

STATE is sallet state."
  (-when-let (sources
              (--filter (< 0 (length (sallet-source-get-processed-candidates it)))
                        (sallet-state-get-sources state)))
    (let* ((offset (sallet-state-get-selected-candidate state))
           (re (car sources))
           (total 0)
           (total-old total))
      (--each-while sources (<= total offset)
        (setq total-old total)
        (setq total (+ total (length (sallet-source-get-processed-candidates it))))
        (setq re it))
      (cons re (sallet-source-get-candidate
                re
                (sallet-car-maybe
                 (let ((proc (sallet-source-get-processed-candidates re)))
                   (nth (- offset total-old) proc))))))))

(defun sallet-init-state (sources candidate-buffer)
  (let ((state (list (cons 'sources (-keep 'sallet-init-source sources))
                     (cons 'current-buffer (current-buffer))
                     (cons 'prompt "")
                     (cons 'selected-candidate 0)
                     (cons 'futures nil)
                     (cons 'candidate-buffer candidate-buffer))))
    (setq sallet-state state)
    state))

;; TODO propertize the interesting stuff, define faces
(defun sallet-render-source (state source offset)
  "Render.

OFFSET is the number of already rendered candidates before
this source.

Return number of rendered candidates."
  (with-current-buffer (sallet-state-get-candidate-buffer state)
    (let* ((selected (sallet-state-get-selected-candidate state))
           (prompt (sallet-state-get-prompt state))
           (processed-candidates (sallet-source-get-processed-candidates source))
           (renderer (sallet-source-get-renderer source))
           (coffset (- selected offset))
           (i 0))
      ;; TODO: abstract header rendering
      (when (and processed-candidates
                 (> (length processed-candidates) 0))
        (let ((header (sallet-source-get-header source)))
          (if (functionp header)
              (insert (funcall header source) "\n")
            (insert (propertize (format " • %s [%d/%d]\n"
                                        header
                                        (length (sallet-source-get-processed-candidates source))
                                        (length (sallet-source-get-candidates source)))
                                'face 'sallet-source-header)))))
      (-each processed-candidates
        (lambda (n)
          ;; `n' can be a number or a list returned from the
          ;; matcher---the `car' of which is then the index, the rest
          ;; is arbitrary meta data ignored at this stage (it is
          ;; useful when at the sorter stage)
          (let* ((candidate (sallet-source-get-candidate source (sallet-car-maybe n))))
            (insert (propertize "  " 'sallet-candidate-index (+ offset i))
                    ;; TODO: cache the already rendered lines also
                    ;; between sallet calls, there's quite a lot of
                    ;; chance it will come again, like with buffers or
                    ;; so
                    (funcall renderer candidate state (cdr-safe n))
                    "\n"))
          (setq i (1+ i))))
      i)))

(defun sallet-render-state (state render-sources)
  "Render state.

STATE is the current `sallet-state'.

RENDER-SOURCES indicates whether we need to render sources (in
case the prompt or candidates changed) or only update the
scrolling/position of selected/marked candidate."
  (when render-sources
    (with-current-buffer (sallet-state-get-candidate-buffer state)
      (erase-buffer)
      (let ((offset 0))
        (-each (sallet-state-get-sources state)
          (lambda (source)
            (setq offset (+ offset (sallet-render-source state source offset)))))
        (insert "\n\n"))))
  ;; Draw the >> pointer to the currently active candidate
  (with-current-buffer (sallet-state-get-candidate-buffer state)
    (-when-let (pos (text-property-any (point-min) (point-max) 'sallet-candidate-index (sallet-state-get-selected-candidate state)))
      (ov-clear 'sallet-selected-candidate-arrow)
      (goto-char pos)
      ;; TODO: add face, extend the overlay over the entire row? (then
      ;; we can highlight the rest with some overlay as well)
      (ov (point) (+ 2 (point)) 'display ">>" 'sallet-selected-candidate-arrow t)
      (set-window-point (get-buffer-window (sallet-state-get-candidate-buffer state)) pos))))

(defun sallet-cleanup-candidate-window ()
  "Cleanup the candidates buffer."
  (-when-let (buffer (get-buffer "*Sallet candidates*"))
    (kill-buffer buffer))
  (--each (buffer-list)
    (when (string-match-p "\\` \\*Minibuf-[0-9]+\\*\\'"(buffer-name it))
      (remove-hook 'post-command-hook 'sallet-minibuffer-post-command-hook t))))

(defvar sallet-minibuffer-post-command-hook nil
  "Closure used to update sallet window on minibuffer events.

The closure is stored in function slot.")

(defun sallet-minibuffer-setup (state)
  "Setup `post-command-hook' in minibuffer to update sallet STATE."
  ;; TODO: figure out where to do which updates... this currently
  ;; doesn't work The problem is that this lags the minibuffer input
  ;; reading every time it changes and some recomputation happens.  We
  ;; want to be able to type in a word without sallet recomputing the
  ;; full candidate list after every letter.  Helm solves this with
  ;; timers, which we will probably have to opt for too (aka poor
  ;; man's threads)
  (fset 'sallet-minibuffer-post-command-hook
        (lambda () (sallet-minibuffer-post-command state)))
  (add-hook 'post-command-hook 'sallet-minibuffer-post-command-hook nil t))

;; TODO: figure out how to do the buffer passing fast
(defun sallet-process-source-async (state source)
  "Process SOURCE asynchronously in separate emacs."
  (let ((sallet-async-state (--remove
                             (memq (car it) '(sources
                                              futures
                                              current-buffer
                                              candidate-buffer)) state))
        (sallet-async-source source))
    (async-start
     `(lambda ()
        (push ,(file-name-directory (locate-library "dash")) load-path)
        (push ,(file-name-directory (locate-library "flx")) load-path)
        (push ,(file-name-directory (locate-library "shut-up")) load-path)
        (push ,(file-name-directory (locate-library "sallet")) load-path)
        (require 'shut-up)
        (require 'sallet)
        (with-temp-buffer
          (shut-up
            ;; TODO: this isn't always necessary, should be part of the
            ;; async source generator?
            (insert ,(with-current-buffer (sallet-state-get-current-buffer state)
                       (buffer-substring-no-properties (point-min) (point-max))))
            (setq sallet-async-state (read ,(format "%S" sallet-async-state)))
            (setq sallet-async-source (read ,(format "%S" sallet-async-source)))
            (sallet-process-source sallet-async-state sallet-async-source))
          (list :candidates (sallet-source-get-candidates sallet-async-source)
                :processed-candidates (sallet-source-get-processed-candidates sallet-async-source))))
     (lambda (result)
       (-when-let ((&plist :candidates candidates
                           :processed-candidates processed-candidates)
                   result)
         (sallet-source-set-candidates source candidates)
         (sallet-source-set-processed-candidates source processed-candidates)
         (sallet-render-state state t))))))

(defun sallet-update-candidates (state source)
  "Update candidates and processed-candidatess in STATE for SOURCE."
  (let* ((candidates (sallet-source-get-candidates source)))
    (-if-let (matcher (sallet-source-get-matcher source))
        (let ((processed-candidates (funcall matcher candidates state)))
          (sallet-source-set-processed-candidates source processed-candidates))
      (sallet-source-set-processed-candidates source (sallet-make-candidate-indices candidates))))
  (let* ((processed-candidates (sallet-source-get-processed-candidates source)))
    (-when-let (sorter (sallet-source-get-sorter source))
      (sallet-source-set-processed-candidates
       source
       (funcall sorter processed-candidates state)))))

(defun sallet-process-source (state source)
  "Update sallet STATE by processing SOURCE."
  (-when-let (generator (sallet-source-get-generator source))
    (let ((gen (funcall generator source state)))
      (cond
       ((processp gen)
        (sallet-source-set-process source gen))
       (gen (sallet-source-set-candidates source gen)))))
  (sallet-update-candidates state source))

(defun sallet-process-sources (state)
  ;; TODO: add old-prompt to state
  ;; TODO: add old-processed-candidates to state
  (-each (sallet-state-get-sources state)
    (lambda (source)
      ;; Here async means async package (computing in background
      ;; emacs).  Another meaning of async is async io (using output
      ;; of a process to construct candidates).  The latter is not yet
      ;; supported, but we should get it working.
      ;; TODO: add support for taking process output and constructing
      ;; list of candidates out of that.  That could be called
      ;; "process filtering source" ?
      (if (not (sallet-source-is-async source))
          (sallet-process-source state source)
        (let ((futures (sallet-state-get-futures state))
              (source-id (aref source 2)))
          (-when-let ((&plist source-id process) futures)
            (ignore-errors
              (let ((buffer (process-buffer process)))
                (kill-process process)
                (kill-buffer buffer))))
          (let ((proc (sallet-process-source-async state source)))
            (sallet-state-set-futures state (plist-put futures source-id proc))))))))

(defun sallet-minibuffer-post-command (state)
  (let ((old-prompt (sallet-state-get-prompt state))
        (new-prompt (buffer-substring-no-properties 5 (point-max))))
    (unless (equal old-prompt new-prompt)
      (sallet-state-set-selected-candidate state 0)
      (sallet-state-set-prompt state new-prompt)
      (sallet-process-sources state))
    (sallet-render-state state (not (equal old-prompt new-prompt)))))

;; TODO: add user-facing documentation as docstring and developer
;; documentation in code.
;; TODO: add a way to preprocess the pattern before passing it to the
;; individual sources... this can help when we mix "incompatible"
;; sources together (where e.g. special prefixes mean different things
;; or are meaningless... so if we mix e.g. buffer and locate, we don't
;; want to pass leading / to locate but we want to pass it to buffer).
;; The filter is not done on the source level because the same prefix
;; (or lack of) can mean different thing to different sources.
;; TODO: add conditional evaluation of sources.  For example, first
;; run global -P, if nothing is found run ag -g, if nothing is found
;; run find . -name '*<pat>*', if nothing is found run locate...  This
;; way we don't run all the redundant "broader" searches if some
;; narrower search succeeds.  After some timeouts or a "recompute
;; signal" we can recompute all targets.
;; TODO: add some simple default implementation for "line candidates
;; from process" and "grep-like candidates from process"
(defun sallet (sources)
  (let* ((buffer (get-buffer-create "*Sallet candidates*"))
         ;; make this lexically scoped
         (state (sallet-init-state sources buffer)))
    ;; TODO: add better modeline, show number of sources/candidates etc...
    (with-current-buffer buffer
      (kill-all-local-variables)
      (setq truncate-lines t)
      (buffer-disable-undo)
      (setq cursor-type nil))
    ;; TODO: if we have actions which could use "current" buffer
    ;; during session (e.g. show context of this occur line), we
    ;; should show that buffer in a separate (existing?) window.  The
    ;; operations to restore the original state should go into
    ;; `sallet-cleanup-candidate-window'.  See also
    ;; `helm-always-two-windows'.
    (switch-to-buffer buffer)
    (sallet-render-state state t)
    (condition-case var
        (minibuffer-with-setup-hook (lambda () (sallet-minibuffer-setup state))
          ;; TODO: add support to pass maps
          ;; TODO propertize prompt
          (read-from-minibuffer ">>> " nil (let ((map (make-sparse-keymap)))
                                             (set-keymap-parent map minibuffer-local-map)
                                             (define-key map (kbd "C-n") 'sallet-candidate-up)
                                             (define-key map (kbd "C-p") 'sallet-candidate-down)
                                             (define-key map (kbd "C-o") 'sallet-candidate-next-source)
                                             map))
          (sallet-default-action))
      ;; TODO: do we want `kill-buffer-and-window?'
      (quit (sallet-cleanup-candidate-window))
      (error (sallet-cleanup-candidate-window)))))

;; TODO: figure out how to avoid the global state here: sallet-state
(defun sallet-candidate-up ()
  (interactive)
  (when (< (sallet-state-get-selected-candidate sallet-state)
           (1- (sallet-state-get-number-of-all-candidates sallet-state)))
    (sallet-state-incf-selected-candidate sallet-state)))

(defun sallet-candidate-down ()
  (interactive)
  (when (> (sallet-state-get-selected-candidate sallet-state) 0)
    (sallet-state-decf-selected-candidate sallet-state)))

(defun sallet-candidate-next-source ()
  "Set the current selected candidate to the first candidate of next source."
  (interactive)
  (let* ((current (sallet-state-get-selected-candidate sallet-state))
         ;; TODO: rewrite using text properties: mark the header with
         ;; some property when rendering, then find the next such
         ;; property after the point, go to the next line, extract the
         ;; candidate index, set it as current candidate
         (candidates-per-source (--remove
                                 (= 0 it)
                                 (--map (length (sallet-source-get-processed-candidates it))
                                        (sallet-state-get-sources sallet-state))))
         (offsets (-butlast (nreverse (--reduce-from (cons (+ it (car acc)) acc) (list 0) candidates-per-source))))
         (next (--first (< current it) offsets)))
    (unless next (setq next 0))
    (sallet-state-set-selected-candidate sallet-state next)))

(defun sallet-default-action ()
  (sallet-cleanup-candidate-window)
  (-when-let ((source . cand) (sallet-state-get-selected-source sallet-state))
    (funcall (sallet-source-get-action source) cand)))

;; TODO: create a customize group just for sources
(defcustom sallet-buffer-sources '(sallet-source-buffer)
  "Sources for `sallet-buffer'.

Since `sallet' does not make any artificial distinctions between
sources, you can put any source here.  However, keeping it
thematic and related to buffers is probably a good idea."
  :group 'sallet
  :type '(repeat symbol))

(defun sallet-buffer ()
  "Display buffer-like candidates.

Takes the list of used sources from `sallet-buffer-sources'."
  (interactive)
  (sallet sallet-buffer-sources))

(defun sallet-occur ()
  "Show all lines in current buffer matching the fuzzy pattern.

First, all lines matching the input pattern \"fuzzily\" are
collected.  They are then scored and ordered to bring the most
interesting lines at the top.  Therefore, the results are not in
the same order as they appear in the buffer.  If you want that,
use `salet-occur-nonfuzzy'.

The scoring algorithm is from the package `flx'.

If you want to customize the matching algorithm, you can extend
sallet source `sallet-source-occur-fuzzy'."
  (interactive)
  (sallet (list sallet-source-occur-fuzzy)))

(defun sallet-occur-async ()
  (interactive)
  (sallet (list sallet-source-occur-async)))

(defun sallet-occur-nonfuzzy ()
  "Show all lines in current buffer matching pattern.

The lines are presented in the same order as they appear in the
file.  The lines are matched against each word in the input
separately.

See also `sallet-occur' for a fuzzy variant.  If you want to
customize the matching algorithm, you can extend sallet source
`sallet-source-occur'."
  (interactive)
  (sallet (list sallet-source-occur)))

(defun sallet-imenu ()
  (interactive)
  (sallet (list sallet-source-imenu)))

;; TODO: write sallet for opening files

;; TODO: better name, put it in the framework/pipeline somewhere
(defun sallet-linereader (filter)
  "Read stream of data and pass complete lines to FILTER.

Returns a function which can be used as process sentinel.

FILTER is a function which could be used with
`set-process-filter'.

This decorator buffers input until it can pass the data further
and is useful as a buffer between a process producing data and an
Emacs function operating on the data which expects to get
complete lines as input."
  (let ((data ""))
    (lambda (process string)
      (let* ((data (concat data string))
             (line-data (split-string data "\n")))
        (while (cdr line-data)
          (funcall filter process (car line-data))
          (!cdr line-data))
        (setq data (car line-data))))))

;; TODO: better name, put it in the framework/pipeline somewhere
(defun sallet-linebased-candidate-generator (transformer source state)
  "Turn a TRANSFORMER into candidate generator for SOURCE.

TRANSFORMER is a function which given a string generates one
candidate from it.

SOURCE is an instance of sallet source.

STATE is a sallet state."
  (let ((n 0))
    (sallet-source-set-candidates source (make-vector 32 nil))
    (lambda (_process string)
      (let* ((buffer (sallet-source-get-candidates source))
             (cand (funcall transformer string))
             (bl (length buffer)))
        (when (= n bl)
          (let ((new-buffer (make-vector (* 2 bl) nil))
                (i 0))
            (mapc (lambda (x)
                    (aset new-buffer i x)
                    (setq i (1+ i)))
                  buffer)
            (setq buffer new-buffer)
            (sallet-source-set-candidates source new-buffer))
          (sallet-update-candidates state source)
          (sallet-render-state state t))
        (aset buffer n cand)
        (setq n (1+ n))
        (sallet-source-set-candidates source buffer)))))

(provide 'sallet)

;; Local Variables:
;; eval: (add-to-list 'imenu-generic-expression '("Sallet sources" "\\(^(sallet-defsource +\\)\\(\\_<.+?\\_>\\)" 2))
;; End:

;;; sallet.el ends here
