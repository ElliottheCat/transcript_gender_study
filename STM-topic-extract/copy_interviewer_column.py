#!/usr/bin/env python3
"""
Simply copy the interviewer column from USHMM metadata to test100 metadata
"""

import pandas as pd

def copy_interviewer_column():
    # File paths
    ushmm_path = "/Users/xiyuancao/Desktop/topic-extraction/ushmm-metadata/ushmm-metadata.csv"
    test_path = "/Users/xiyuancao/Desktop/topic-extraction/STM-topic-extract/data/metadata/2doc_meta.csv"
    
    # Read both files
    ushmm_df = pd.read_csv(ushmm_path)
    test_df = pd.read_csv(test_path)
    
    print(f"USHMM metadata: {len(ushmm_df)} rows")
    print(f"Test metadata: {len(test_df)} rows")
    
    # Find merge column (filename or rg_number)
    merge_col = None
    for col in ['filename', 'rg_number']:
        if col in test_df.columns and col in ushmm_df.columns:
            merge_col = col
            print(f"Found common column: {merge_col}")
            break
    
    if merge_col is None:
        print("Available columns in test:", list(test_df.columns))
        print("Available columns in USHMM:", list(ushmm_df.columns))
        raise ValueError("No common column found for merging")
    
    # If test_df already has 'interviewer' column, rename it to avoid conflict
    if 'interviewer' in test_df.columns:
        test_df = test_df.rename(columns={'interviewer': 'interview_content'})
        print("Renamed existing 'interviewer' column to 'interview_content'")
    
    # Merge to get interviewer column
    merged_df = test_df.merge(
        ushmm_df[[merge_col, 'interviewer']], 
        on=merge_col, 
        how='left'
    )
    
    # Fill missing values with 'NULL'
    merged_df['interviewer'] = merged_df['interviewer'].fillna('NULL')
    
    print(f"\nMerge results:")
    print(f"  Total rows: {len(merged_df)}")
    print(f"  Rows with interviewer data: {(merged_df['interviewer'] != 'NULL').sum()}")
    print(f"  Rows with NULL interviewer: {(merged_df['interviewer'] == 'NULL').sum()}")
    
    # Show sample of interviewer values
    print(f"\nSample interviewer values:")
    sample_interviewers = merged_df['interviewer'].value_counts().head(10)
    for interviewer, count in sample_interviewers.items():
        display_text = interviewer[:50] + "..." if len(str(interviewer)) > 50 else interviewer
        print(f"  {display_text}: {count}")
    
    # Save result
    merged_df.to_csv(test_path, index=False)
    print(f"\n✓ Updated test100_meta.csv with interviewer column")
    
    return test_path

if __name__ == "__main__":
    copy_interviewer_column()