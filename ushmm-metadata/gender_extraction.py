import pandas as pd
import argparse
import time
import os
from typing import List, Optional
from collections import Counter
import google.generativeai as genai


def prompt_generation(interviewee_name: str, interview_snippet: str) -> str:
    """Generate a prompt for gender extraction from interview snippets."""
    prompt = f"""This is an interview transcript. Based on the content below, determine the gender of the interviewee: {interviewee_name}.

Transcript excerpt:
{interview_snippet}

Look for pronouns, self-identification, or contextual clues. Respond with ONLY one word:
- Male
- Female

Interviewee: {interviewee_name}
Gender:"""
    return prompt


def read_first_n_lines(file_path: str, n: int = 20) -> str:
    """Read first n lines from a text file."""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            lines = []
            for i, line in enumerate(f):
                if i >= n:
                    break
                lines.append(line.rstrip())
            return '\n'.join(lines)
    except FileNotFoundError:
        print(f"Warning: Transcript file not found: {file_path}")
        return ""
    except Exception as e:
        print(f"Error reading file {file_path}: {e}")
        return ""


def get_transcript_path(filename: str, transcript_dir: str = "postcleaned-txt") -> str:
    """Get the full path to transcript file."""
    # Get the directory where this script is located (ushmm-metadata)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(script_dir, transcript_dir, filename)


def send_gemini_request(prompt: str, model_name: str = "gemini-2.5-flash-lite") -> Optional[str]:
    """Send request to Google Gemini API."""
    try:
        model = genai.GenerativeModel(model_name)
        
        generation_config = genai.types.GenerationConfig(
            max_output_tokens=20,
            temperature=0.1
        )
        
        response = model.generate_content(
            prompt,
            generation_config=generation_config
        )
        
        return response.text.strip() if response.text else None
        
    except Exception as e:
        print(f"Gemini API error: {e}")
        return None


def extract_gender_from_response(response: str) -> Optional[str]:
    """Extract gender from Gemini response - check for UNIQUE occurrence."""
    if not response:
        return None
        
    response = response.strip().lower()
    
    # Count occurrences of male and female
    male_count = response.count('male')
    female_count = response.count('female')
    
    # Adjust for 'female' containing 'male'
    # If 'female' is found, subtract those from male count
    actual_male_count = male_count - female_count
    
    # Check for unique occurrence
    if actual_male_count > 0 and female_count == 0:
        return 'Male'
    elif female_count > 0 and actual_male_count == 0:
        return 'Female'
    else:
        return None


def query_gender_multiple_times(interviewee_name: str, interview_snippet: str, 
                               num_queries: int = 3) -> tuple[Optional[str], int]:
    """Query Gemini multiple times and return majority vote with confidence count."""
    results = []
    
    for i in range(num_queries):
        prompt = prompt_generation(interviewee_name, interview_snippet)
        response = send_gemini_request(prompt)
        gender = extract_gender_from_response(response)
        
        if gender:
            results.append(gender)
            print(f"Query {i+1}: {gender} (Response: '{response}')")
        else:
            print(f"Query {i+1}: No valid response (Response: '{response}')")
        
        # Small delay between requests to respect rate limits
        time.sleep(1.0)
    
    if not results:
        return None, 0
    
    # Return majority vote and confidence count
    counter = Counter(results)
    most_common = counter.most_common(1)[0]
    return most_common[0], most_common[1]


