#!/usr/bin/env python3
"""
Randomly select 100 documents from transcripts folder and copy to test100 folder
"""

import os
import random
import shutil
from pathlib import Path
import argparse

def create_test100_sample(source_folder, output_folder="data/test100", n_samples=100, seed=42):
    """
    Randomly sample n documents from source folder and copy to output folder.
    
    Args:
        source_folder: Path to folder containing transcript files
        output_folder: Path for output folder (will be created)
        n_samples: Number of documents to sample (default: 100)
        seed: Random seed for reproducibility
    """
    
    # Set random seed for reproducibility
    random.seed(seed)
    
    # Get source folder path
    source_path = Path(source_folder)
    if not source_path.exists():
        raise ValueError(f"Source folder does not exist: {source_folder}")
    
    # Get all .txt files from source folder
    txt_files = list(source_path.glob("*.txt"))
    
    if len(txt_files) == 0:
        raise ValueError(f"No .txt files found in {source_folder}")
    
    print(f"Found {len(txt_files)} .txt files in {source_folder}")
    
    # Check if we have enough files
    if len(txt_files) < n_samples:
        print(f"Warning: Only {len(txt_files)} files available, using all of them")
        n_samples = len(txt_files)
    
    # Randomly sample files
    selected_files = random.sample(txt_files, n_samples)
    print(f"Randomly selected {len(selected_files)} files")
    
    # Create output folder
    output_path = Path(output_folder)
    output_path.mkdir(parents=True, exist_ok=True)
    print(f"Created output folder: {output_folder}")
    
    # Copy selected files
    copied_count = 0
    for file_path in selected_files:
        try:
            destination = output_path / file_path.name
            shutil.copy2(file_path, destination)
            copied_count += 1
        except Exception as e:
            print(f"Error copying {file_path.name}: {e}")
    
    print(f"Successfully copied {copied_count} files to {output_folder}")
    
    # Show first few selected files
    print("\nFirst 10 selected files:")
    for i, file_path in enumerate(selected_files[:10]):
        print(f"  {i+1}. {file_path.name}")
    
    if len(selected_files) > 10:
        print(f"  ... and {len(selected_files) - 10} more")
    
    return output_folder

def main():
    parser = argparse.ArgumentParser(description="Randomly sample documents from transcripts folder")
    parser.add_argument("--source", default="data/transcripts",
                       help="Source folder with transcript files (default: data/testing)")
    parser.add_argument("--output", default="data/test100", 
                       help="Output folder for sampled files (default: data/test100)")
    parser.add_argument("--n", type=int, default=100, 
                       help="Number of files to sample (default: 100)")
    parser.add_argument("--seed", type=int, default=42, 
                       help="Random seed for reproducibility (default: 42)")
    
    args = parser.parse_args()
    
    try:
        create_test100_sample(
            source_folder=args.source,
            output_folder=args.output, 
            n_samples=args.n,
            seed=args.seed
        )
        
        print(f"\n✓ Success! {args.n} files randomly sampled to {args.output}")
        print(f"\nNext steps:")
        print(f"1. Create metadata: python3 create_testing_metadata.py test100")
        print(f"2. Update searchK.r to use test100 data")
        
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    main()