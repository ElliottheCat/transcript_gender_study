#!/usr/bin/env python3
"""
Test script for gender extraction functionality
"""

import sys
import os
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from gender_extraction import (
    prompt_generation, 
    read_first_n_lines, 
    get_transcript_path,
    extract_gender_from_response
)
import pandas as pd

def test_transcript_reading():
    """Test reading transcript files."""
    print("=== Testing Transcript Reading ===")
    
    # Read metadata to get a sample filename
    csv_path = "/Users/xiyuancao/Desktop/topic-extraction/ushmm-metadata/ushmm-metadata.csv"
    df = pd.read_csv(csv_path)
    
    # Test with first entry
    sample_row = df.iloc[0]
    filename = sample_row['filename']
    interviewee_name = sample_row['interviewee']
    
    print(f"Testing with: {filename}")
    print(f"Interviewee: {interviewee_name}")
    
    # Get transcript path
    transcript_path = get_transcript_path(filename)
    print(f"Transcript path: {transcript_path}")
    
    # Check if file exists
    if os.path.exists(transcript_path):
        print("✓ Transcript file found")
        
        # Read first 20 lines
        content = read_first_n_lines(transcript_path, 20)
        print(f"✓ Read {len(content.split(chr(10)))} lines")
        print(f"Content preview (first 200 chars):")
        print(content[:200])
        
        # Generate prompt
        prompt = prompt_generation(interviewee_name, content)
        print(f"\n✓ Generated prompt (first 300 chars):")
        print(prompt[:300])
        
    else:
        print(f"✗ Transcript file not found: {transcript_path}")
        # Try alternative directory
        alt_path = get_transcript_path(filename, "pdf-to-txt/postcleaned-txt")
        print(f"Trying alternative path: {alt_path}")
        if os.path.exists(alt_path):
            print("✓ Found in postcleaned-txt directory")
        else:
            print("✗ Not found in postcleaned-txt either")

def test_gender_extraction():
    """Test gender extraction from responses."""
    print("\n=== Testing Gender Extraction ===")
    
    test_cases = [
        ("Male", "Male"),
        ("Female", "Female"), 
        ("male", "Male"),
        ("female", "Female"),
        ("The gender is male", "Male"),
        ("The person is female", "Female"),
        ("Gender: Male", "Male"),
        ("Response: Female", "Female"),
        ("male and female", None),  # Ambiguous
        ("neither male nor female", None),  # Ambiguous
        ("unknown", None),
        ("", None)
    ]
    
    for response, expected in test_cases:
        result = extract_gender_from_response(response)
        status = "✓" if result == expected else "✗"
        print(f"{status} '{response}' -> {result} (expected: {expected})")

def test_metadata_loading():
    """Test loading and parsing metadata."""
    print("\n=== Testing Metadata Loading ===")
    
    csv_path = "/Users/xiyuancao/Desktop/topic-extraction/ushmm-metadata/ushmm-metadata.csv"
    
    try:
        df = pd.read_csv(csv_path)
        print(f"✓ Loaded {len(df)} rows from metadata")
        print(f"✓ Columns: {list(df.columns)}")
        
        # Check required columns
        required_cols = ['filename', 'interviewee']
        missing_cols = [col for col in required_cols if col not in df.columns]
        
        if missing_cols:
            print(f"✗ Missing required columns: {missing_cols}")
        else:
            print(f"✓ All required columns present")
            
        # Show sample data
        print(f"\nSample entries:")
        for i in range(min(3, len(df))):
            row = df.iloc[i]
            print(f"  {i+1}. {row['filename']} - {row['interviewee']}")
            
    except Exception as e:
        print(f"✗ Error loading metadata: {e}")

if __name__ == "__main__":
    print("Gender Extraction Test Suite")
    print("=" * 40)
    
    test_metadata_loading()
    test_transcript_reading()
    test_gender_extraction()
    
    print("\n" + "=" * 40)
    print("Test completed!")
    print("\nTo run the full pipeline, use:")
    print("python gender_extraction.py --csv_path ushmm-metadata.csv --server_url http://your-server:port/generate --output_path gender_results.csv")