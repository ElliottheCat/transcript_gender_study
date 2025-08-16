# Preprocessing of transcripts

## Quick Start

### Metadata cleaning
```bash
python clean-metadata.py --input-dir pdf-to-txt/precleaned-txt --output-dir pdf-to-txt/postcleaned-txt --join-line --normalize-spaces --dehyphenate 
```

### Difference comparison

Enter the names of the files you want to compare after the `--names` flag:
```bash
python comp-docs.py "pdf-to-txt/precleaned-txt" "pdf-to-txt/postcleaned-txt" -o "/Users/xiyuancao/Desktop/topic-extraction/pdf-to-txt/docs-diffs" --names RG-50.106.0218_trs_en.txt RG-50.042.0018_trs_en.txt RG-50.233.0077_trs_en.txt RG-50.030.0148_trs_en.txt RG-50.471.0007_trs_en.txt RG-50.999.0574_trs_en.txt RG-50.233.0126_trs_en.txt RG-50.549.02.0071_trs_en.txt RG-50.344.0005_trs_en.txt
```

Navigate to `pdf-to-txt/docs-diffs` and use "Go Live" in VSCode to view the results in a browser.

## Python Script Documentation

### clean-metadata.py

#### Command Line Interface & Input/Output

**Arguments:**
- `--input-dir` (required): Root folder to scan for `.txt` files recursively
- `--output-dir` (required): Root folder where cleaned files are written, preserving relative paths/filenames
- `--join-lines` (flag): Enables paragraph line-joining logic
- `--normalize-spaces` (flag): Collapses runs of spaces/tabs inside lines (preserves ellipses)
- `--dehyphenate` (flag): Joins end-of-line hyphenation (word-\npart → wordpart)
- `--workers` (int, default: CPU count): Number of parallel processes for cleaning files

**File Processing:**
- Recursively collects every regular file matching `*.txt` under `--input-dir`
- Reads each file as text with `errors="ignore"` (silently drops undecodable bytes)
- Writes cleaned content to corresponding path under `--output-dir` (creating parent dirs as needed)
- Prints a ✓ line per processed file
- Displays final "Bytes in / out / ratio" report

**Exit Behavior:**
- Exits with error if `--input-dir` is missing or contains no .txt files

**Parallelism:**
- Uses ProcessPoolExecutor with `max_workers=--workers` (one process per file task)

#### Text Transformations (Applied in Order)

##### 1. Boilerplate/Disclaimer Removal (Global)
Applies regex removals across entire text (multi-line & dotall):

**USHMM Footer Pair:**
- `https://collections.ushmm.org`
- `Contact reference@ushmm.org for further information about this collection`

**"Verbatim Transcript" Disclaimer Sentence**

**Intro Disclaimers (Bounded):**
- Block beginning with "The following transcript is the result of a recorded interview." through "should not be quoted… against the interview."
- Block beginning with "The interview is part of the United States Holocaust Memorial Museum's collection…" through "…catalog record."

**CART/Rough-Draft Boilerplate:**
- Lines mentioning Communication Access Realtime Translation (CART) rough-draft format
- `ROUGH DRAFT TRANSCRIPT NOT A VERBATIM RECORD`

**Index Header Lines:**
- Any line starting with `USHMM Archives RG-…` (entire line removed)

**Hometeam Caption Footer:**
- Removes standalone line `www.hometeamcaptions.com`

##### 2. Page-Header Removal (Windowed, After Front-Matter)
Runs twice: before and after joining (if enabled).

- **Front-matter cutoff:** Leaves first 51 lines (0–50) untouched
- **Cross-line header matcher:** Drops blocks of up to 4 lines that, when joined with spaces, match:
    - Interview (with|of) <Capitalized Name> <Month> <Day>, <Year> [optional page number]
    - Name limited to 1–80 chars, including spaces, periods, commas, apostrophes, and hyphens
- **Standalone page numbers:** After cutoff, removes lines containing only 1–4 digits

##### 3. Inline Interview Header Removal (Single-Line, After Front-Matter)
Runs twice: before and after joining (if enabled).

- After line 50, removes inline spans matching:
    - Interview (with|of) <Name> <Month> <Day>, <Year> [RG-…]
    - Keeps rest of line; collapses multiple spaces created by removal
- Removes entire lines containing only page numbers (1–4 digits) after cutoff

##### 4. Line Joining (Enabled by `--join-lines`)
Collapses layout-driven wraps into single logical lines while preserving speaker turns.

**Speaker Detection (Starts New Unit):**
- **Colon speakers:** Colon within first ~15 characters (e.g., Q:, A:, Interviewer:)
    - Pattern: `^\s*\S.{0,12}:\s`
- **Double-arrow speakers:** Lines like `>> Betsy Anthony:` (First Person series)
    - Pattern: `^\s*>>\s*\S.{0,50}:\s`

**Strict Q/A Mode:** If speaker line is literal `Q:` or `A:` (case-insensitive):
- Drops blank lines inside answer block (layout noise)
- Skips standalone page-number lines inside block

**Continuation Rules:**
- Within speaker turn: subsequent non-blank, non-speaker lines joined with space
- Between speaker turns: finishing turn flushes it as single line

**Result:** Q:/A:/>> Name: lines remain distinct; wrapped lines under them are joined to that turn.

##### 5. Space Normalization (`--normalize-spaces`)
**When joining:** Normalizes each flushed paragraph/turn by:
- Protecting ellipses with sentinel
- Replacing runs of spaces/tabs (`[ \t]{2,}`) with single space
- Restoring ellipses

**When not joining:** Applies same normalization to each non-blank line independently

##### 6. Dehyphenation (`--dehyphenate`)
For each flushed paragraph/turn, up to 3 passes of:
- `(\w+)-\s+([a-z]\w*)` → `\1\2`
- Joins end-of-line hyphenated word if next token starts with lowercase

##### 7. Blank-Line Compaction
After all steps, collapses 3+ consecutive newlines into exactly 2 newlines (space saving).


#### Function Flow Per File
1. Read raw text
2. `remove_boilerplate()`
3. `remove_interview_blocks_windowed()` (cutoff-aware, cross-line + page numbers)
4. `strip_inline_headers()` (inline within a line + page numbers)
5. If `--join-lines`:
   - `join_wrapped_lines_until_colon()`
   - `remove_interview_blocks_windowed()` (again)
   - `strip_inline_headers()` (again)
   - (optional) normalize & dehyphenate applied during flushes
6. Else if `--normalize-spaces`: per-line normalization
7. Collapse extra blanks (`\n{3,}` → `\n\n`)
8. Write the cleaned text with a trailing newline

#### Notes / Behaviors Worth Knowing
- The front-matter cutoff (line index ≤ 50) protects titles/abstracts from header/page stripping
- The double pass of header stripping helps catch headers that become inline after joining
- `errors="ignore"` means any undecodable bytes are dropped quietly (no replacement markers)
- Output always ends with a single trailing newline, and internal spacing is normalized only if the corresponding flags are set
- The script does not alter punctuation except:
  - dehyphenating split words (if `--dehyphenate`)
  - preserving ellipses (...) during space normalization (regex sometimes removes ... along with space run)
  - collapsing whitespace introduced by header removals