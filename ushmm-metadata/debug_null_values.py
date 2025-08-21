#!/usr/bin/env python3
"""
Debug script to check null/empty values in metadata CSV
"""

import pandas as pd
import numpy as np

def debug_null_values(csv_path: str):
    """Debug null/empty values in the CSV."""
    df = pd.read_csv(csv_path)
    
    print(f"Total rows: {len(df)}")
    print(f"Columns: {list(df.columns)}")
    
    # Check different types of "empty" values
    columns_to_check = ['subject_topical', 'subject_geography', 'subject_person', 'subject_corporate']
    
    for col in columns_to_check:
        if col in df.columns:
            print(f"\n=== {col.upper()} ===")
            
            # Different ways to check for "empty"
            is_null = df[col].isnull()
            is_na = df[col].isna() 
            is_empty_string = df[col] == ''
            is_whitespace = df[col].str.strip() == '' if df[col].dtype == 'object' else pd.Series([False] * len(df))
            
            print(f"pd.isnull(): {is_null.sum()}")
            print(f"pd.isna(): {is_na.sum()}")
            print(f"Empty string '': {is_empty_string.sum()}")
            print(f"Whitespace only: {is_whitespace.sum()}")
            
            # Combined "truly empty"
            truly_empty = is_null | is_na | is_empty_string | is_whitespace
            print(f"Total truly empty: {truly_empty.sum()}")
            print(f"Non-empty: {len(df) - truly_empty.sum()}")
            
            # Show some example values
            print("Example non-null values:")
            non_null_examples = df[col].dropna().head(3)
            for i, val in enumerate(non_null_examples):
                semicolon_count = str(val).count(';') if pd.notna(val) else 0
                print(f"  {i+1}: '{val}' (semicolons: {semicolon_count}, topics: {semicolon_count + 1 if pd.notna(val) and str(val).strip() else 0})")
            
            # Show some example "empty" values
            if truly_empty.any():
                print("Example 'empty' values:")
                empty_examples = df[truly_empty][col].head(3)
                for i, val in enumerate(empty_examples):
                    print(f"  {i+1}: '{val}' (type: {type(val)})")

if __name__ == "__main__":
    csv_path = "/Users/xiyuancao/Desktop/topic-extraction/ushmm-metadata/ushmm-metadata.csv"
    debug_null_values(csv_path)