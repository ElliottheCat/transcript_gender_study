#!/usr/bin/env python3
"""
Batch-clean USHMM transcript .txt files.

- Removes repeated site header/footer lines & disclaimers
- Removes index/page lines like "USHMM Archives RG-50.999.0630 3"
- Collapses excessive blank lines
- (optional) --join-lines: concatenates lines within a paragraph until a new line
  with a colon appears in the first ~15 characters (e.g., Q:, A:, Name:)
- Writes to an output directory with the same filenames
- Parallelized for speed
"""

import argparse, re, sys, os
from pathlib import Path
from concurrent.futures import ProcessPoolExecutor, as_completed

# ----- Boilerplate/disclaimer removal (tight, bounded) -----
PATTERNS = [
    # Site footer/header pair
    r"(?:https?://collections\.ushmm\.org\s+Contact reference@ushmm\.org for further information about this collection\s*)+",
    r"This is a verbatim transcript of spoken word\. It is not the primary source, and it has not been checked for spelling or accuracy\.\s*",

    # Intro disclaimer blocks (allowing line breaks, bounded to avoid over-deleting)
    r"The following transcript is the result of a recorded interview\.[\s\S]{0,800}?should not be quoted or used without first checking it against\s+the interview\.\s*",
    r"The interview is part of the United States Holocaust Memorial Museum(?:'s)? collection of oral testimonies\.[\s\S]{0,600}?catalog record\.\s*",

    # Common event/rough-draft boilerplate
    r"Communication Access Realtime Translation \(CART\) .*? rough-draft format\.\s*",
    r"ROUGH DRAFT TRANSCRIPT\s+NOT A VERBATIM RECORD\s*",

    # Index/page markers like: "USHMM Archives RG-50.030*0148" or "USHMM Archives RG-50.999.0630 3"
    r"^\s*USHMM Archives RG-[^\n]*$",
]

#collapses 3+ newlines → 2 newlines.
EXTRA_BLANKS = re.compile(r"\n{3,}", re.M)

# Colon-in-first-~15-characters (speaker turn / label) e.g., "Q:", "A:", "Interviewer:"
SPEAKER_LINE = re.compile(r"^\s*\S.{0,12}:\s", re.M)

# collapse 2+ spaces/tabs but leave ellipses intact
RUNS_OF_SPACE = re.compile(r"[ \t]{2,}")
ELLIPSIS_GUARD = "\uFFF9ELLIPSIS\uFFFA"  # unlikely sentinel

WORD_HYPHEN_BREAK = re.compile(r"(\w+)-\s+([a-z]\w*)")  # end-of-line hyphen -> next lowercase word

# STRICT mode only for literal Q:/A: turns
SPEAKER_QA = re.compile(r"^\s*[QA]\s*:\s*", re.I)

# --- Inline page-header cleanup (safe heuristic) ---
MONTHS = r"(January|February|March|April|May|June|July|August|September|October|November|December)"

# Matches: "Interview with <Name> [<page#>] <Month> <D>, <YYYY> [RG-…]" even if embedded in a paragraph
INLINE_INTERVIEW_HEADER = re.compile(
    rf"\bInterview\s+(?:with|of)\s+[A-Z][A-Za-z .,'\-]{{1,80}}(?:\s+\d{{1,3}})?\s+{MONTHS}\s+\d{{1,2}},\s+\d{{4}}(?:\s+RG-[0-9.*\-]+)?\b"
)
# page numbers like "3", "12", "1234" on their own line
PAGE_ONLY = re.compile(r"^\s*\d{1,4}\s*$")

# Strict month token (already defined as MONTHS)
# Cross-line "Interview with NAME Month DD, YYYY [page]" block matcher (anchored at line start)
INTERVIEW_BLOCK = re.compile(
    rf"^\s*Interview\s+(?:with|of)\s+"
    r"[A-Z][A-Za-z .,'\-]{1,80}\s+"            # Name (capitalized, modestly bounded)
    rf"{MONTHS}\s+\d{{1,2}},\s*\d{{4}}"        # Month DD, YYYY
    r"(?:\s+\d{1,4})?\s*$",                    # optional trailing page number
    re.IGNORECASE
)



def strip_inline_headers(s: str) -> str:
    lines = s.splitlines()
    cleaned = []
    for idx, line in enumerate(lines):
        if idx > 50:
            # remove inline "Interview with ... Month D, YYYY ..." headers (your existing pattern)
            line = INLINE_INTERVIEW_HEADER.sub(" ", line)
            # NEW: remove lines that are just a page number
            if PAGE_ONLY.match(line):
                continue
            line = re.sub(r"\s{2,}", " ", line)
        cleaned.append(line)
    return "\n".join(cleaned)

def remove_interview_blocks_windowed(s: str, cutoff: int = 50, lookahead: int = 4) -> str:
    """
    Remove page headers like:
      Interview with <Name>
      January 23,
      2014
      5
    or all on one line, but only if they occur after `cutoff` lines.
    """
    lines = s.splitlines()
    out = []
    i = 0
    n = len(lines)

    while i < n:
        # Don't touch the early front-matter
        if i <= cutoff:
            out.append(lines[i])
            i += 1
            continue

        # Try to match a header block across up to `lookahead` lines
        matched = False
        max_k = min(lookahead, n - i)
        for k in range(1, max_k + 1):
            window = " ".join(l.strip() for l in lines[i:i+k])
            if INTERVIEW_BLOCK.match(window):
                # Skip these k lines (drop the header block)
                i += k
                matched = True
                break

        if matched:
            continue

        # Also drop a lone page number line in the body
        if PAGE_ONLY.match(lines[i]):
            i += 1
            continue

        out.append(lines[i])
        i += 1

    return "\n".join(out)



