import asyncio
import os
import shutil
from typing import List


def filter_trs_pdfs(source_folder: str, destination_folder: str):
    """Copy only PDFs with 'trs' in filename to destination folder."""

    # Create destination folder if it doesn't exist
    os.makedirs(destination_folder, exist_ok=True)

    trs_count = 0
    total_count = 0

    for filename in os.listdir(source_folder):
        if filename.endswith('.pdf'):
            total_count += 1

            if 'trs' in filename.lower():
                source_path = os.path.join(source_folder, filename)
                dest_path = os.path.join(destination_folder, filename)

                shutil.copy2(source_path, dest_path)
                trs_count += 1
                print(f"Copied: {filename}")

    print(f"\nFiltering complete!")
    print(f"Total PDFs found: {total_count}")
    print(f"TRS PDFs copied: {trs_count}")
    print(f"Destination: {destination_folder}")

    return trs_count



if __name__ == "__main__":
        
    PDF_FOLDER = os.path.join(os.path.dirname(__file__), ".pdfs")
    TRS_PDF_FOLDER = os.path.join(os.path.dirname(__file__),".trs_pdf")

# Filter TRS PDFs
    print("Filtering PDFs with 'trs' in filename... Source: {PDF_FOLDER}, Destination: {TRS_PDF_FOLDER}")
    trs_count = filter_trs_pdfs(PDF_FOLDER, TRS_PDF_FOLDER)