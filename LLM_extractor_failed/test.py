import os
import asyncio
import sys

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from LLM_extractor_failed.pdf_process import process_interview_pdfs
import shutil

if __name__ == "__main__":
    TRS_PDF_FOLDER = ".trs_pdf"
    OUTPUT_CSV = "test_results.csv"

    # Check if folder exists and has PDFs
    if not os.path.exists(TRS_PDF_FOLDER):
        print(f"Folder {TRS_PDF_FOLDER} doesn't exist!")
        exit()

    pdf_files = [f for f in os.listdir(TRS_PDF_FOLDER) if f.endswith('.pdf')]
    print(f"Found {len(pdf_files)} PDF files")

    if len(pdf_files) == 0:
        print("No PDF files found!")
        exit()

    # Create test folder and copy first 10 PDFs
    TEST_PDF_FOLDER = "test_pdf_folder"
    if not os.path.exists(TEST_PDF_FOLDER):
        os.makedirs(TEST_PDF_FOLDER)
    
    # Limit to first 10 for testing
    if len(pdf_files) > 2:
        print(f"Limiting to first 10 PDFs for testing")
        pdf_files = pdf_files[:2]
    
    # Copy PDFs to test folder
    for pdf_file in pdf_files:
        src = os.path.join(TRS_PDF_FOLDER, pdf_file)
        dst = os.path.join(TEST_PDF_FOLDER, pdf_file)
        shutil.copy2(src, dst)
    
    print(f"Copied {len(pdf_files)} PDFs to {TEST_PDF_FOLDER}")
    
    asyncio.run(process_interview_pdfs(TEST_PDF_FOLDER, OUTPUT_CSV))