def process_metadata_file(csv_path: str, output_path: str = None,
                         transcript_dir: str = "postcleaned-txt", num_queries: int = 3) -> pd.DataFrame:
    """Process the metadata CSV file and extract gender for each interviewee."""
    # Read metadata
    df = pd.read_csv(csv_path)
    
    # Check for existing results to resume from
    existing_results = []
    processed_files = set()
    
    if output_path and os.path.exists(output_path):
        try:
            existing_df = pd.read_csv(output_path)
            existing_results = existing_df.to_dict('records')
            # Only consider files "processed" if they have a gender prediction (not None/NaN)
            actually_processed = existing_df[existing_df['predicted_gender'].notna()]
            processed_files = set(actually_processed['filename'].tolist())
            print(f"Found existing results file with {len(existing_results)} total rows")
            print(f"Actually processed (with gender predictions): {len(processed_files)} interviews")
            print(f"Resuming from where we left off...")
        except Exception as e:
            print(f"Could not load existing results: {e}")
            existing_results = []
            processed_files = set()
    
    results = existing_results.copy()
    total_rows = len(df)
    remaining_rows = len(df[~df['filename'].isin(processed_files)])
    
    print(f"Total interviews: {total_rows}")
    print(f"Already processed: {len(processed_files)}")
    print(f"Remaining to process: {remaining_rows}")
    
    for idx, row in df.iterrows():
        filename = row['filename']
        interviewee_name = row['interviewee']
        
        # Skip if already processed
        if filename in processed_files:
            print(f"Skipping {idx+1}/{total_rows}: {filename} (already processed)")
            continue
            
        print(f"\nProcessing {idx+1}/{total_rows}: {filename}")
        
        # Get transcript path
        transcript_path = get_transcript_path(filename, transcript_dir)
        
        # Read first 20 lines of transcript
        interview_snippet = read_first_n_lines(transcript_path, 20)
        
        if not interview_snippet.strip():
            print(f"Warning: No content found for {filename}")
            results.append({
                'filename': filename,
                'interviewee': interviewee_name,
                'predicted_gender': None,
                'confidence_count': 0,
                'confidence_ratio': 0.0
            })
            continue
        
        # Query Gemini multiple times for gender
        print(f"Querying gender for: {interviewee_name}")
        predicted_gender, confidence_count = query_gender_multiple_times(
            interviewee_name, interview_snippet, num_queries
        )
        
        confidence_ratio = confidence_count / num_queries if num_queries > 0 else 0.0
        
        results.append({
            'filename': filename,
            'interviewee': interviewee_name,
            'predicted_gender': predicted_gender,
            'confidence_count': confidence_count,
            'confidence_ratio': confidence_ratio,
            'rg_number': row.get('rg_number', ''),
            'interview_date': row.get('interview_date', '')
        })
        
        print(f"Result: {predicted_gender} (confidence: {confidence_count}/{num_queries})")
        
        # Save checkpoint every 50 interviews
        if len(results) % 50 == 0 and len(results) > len(existing_results):
            checkpoint_df = pd.DataFrame(results)
            if output_path:
                checkpoint_df.to_csv(output_path, index=False)
                print(f"🔄 CHECKPOINT: Saved progress at {len(results)} interviews to {output_path}")
            else:
                checkpoint_df.to_csv(f"checkpoint_{len(results)}.csv", index=False)
                print(f"🔄 CHECKPOINT: Saved progress at {len(results)} interviews")
    
    # Create final results DataFrame
    results_df = pd.DataFrame(results)
    
    # Save final results
    if output_path:
        results_df.to_csv(output_path, index=False)
        print(f"\n✅ FINAL RESULTS saved to: {output_path}")
    
    return results_df


def main():
    parser = argparse.ArgumentParser(description='Extract gender from USHMM interview metadata using Google Gemini')
    parser.add_argument('--csv_path', required=True, help='Path to metadata CSV file')
    parser.add_argument('--api_key', required=True, help='Google Gemini API key')
    parser.add_argument('--output_path', help='Path to save results CSV')
    parser.add_argument('--transcript_dir', default='postcleaned-txt', 
                       help='Directory containing transcript files')
    parser.add_argument('--num_queries', type=int, default=3, 
                       help='Number of times to query each name (default: 3)')
    
    args = parser.parse_args()
    
    # Configure Gemini API
    genai.configure(api_key=args.api_key)
    print(f"Configured Gemini API with provided key")
    
    # Process the metadata file
    results_df = process_metadata_file(
        csv_path=args.csv_path,
        output_path=args.output_path,
        transcript_dir=args.transcript_dir,
        num_queries=args.num_queries
    )
    
    # Print summary statistics
    total = len(results_df)
    male_count = len(results_df[results_df['predicted_gender'] == 'Male'])
    female_count = len(results_df[results_df['predicted_gender'] == 'Female'])
    unknown_count = len(results_df[results_df['predicted_gender'].isna()])
    
    # Confidence statistics
    high_confidence = len(results_df[results_df['confidence_ratio'] >= 0.67])  # 2/3 or better
    
    print(f"\n=== Summary ===")
    print(f"Total interviews: {total}")
    print(f"Male: {male_count} ({male_count/total*100:.1f}%)")
    print(f"Female: {female_count} ({female_count/total*100:.1f}%)")
    print(f"Unknown: {unknown_count} ({unknown_count/total*100:.1f}%)")
    print(f"High confidence (≥2/3): {high_confidence} ({high_confidence/total*100:.1f}%)")


if __name__ == "__main__":
    main()