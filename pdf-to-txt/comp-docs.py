#!/usr/bin/env python3
import argparse, difflib, sys
from pathlib import Path

CSS = """
<style>
body{font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial;margin:20px;background:#0b0e11;color:#e6edf3}
a{color:#7aa2f7;text-decoration:none} a:hover{text-decoration:underline}
h1,h2{margin:.2rem 0 1rem 0}
ul{line-height:1.6}
table.diff{font-family:ui-monospace,Menlo,Consolas,monospace;border-collapse:collapse;border:1px solid #2d333b;width:100%}
table.diff th,table.diff td{border-right:1px solid #2d333b;padding:.25rem .5rem;vertical-align:top;white-space:pre-wrap;word-break:break-word}
.diff_header,.diff_next{background:#11161c;color:#9aa4b2}
.diff_add{background:#0f2a18;color:#58d68d}
.diff_chg{background:#2a1e0f;color:#f5c46b}
.diff_sub{background:#2a1214;color:#ff7b72}
.meta{color:#9aa4b2;font-size:.95rem;margin-bottom:1rem}
</style>
"""

def read_lines(p: Path) -> list[str]:
    return p.read_text(encoding="utf-8", errors="ignore").splitlines()

def make_html_diff(a_lines, b_lines, left_label, right_label, context=3) -> str:
    hd = difflib.HtmlDiff(wrapcolumn=120)
    table = hd.make_table(a_lines, b_lines, left_label, right_label, context=True, numlines=context)
    return f"<!doctype html><meta charset='utf-8'><title>Diff: {left_label} ⇄ {right_label}</title>{CSS}<h1>Diff</h1><div class='meta'>{left_label} ⇄ {right_label} (±{context} lines of context)</div>{table}"

def main():
    ap = argparse.ArgumentParser(description="Batch HTML diffs for same-named files across two directories.")
    ap.add_argument("left_dir", help="Folder with ORIGINAL files (e.g., precleaned)")
    ap.add_argument("right_dir", help="Folder with UPDATED files (e.g., postcleaned)")
    ap.add_argument("-o", "--out-dir", default="docs-diffs", help="Output folder for HTML diffs (default: docs-diffs)")
    ap.add_argument("--context", type=int, default=3, help="Context lines around changes (default: 3)")
    ap.add_argument("--names", nargs="*", help="Optional explicit list of filenames to compare (space-separated)")
    args = ap.parse_args()

    left = Path(args.left_dir).expanduser().resolve()
    right = Path(args.right_dir).expanduser().resolve()
    out = Path(args.out_dir).expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)

    if not left.exists() or not right.exists():
        sys.exit(f"One of the input dirs does not exist:\n  {left}\n  {right}")

    if args.names:
        names = [Path(n).name for n in args.names]
    else:
        # Intersect *.txt filenames by default
        left_names = {p.name for p in left.glob("*.txt")}
        right_names = {p.name for p in right.glob("*.txt")}
        names = sorted(left_names & right_names)

    if not names:
        sys.exit("No matching filenames to compare.")

    index_items = []
    for name in names:
        lp = left / name
        rp = right / name
        if not lp.exists() or not rp.exists():
            print(f"• Skipping (missing in one side): {name}")
            continue

        a, b = read_lines(lp), read_lines(rp)
        html = make_html_diff(a, b, f"{name} (pre)", f"{name} (post)", context=args.context)
        out_file = out / f"{name}.diff.html"
        out_file.write_text(html, encoding="utf-8")
        print(f"✓ Wrote {out_file}")
        rel = out_file.name
        index_items.append(f"<li><a href='{rel}'>{name}</a></li>")

    index_html = f"<!doctype html><meta charset='utf-8'><title>Docs diffs</title>{CSS}<h1>Docs diffs</h1><div class='meta'>Left: {left}<br>Right: {right}</div><ul>{''.join(index_items)}</ul>"
    (out / "index.html").write_text(index_html, encoding="utf-8")
    print(f"\nOpen: {out/'index.html'}")

if __name__ == "__main__":
    main()
