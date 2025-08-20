#!/usr/bin/env python3
import os
import sys
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from gender_extraction import get_transcript_path, read_first_n_lines

# Test the path function
test_filename = "RG-50.999.0621_trs_en.txt"
path = get_transcript_path(test_filename)
print(f"Generated path: {path}")
print(f"File exists: {os.path.exists(path)}")

if os.path.exists(path):
    content = read_first_n_lines(path, 5)
    print(f"First 5 lines preview:")
    print(content[:200])
else:
    print("File not found!")
    # Let's check what's in the directory
    script_dir = os.path.dirname(os.path.abspath(__file__))
    transcript_dir = os.path.join(script_dir, "postcleaned-txt")
    print(f"Checking directory: {transcript_dir}")
    if os.path.exists(transcript_dir):
        files = os.listdir(transcript_dir)
        print(f"Found {len(files)} files")
        if test_filename in files:
            print(f"✓ {test_filename} is in the directory")
        else:
            print(f"✗ {test_filename} not in directory")
            # Show similar files
            similar = [f for f in files if "RG-50.999" in f][:5]
            print(f"Similar files: {similar}")
    else:
        print(f"Directory doesn't exist: {transcript_dir}")