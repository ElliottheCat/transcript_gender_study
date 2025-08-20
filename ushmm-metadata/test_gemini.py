#!/usr/bin/env python3
"""
Test script for Gemini gender extraction
"""

import sys
import os
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

import google.generativeai as genai
from gender_extraction import (
    prompt_generation, 
    send_gemini_request,
    extract_gender_from_response,
    query_gender_multiple_times
)

def test_gemini_connection(api_key: str):
    """Test basic Gemini API connection."""
    print("=== Testing Gemini Connection ===")
    
    try:
        genai.configure(api_key=api_key)
        
        # Simple test
        response = send_gemini_request("What is 2+2?")
        if response:
            print(f"✓ Gemini API working. Response: {response}")
            return True
        else:
            print("✗ No response from Gemini")
            return False
    except Exception as e:
        print(f"✗ Gemini API error: {e}")
        return False

def test_gender_extraction_logic():
    """Test the improved gender extraction logic."""
    print("\n=== Testing Gender Extraction Logic ===")
    
    test_cases = [
        ("Male", "Male"),
        ("Female", "Female"), 
        ("male", "Male"),
        ("female", "Female"),
        ("The gender is male", "Male"),
        ("The person is female", "Female"),
        ("Gender: Male", "Male"),
        ("Response: Female", "Female"),
        ("male and female", None),  # Both present
        ("neither male nor female", None),  # Both present
        ("female male", None),  # Both present
        ("femaleness", "Female"),  # Only female
        ("unmale", None),  # Only male but in context that might be confusing
        ("unknown", None),
        ("", None)
    ]
    
    for response, expected in test_cases:
        result = extract_gender_from_response(response)
        status = "✓" if result == expected else "✗"
        print(f"{status} '{response}' -> {result} (expected: {expected})")

def test_full_pipeline(api_key: str):
    """Test the full pipeline with a sample."""
    print("\n=== Testing Full Pipeline ===")
    
    genai.configure(api_key=api_key)
    
    # Sample data
    sample_name = "David A. Kochalski"
    sample_transcript = """United States Holocaust Memorial Museum

Interview with David A. Kochalski
July 28, 1994
RG-50.030*0001

The following oral history testimony is the result of a videotaped interview with David A. Kochalski, conducted by Randy M. Goldman on July 28, 1994. David discusses his childhood in Poland and experiences during the Holocaust."""
    
    print(f"Testing with: {sample_name}")
    print(f"Sample transcript length: {len(sample_transcript)} characters")
    
    # Test 3 queries
    result, confidence = query_gender_multiple_times(sample_name, sample_transcript, 3)
    
    print(f"Final result: {result}")
    print(f"Confidence: {confidence}/3")
    
    if confidence >= 2:
        print("✓ High confidence result (≥2/3)")
    else:
        print("⚠ Low confidence result")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python test_gemini.py <GEMINI_API_KEY>")
        print("Get your API key from: https://makersuite.google.com/app/apikey")
        sys.exit(1)
    
    api_key = sys.argv[1]
    
    print("Gemini Gender Extraction Test Suite")
    print("=" * 40)
    
    # Test connection first
    if test_gemini_connection(api_key):
        test_gender_extraction_logic()
        test_full_pipeline(api_key)
    else:
        print("Cannot proceed with tests - Gemini API connection failed")
    
    print("\n" + "=" * 40)
    print("Test completed!")
    print("\nTo run the full pipeline:")
    print("python gender_extraction.py --csv_path ushmm-metadata.csv --api_key YOUR_API_KEY --output_path results.csv")