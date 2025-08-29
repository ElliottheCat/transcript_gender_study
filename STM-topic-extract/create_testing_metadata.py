#!/usr/bin/env python3
"""
Quick script to filter metadata for a specified folder
"""

import os
import sys
import argparse
from pathlib import Path
from filter_metadata import filter_metadata

def main():
    parser = argparse.ArgumentParser(description="Filter metadata for files in a specific folder")
    parser.add_argument("folder_name", help="Name of the folder (e.g., 'testing', 'validation')")
    parser.add_argument("--metadata", default="data/metadata/metadata_with_gender.csv", 
                       help="Path to original metadata CSV (default: data/metadata/metadata_with_gender.csv)")
    
    args = parser.parse_args()
    
    # Set up paths
    folder_name = args.folder_name
    folder_path = f"data/{folder_name}"
    original_metadata = args.metadata
    output_metadata = f"data/metadata/{folder_name}_meta.csv"
    
    print(f"Filtering metadata for {folder_name} folder...")
    print(f"Input folder: {folder_path}")
    print(f"Original metadata: {original_metadata}")
    print(f"Output metadata: {output_metadata}")
    
    try:
        filter_metadata(folder_path, original_metadata, output_metadata)
        print(f"\n✓ Success! Created: {output_metadata}")
        print("\nTo use this filtered metadata in your R script, update this line:")
        print(f'META_PATH <- file.path(ROOT, "{output_metadata}")')
        
    except Exception as e:
        print(f"Error: {e}")
        
        # Show what files exist to help debug
        if os.path.exists(folder_path):
            files = [f for f in os.listdir(folder_path) if f.endswith('.txt')]
            print(f"\nFiles in {folder_path}: {len(files)} .txt files")
            if len(files) <= 10:
                for f in files:
                    print(f"  - {f}")
            else:
                print(f"  - {files[0]} ... (and {len(files)-1} more)")
        else:
            print(f"\nFolder does not exist: {folder_path}")
        
        if os.path.exists(original_metadata):
            import pandas as pd
            df = pd.read_csv(original_metadata)
            print(f"\nOriginal metadata: {len(df)} rows")
            print(f"Columns: {list(df.columns)}")
        else:
            print(f"\nMetadata file does not exist: {original_metadata}")

if __name__ == "__main__":
    main()