def remove_boilerplate(text: str) -> str:
    for pat in PATTERNS:
        text = re.sub(pat, "", text, flags=re.MULTILINE | re.DOTALL)
    return text

def _normalize_paragraph_spaces(s: str) -> str:
    # protect ellipses
    s = s.replace("...", ELLIPSIS_GUARD)
    s = RUNS_OF_SPACE.sub(" ", s)
    # restore ellipses
    return s.replace(ELLIPSIS_GUARD, "...")

def _dehyphenate_paragraph(s: str) -> str:
    # multiple passes in case there are several breaks
    for _ in range(3):
        s, n = WORD_HYPHEN_BREAK.subn(r"\1\2", s)
        if n == 0:
            break
    return s

def join_wrapped_lines_until_colon(text: str, normalize_spaces: bool, dehyphenate: bool) -> str:
    lines = text.splitlines()
    out, buffer = [], ""
    just_saw_speaker = False
    qa_strict = False

    for idx, line in enumerate(lines):
        stripped = line.strip()

        if stripped == "":
            if qa_strict:
                # inside Q/A: drop layout blanks entirely
                continue
            if just_saw_speaker:
                just_saw_speaker = False
                continue
            if buffer:
                para = buffer.strip()
                if dehyphenate:      para = _dehyphenate_paragraph(para)
                if normalize_spaces: para = _normalize_paragraph_spaces(para)
                out.append(para); buffer = ""
            out.append("")
            continue

        if SPEAKER_LINE.match(line):
            if buffer:
                para = buffer.strip()
                if dehyphenate:      para = _dehyphenate_paragraph(para)
                if normalize_spaces: para = _normalize_paragraph_spaces(para)
                out.append(para)
            buffer = stripped
            just_saw_speaker = True
            qa_strict = bool(SPEAKER_QA.match(line))
            continue

        # --- NEW: when in strict Q/A, ignore standalone page numbers
        if qa_strict and PAGE_ONLY.match(line):
            continue

        # continuation
        buffer = (buffer + " " + stripped) if buffer else stripped
        just_saw_speaker = False

    if buffer:
        para = buffer.strip()
        if dehyphenate:      para = _dehyphenate_paragraph(para)
        if normalize_spaces: para = _normalize_paragraph_spaces(para)
        out.append(para)

    return "\n".join(out)



def clean_text(s: str, join_lines: bool, normalize_spaces: bool, dehyphenate: bool) -> str:
    s = remove_boilerplate(s)

    # Pass 1: remove split/inline interview headers & page-only lines (after cutoff)
    s = remove_interview_blocks_windowed(s)   # NEW
    s = strip_inline_headers(s)               # keep your existing single-line cleanup

    if join_lines:
        s = join_wrapped_lines_until_colon(s, normalize_spaces, dehyphenate)

        # Pass 2: after joining, do another cleanup in case a header got glued
        s = remove_interview_blocks_windowed(s)  # NEW
        s = strip_inline_headers(s)              # existing
    elif normalize_spaces:
        s = "\n".join(_normalize_paragraph_spaces(line) if line.strip() else "" for line in s.splitlines())

    s = EXTRA_BLANKS.sub("\n\n", s)
    return s.strip() + "\n"



def process_one(path_in: Path, in_root: Path, out_root: Path, join_lines: bool, normalize_spaces: bool, dehyphenate: bool):
    
    rel = path_in.relative_to(in_root)
    path_out = out_root / rel
    path_out.parent.mkdir(parents=True, exist_ok=True)
    raw = path_in.read_text(errors="ignore")
    cleaned = clean_text(raw, join_lines, normalize_spaces, dehyphenate)
    path_out.write_text(cleaned)
    return (str(rel), len(raw), len(cleaned))

def main():
    ap = argparse.ArgumentParser(description="Clean USHMM transcript text files at scale.")
    ap.add_argument("--input-dir", required=True, help="Directory containing .txt files")
    ap.add_argument("--output-dir", required=True, help="Directory to write cleaned files")
    ap.add_argument("--join-lines", action="store_true",
                    help="Concatenate non-blank lines until the next line that has a colon within the first ~15 chars (e.g., Q:, A:, Name:)")
    ap.add_argument("--workers", type=int, default=os.cpu_count(), help="Parallel workers (default: CPU count)")
    ap.add_argument("--normalize-spaces", action="store_true", help="Collapse multiple spaces/tabs inside lines to a single space (keeps '...').")
    ap.add_argument("--dehyphenate", action="store_true", help="Join soft hyphenation across wrapped lines (word- \\n part -> wordpart).")

    args = ap.parse_args()

    in_root = Path(args.input_dir).resolve()
    out_root = Path(args.output_dir).resolve()
    if not in_root.exists():
        print(f"Input dir not found: {in_root}", file=sys.stderr); sys.exit(1)
    out_root.mkdir(parents=True, exist_ok=True)

    txts = sorted([p for p in in_root.rglob("*.txt") if p.is_file()])
    if not txts:
        print("No .txt files found.", file=sys.stderr); sys.exit(2)

    print(f"Cleaning {len(txts)} files from {in_root} -> {out_root} (workers={args.workers})")
    total_in = total_out = 0

    with ProcessPoolExecutor(max_workers=args.workers) as ex:
        futures = {
            ex.submit(process_one, p, in_root, out_root, args.join_lines, args.normalize_spaces, args.dehyphenate): p
            for p in txts
        }
        for fut in as_completed(futures):
            rel, n_in, n_out = fut.result()
            total_in += n_in; total_out += n_out
            print(f"✓ {rel}")

    ratio = (total_out / total_in) if total_in else 1.0
    print(f"\nDone. Bytes in: {total_in:,}  Bytes out: {total_out:,}  Size ratio: {ratio:.2f}")

if __name__ == "__main__":
    main()
