#!/usr/bin/env python3
"""
Batch convert all PDFs in a folder (and subfolders) to text using:
    pdftotext -layout "input.pdf" "output.txt"

Requirements:
    - poppler-utils installed (provides pdftotext command)
"""

import argparse
import subprocess
from pathlib import Path

def convert_pdf(pdf_path: Path, in_root: Path, out_root: Path):
    rel = pdf_path.relative_to(in_root)
    txt_path = out_root / rel.with_suffix(".txt")
    txt_path.parent.mkdir(parents=True, exist_ok=True)
    
    cmd = ["pdftotext", "-layout", str(pdf_path), str(txt_path)]
    subprocess.run(cmd, check=True)
    return rel

def main():
    ap = argparse.ArgumentParser(description="Batch run pdftotext -layout on all PDFs in a folder.")
    ap.add_argument("--input-dir", required=True, help="Directory containing PDF files")
    ap.add_argument("--output-dir", required=True, help="Directory to save text files")
    args = ap.parse_args()

    in_root = Path(args.input_dir).resolve()
    out_root = Path(args.output_dir).resolve()
    out_root.mkdir(parents=True, exist_ok=True)

    pdfs = sorted([p for p in in_root.rglob("*.pdf")])
    if not pdfs:
        print(f"No PDFs found in {in_root}")
        return

    print(f"Found {len(pdfs)} PDFs. Converting...")
    for pdf in pdfs:
        try:
            rel = convert_pdf(pdf, in_root, out_root)
            print(f"{rel} converted to text.")
        except subprocess.CalledProcessError as e:
            print(f"Error converting {pdf}: {e}")

    print("\nDone.")

if __name__ == "__main__":
    main()
