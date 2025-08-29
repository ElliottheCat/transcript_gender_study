#!/usr/bin/env python3
"""
Filter metadata CSV to include only rows for files that exist in a given folder.
"""

import os
import pandas as pd
import argparse
from pathlib import Path

def filter_metadata(folder_path, metadata_path, output_path):
    """
    Filter metadata CSV to include only files present in the folder.
    
    Args:
        folder_path: Path to folder containing transcript files
        metadata_path: Path to input metadata CSV
        output_path: Path for filtered metadata CSV output
    """
    
    # Get list of files in the folder (only .txt files)
    folder = Path(folder_path)
    if not folder.exists():
        raise ValueError(f"Folder does not exist: {folder_path}")
    
    available_files = set()
    for file_path in folder.glob("*.txt"):
        available_files.add(file_path.name)
    
    print(f"Found {len(available_files)} .txt files in {folder_path}")
    
    # Read metadata CSV
    if not os.path.exists(metadata_path):
        raise ValueError(f"Metadata file does not exist: {metadata_path}")
    
    metadata = pd.read_csv(metadata_path)
    print(f"Original metadata has {len(metadata)} rows")
    
    # Find the filename column (try common variations)
    filename_col = None
    for col in ['filename', 'file_name', 'doc_id', 'document_id']:
        if col in metadata.columns:
            filename_col = col
            break
    
    if filename_col is None:
        print("Available columns:", list(metadata.columns))
        raise ValueError("Could not find filename column in metadata. Expected one of: filename, file_name, doc_id, document_id")
    
    print(f"Using '{filename_col}' as filename column")
    
    # Filter metadata to only include files that exist
    filtered_metadata = metadata[metadata[filename_col].isin(available_files)]
    
    print(f"Filtered metadata has {len(filtered_metadata)} rows")
    print(f"Removed {len(metadata) - len(filtered_metadata)} rows with missing files")
    
    # Save filtered metadata
    filtered_metadata.to_csv(output_path, index=False)
    print(f"Filtered metadata saved to: {output_path}")
    
    # Show which files are matched
    matched_files = set(filtered_metadata[filename_col])
    unmatched_files = available_files - matched_files
    
    if unmatched_files:
        print(f"\nWarning: {len(unmatched_files)} files in folder have no metadata:")
        for file in sorted(unmatched_files):
            print(f"  - {file}")
    
    print(f"\nMatched {len(matched_files)} files with metadata")
    
    return output_path

def main():
    parser = argparse.ArgumentParser(description="Filter metadata CSV for files in a folder")
    parser.add_argument("folder", help="Path to folder containing transcript files")
    parser.add_argument("metadata", help="Path to input metadata CSV file")
    parser.add_argument("-o", "--output", help="Path for output CSV (default: filtered_metadata.csv)", 
                       default="data/metadata/filtered_metadata.csv")
    
    args = parser.parse_args()
    
    try:
        # Create output directory if it doesn't exist
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        
        filter_metadata(args.folder, args.metadata, args.output)
        
    except Exception as e:
        print(f"Error: {e}")
        return 1
    
    return 0

if __name__ == "__main__":
    exit(main())