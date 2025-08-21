#!/usr/bin/env python3
"""
Script to calculate average topic count from USHMM metadata topical terms
"""

import pandas as pd
import argparse
import numpy as np
from typing import List, Dict


def count_topics_in_field(field_value: str) -> int:
    """Count topics in a field by counting semicolons + 1."""
    if pd.isna(field_value) or field_value == '' or field_value.strip() == '':
        return 0
    
    # Count semicolons and add 1 (since semicolons separate terms)
    semicolon_count = str(field_value).count(';')
    return semicolon_count + 1


def analyze_topic_counts(csv_path: str) -> Dict:
    """Analyze topic counts from the metadata CSV."""
    print("Loading metadata CSV...")
    df = pd.read_csv(csv_path)
    
    print(f"Total transcripts: {len(df)}")
    
    # Find topical columns (should be subject_topical)
    topical_columns = [col for col in df.columns if 'topical' in col.lower() or 'subject' in col.lower()]
    print(f"Found topical columns: {topical_columns}")
    
    results = {}
    
    for col in topical_columns:
        if col in df.columns:
            print(f"\nAnalyzing column: {col}")
            
            # Count topics for each row
            topic_counts = df[col].apply(count_topics_in_field)
            
            # Calculate statistics
            total_topics = topic_counts.sum()
            non_zero_counts = topic_counts[topic_counts > 0]
            
            # Average only among documents with non-zero subjects for this category
            average_for_nonzero_docs = total_topics / len(non_zero_counts) if len(non_zero_counts) > 0 else 0
            
            results[col] = {
                'total_transcripts': len(df),
                'transcripts_with_topics': len(non_zero_counts),
                'transcripts_without_topics': len(df) - len(non_zero_counts),
                'total_topics': int(total_topics),
                'average_topics_nonzero_only': average_for_nonzero_docs,
                'min_topics': int(topic_counts.min()),
                'max_topics': int(topic_counts.max()),
                'median_topics_nonzero': non_zero_counts.median() if len(non_zero_counts) > 0 else 0
            }
            
            print(f"  Total topics: {total_topics}")
            print(f"  Transcripts with topics: {len(non_zero_counts)}/{len(df)} ({len(non_zero_counts)/len(df)*100:.1f}%)")
            print(f"  Average topics (non-zero documents only): {average_for_nonzero_docs:.2f}")
            print(f"  Range: {int(topic_counts.min())} - {int(topic_counts.max())} topics")
            print(f"  Median (non-zero only): {non_zero_counts.median() if len(non_zero_counts) > 0 else 0:.1f} topics")
    
    return results


def show_examples(csv_path: str, num_examples: int = 5):
    """Show examples of topical terms."""
    df = pd.read_csv(csv_path)
    
    topical_columns = [col for col in df.columns if 'topical' in col.lower() or 'subject' in col.lower()]
    
    print(f"\n=== Examples of Topical Terms ===")
    
    for col in topical_columns:
        if col in df.columns:
            print(f"\nColumn: {col}")
            
            # Get examples with different topic counts
            df_with_counts = df.copy()
            df_with_counts['topic_count'] = df_with_counts[col].apply(count_topics_in_field)
            
            # Show examples from different ranges
            examples = []
            
            # High topic count examples
            high_count = df_with_counts.nlargest(2, 'topic_count')
            examples.extend(high_count.iterrows())
            
            # Medium topic count examples  
            medium_mask = (df_with_counts['topic_count'] >= 3) & (df_with_counts['topic_count'] <= 6)
            if medium_mask.any():
                medium_examples = df_with_counts[medium_mask].head(2)
                examples.extend(medium_examples.iterrows())
            
            # Low topic count examples
            low_mask = (df_with_counts['topic_count'] >= 1) & (df_with_counts['topic_count'] <= 2)
            if low_mask.any():
                low_examples = df_with_counts[low_mask].head(1)
                examples.extend(low_examples.iterrows())
            
            for idx, (_, row) in enumerate(examples[:num_examples]):
                topic_count = count_topics_in_field(row[col])
                filename = row.get('filename', 'Unknown')
                interviewee = row.get('interviewee', 'Unknown')
                
                print(f"  Example {idx+1}: {filename} - {interviewee}")
                print(f"    Topics ({topic_count}): {row[col]}")
                print()


def save_detailed_analysis(csv_path: str, output_path: str):
    """Save detailed topic analysis to CSV."""
    df = pd.read_csv(csv_path)
    
    topical_columns = [col for col in df.columns if 'topical' in col.lower() or 'subject' in col.lower()]
    
    # Add topic count columns
    for col in topical_columns:
        if col in df.columns:
            df[f'{col}_topic_count'] = df[col].apply(count_topics_in_field)
    
    # Add total topic count across all topical columns
    topic_count_cols = [f'{col}_topic_count' for col in topical_columns if col in df.columns]
    if topic_count_cols:
        df['total_topic_count'] = df[topic_count_cols].sum(axis=1)
    
    # Save to CSV
    df.to_csv(output_path, index=False)
    print(f"\nDetailed analysis saved to: {output_path}")


def main():
    parser = argparse.ArgumentParser(description='Analyze topic counts in USHMM metadata')
    parser.add_argument('--csv_path', required=True, help='Path to metadata CSV file')
    parser.add_argument('--output_path', help='Path to save detailed analysis CSV')
    parser.add_argument('--show_examples', action='store_true', help='Show example entries')
    parser.add_argument('--num_examples', type=int, default=5, help='Number of examples to show')
    
    args = parser.parse_args()
    
    # Perform main analysis
    results = analyze_topic_counts(args.csv_path)
    
    # Show examples if requested
    if args.show_examples:
        show_examples(args.csv_path, args.num_examples)
    
    # Save detailed analysis if requested
    if args.output_path:
        save_detailed_analysis(args.csv_path, args.output_path)
    
    # Print summary
    print("\n" + "="*50)
    print("SUMMARY")
    print("="*50)
    
    for col, stats in results.items():
        print(f"\n{col.upper()}:")
        print(f"Total transcripts: {stats['total_transcripts']:,}")
        print(f"Transcripts with topics: {stats['transcripts_with_topics']:,} ({stats['transcripts_with_topics']/stats['total_transcripts']*100:.1f}%)")
        print(f"Total topics: {stats['total_topics']:,}")
        print(f"Average topics (non-zero docs only): {stats['average_topics_nonzero_only']:.2f}")
        print(f"Range: {stats['min_topics']} - {stats['max_topics']} topics")
        print(f"Median (non-zero only): {stats['median_topics_nonzero']:.1f} topics")


if __name__ == "__main__":
    main()