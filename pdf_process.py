import os
from typing import List, Dict
from dotenv import load_dotenv
from llama_index.core import Document, Settings
from llama_index.core.schema import BaseNode
from llama_index.llms.openai import OpenAI
from llama_index.llms.openai_like import OpenAILike
from llama_index.core.ingestion import IngestionPipeline
from llama_index .core.node_parser import SentenceSplitter
import pandas as pd
from pypdf import PdfReader
from collections import Counter

from .topics import TOPIC_CATEGORIES


from .gpt_oss import get_oss_output
from .extractors import TopicExtractor, GenderExtractor, SpeakerExtractor


def load_pdfs_from_folder(folder_path:str)-> List[Document]:
    """ Load all PDF files from a folder and convert them to Document objects."""

    documents = []

    for filename in os.listdir(folder_path):
        if filename.endswith('.pdf'):
            file_path = os.path.join(folder_path, filename)

            try:
                reader= PdfReader(file_path)
                text = ""
                for page in reader.pages:
                    text += page.extract_text() + "\n"

                # Extract index from filename
                title=filename.replace('.pdf','')
                

                doc = Document(
                    text=text,
                    metadata={
                        "filename": filename,
                        "title": title,
                        "source": file_path,
                        "page_count": len(reader.pages),
                    }
                )
                documents.append(doc)
                print(f"Loaded:{filename} ({len(reader.pages)} pages")

            except Exception as e:
                print(f"Failed to load {filename}: {e}")

    print(f"Successfully loaded {len(documents)} PDF documents")
    return documents


def aggregate_pdf_metadata(nodes: List[BaseNode]) -> Dict[str,Dict]:
    """Aggregate all node memtadata by PDF file."""
    pdf_metadata={}

    for node in nodes:
        filename = node.metadata.get("filename","unknown")

        if filename not in pdf_metadata:
            pdf_metadata[filename]={
                "title": node.metadata.get("title",""),
                "index": node.metadata.get("index",""),
                "page_count": node.metadata.get("page_count",0),
                "topic_categories": [],
                "category_frequency":{},
                "gender_predictions":[],
                "speaker_info": []
            }

            #Agregate topics
            if "topic_categories" in node.metadata:
                pdf_metadata[filename]["topic_categories"].extend(
                    node.metadata["topic_categories"]
                )

            # Aggregate gender
            if "interviewee_gender" in node.metadata:
                pdf_metadata[filename]["gender_predictions"].append(
                    node.metadata["interviewee_gender"]
                )

            
        # Determine gender distribution and topic frequencies
            for filename, metadata in pdf_metadata.items():
                # Most common gender prediction
                if metadata["gender_predictions"]:
                    gender_counts=Counter(metadata["gender_predictions"])
                    metadata["final_gender"] = gender_counts.most_common(1)[0][0]

                # Topic frequency counts
                topic_counts = Counter(metadata["topic_categories"])
                metadata["category_frequency"]=dict(topic_counts)

            return pdf_metadata
        

def save_metadata_to_csv(pdf_metadata: Dict[str, Dict], output_path: str):
    """Save aggregated PDF metadata to CSV file"""
    rows=[]
    for filename, metadata in pdf_metadata.items():
        #Flatten category frequencies into separate columns
        category_freq_cols={}
        for category in TOPIC_CATEGORIES.keys():
            category_freq_cols[f"{category}_frequency"]=metadata["category_frequency"].get(category,0)

        row = {
            "filename": filename,
            "title": metadata["title"],
            "index": metadata["index"],
            "page_count": metadata["page_count"],
            "final_gender": metadata.get("final_gender","unclear"),
            "total_topics_found": len(metadata["topic_categories"]),
            "unique_categories": len(metadata["category_frequency"]),
            **category_freq_cols  # Add frequency columns

        }
        rows.append(row)

    df=pd.DataFrame(rows)
    df.to_csv(output_path,index=False)
    print(f"Metadata saved to: {output_path}")
    return df


async def process_interview_pdfs(pdf_folder: str, output_csv:str):
    """Main function to process all PDFs and extract metadata."""

    #Load encironment and set up
    load_dotenv()

    # Configure LlamaIndex 
    # Choose local or cloud model
    if os.getenv("LOCAL_GPT_OSS"):
        # Point at local OpenAI‑compatible server
        llm = OpenAILike(
            model=os.getenv("GPT_OSS_MODEL", "openai/gpt-oss-120b"),
            api_base=os.getenv("API_BASE", "http://localhost:8000/v1"),
            api_key=os.getenv("API_KEY", "fake"),
            is_chat_model=True,
            context_window=128000,
            temperature=0.1,
        )
    else:
        # Fallback to OpenAI’s hosted model
        llm = OpenAI(model="gpt-3.5-turbo", temperature=0.1)
    
    Settings.llm = llm

    print("Loading PDF documents...")
    documents = load_pdfs_from_folder(pdf_folder)

    if not documents:
        print("No PDF documents found.")

        return
    print("Setting up eextraction pipeline")

    #Create extractors
    topic_extractor = TopicExtractor(llm)
    gender_extractor = GenderExtractor(llm)
    speaker_extractor = SpeakerExtractor(llm)

    #Create pipeline
    pipeline = IngestionPipeline(
        transformations=[
            SentenceSplitter(chunk_size=1000, chunk_overlap=200),
            topic_extractor,
            gender_extractor,
            speaker_extractor
        ]
    )
    print("Processing documents... This may take a while for 1000 PDFs!")
    nodes = await pipeline.arun(documents=documents)
    print("Aggregating metadata...")
    pdf_metadata = aggregate_pdf_metadata(nodes)
    print("Saving metadata to CSV...")
    df=save_metadata_to_csv(pdf_metadata, output_csv)
    print(f"Processing complete! Processed {len(pdf_metadata)} PDF.")
    print(f"Results saved to {output_csv}")
    return pdf_metadata, df
