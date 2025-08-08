import os
import asyncio
from .pdf_process import process_interview_pdfs


if __name__ == "__main__":

 
    TRS_PDF_FOLDER = os.path.join(os.path.dirname(__file__),".trs_pdf")
    OUTPUT_CSV = os.path.join(os.path.dirname(__file__),"interview_metadata.csv")

    trs_count = len(os.listdir(TRS_PDF_FOLDER))

    print(f"TRS PDFs found: {trs_count}")
    if trs_count == 0:
          print("No TRS PDFs found!")
          exit()

    print(f"\nProcessing {trs_count} TRS PDFs...")

    asyncio.run(process_interview_pdfs(TRS_PDF_FOLDER, OUTPUT_CSV))







            