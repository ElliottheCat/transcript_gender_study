"""
ushmm-extractor.py
====================

This script iterates over a folder containing transcript files whose names begin with a United States Holocaust Memorial Museum (USHMM) **RG number**.  It uses the USHMM collections site's public JSON endpoints to look up catalog information for each RG number and extracts selected metadata: interview summary, interviewee(s), interviewer(s), interview date, topical subjects, geographic subjects, personal names, and corporate names.  The results are written to a CSV file.

Each row in the CSV contains the original
   filename, the extracted RG number, and the scraped metadata.  Columns
   include:

   * ``filename`` – original transcript filename
   * ``rg_number`` – RG number extracted from the filename
   * ``interview_summary`` – textual summary of the interview
   * ``interviewee`` – person(s) interviewed
   * ``interviewer`` – person(s) conducting the interview
   * ``interview_date`` – date of the interview
   * ``subject_topical`` – topical terms (semicolon‑separated)
   * ``subject_geography`` – geographic names (semicolon‑separated)
   * ``subject_person`` – personal names (semicolon‑separated)
   * ``subject_corporate`` – corporate names (semicolon‑separated)

The script respects the USHMM web resources by inserting a small delay
between requests.  If you process hundreds of records, you may wish to
increase the ``sleep`` time to reduce load on the server.  Network errors
and missing fields are handled gracefully.

Usage
-----

Run the script from a Python environment with network access:

```
python ushmm_extractor.py --input_dir path/to/postcleaned-txt --output_csv output.csv
```

Ensure that the machine running the script can reach ``collections.ushmm.org``.
"""

import argparse
import csv
import json
import os
import re
import time
from typing import Any, Dict, Iterable, List, Optional, Tuple

import requests


def extract_rg_number(filename: str) -> Optional[str]:
    """Extract the RG number from a filename.

    Filenames are expected to begin with the RG number followed by an
    underscore.  For example, ``RG-50.233.0026_trs_en.txt`` will yield
    ``RG-50.233.0026``.  If no RG prefix is found, return ``None``.
    """
    match = re.match(r"^(RG-[^_]+)", filename)
    if match:
        return match.group(1)
    return None


def search_catalog_by_rg(rg_number: str) -> Optional[str]:
    """Search the USHMM catalog for an RG number and return the IRN.

    The search endpoint returns a list of documents.  We select the
    document whose ``rg_number`` matches exactly.  If none match, return
    ``None``.
    """
    base_url = "https://collections.ushmm.org/search/catalog.json"
    params = {"q": rg_number}
    response = requests.get(base_url, params=params, headers={"User-Agent": "Mozilla/5.0"})
    response.raise_for_status()
    data = response.json()
    docs = data.get("response", {}).get("docs", [])
    for doc in docs:
        doc_rg = doc.get("rg_number")
        # normalize hyphen vs. en dash just in case
        if doc_rg and doc_rg.replace("\u2011", "-") == rg_number:
            return doc.get("irn")
    return None


def fetch_record(irn: str) -> Dict[str, Any]:
    """Fetch a catalog record by IRN and return the JSON document."""
    url = f"https://collections.ushmm.org/search/catalog/irn{irn}.json"
    response = requests.get(url, headers={"User-Agent": "Mozilla/5.0"})
    response.raise_for_status()
    data = response.json()
    return data.get("response", {}).get("document", {})


def normalize_field(value: Any) -> str:
    """Normalize a field to a semicolon-delimited string.

    Fields in the JSON may be a single string or a list of strings.  If
    ``value`` is a list, its elements are joined with ``; ``.  ``None`` or
    missing values yield an empty string.
    """
    if value is None:
        return ""
    if isinstance(value, list):
        return "; ".join(str(v) for v in value)
    return str(value)


def extract_metadata(record: Dict[str, Any]) -> Dict[str, str]:
    """Extract the desired metadata fields from a record JSON.

    The JSON fields we extract mirror the sections on the website:

    * interview_summary – textual summary of the testimony
    * interviewee – person(s) interviewed
    * interviewer – person(s) conducting the interview
    * display_date – interview date
    * subject_topical – topical terms
    * subject_geography – geographic names
    * subject_person – personal names
    * subject_corporate – corporate names
    """
    return {
        "interview_summary": record.get("interview_summary", ""),
        "interviewee": normalize_field(record.get("interviewee")),
        "interviewer": normalize_field(record.get("interviewer")),
        "interview_date": normalize_field(record.get("display_date")),
        "subject_topical": normalize_field(record.get("subject_topical")),
        "subject_geography": normalize_field(record.get("subject_geography")),
        "subject_person": normalize_field(record.get("subject_person")),
        "subject_corporate": normalize_field(record.get("subject_corporate")),
    }


def process_files(input_dir: str, sleep: float = 0.5) -> Iterable[Tuple[str, str, Dict[str, str]]]:
    """Iterate over transcript files and yield extracted metadata.

    For each filename in ``input_dir`` that looks like an RG transcript file,
    this function extracts the RG number, searches for the corresponding
    catalog record, fetches the metadata, and yields a tuple of
    ``(filename, rg_number, metadata_dict)``.

    A brief pause (``sleep`` seconds) is inserted between network
    interactions to reduce load on the remote server.  Adjust this value
    depending on the number of files and network conditions.
    """
    files = sorted(f for f in os.listdir(input_dir) if f.lower().endswith(".txt"))
    for filename in files:
        rg_number = extract_rg_number(filename)
        if not rg_number:
            continue
        try:
            irn = search_catalog_by_rg(rg_number)
        except Exception as e:
            print(f"Error searching for {rg_number}: {e}")
            irn = None
        if not irn:
            print(f"No catalog record found for {rg_number}")
            metadata = {
                "interview_summary": "",
                "interviewee": "",
                "interviewer": "",
                "interview_date": "",
                "subject_topical": "",
                "subject_geography": "",
                "subject_person": "",
                "subject_corporate": "",
            }
        else:
            try:
                record = fetch_record(irn)
                metadata = extract_metadata(record)
            except Exception as e:
                print(f"Error fetching record {irn} for {rg_number}: {e}")
                metadata = {
                    "interview_summary": "",
                    "interviewee": "",
                    "interviewer": "",
                    "interview_date": "",
                    "subject_topical": "",
                    "subject_geography": "",
                    "subject_person": "",
                    "subject_corporate": "",
                }
        yield filename, rg_number, metadata
        # Pause between iterations
        time.sleep(sleep)


def main() -> None:
    parser = argparse.ArgumentParser(description="Extract USHMM metadata for transcript files.")
    parser.add_argument("--input_dir", required=True, help="Directory containing transcript files")
    parser.add_argument("--output_csv", required=True, help="Output CSV filename")
    parser.add_argument("--sleep", type=float, default=0.5, help="Seconds to sleep between requests")
    args = parser.parse_args()
    # Prepare CSV file
    fieldnames = [
        "filename",
        "rg_number",
        "interview_summary",
        "interviewee",
        "interviewer",
        "interview_date",
        "subject_topical",
        "subject_geography",
        "subject_person",
        "subject_corporate",
    ]
    with open(args.output_csv, "w", newline="", encoding="utf-8") as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()
        for filename, rg_number, metadata in process_files(args.input_dir, sleep=args.sleep):
            row = {"filename": filename, "rg_number": rg_number, **metadata}
            writer.writerow(row)


if __name__ == "__main__":
    main()
