##### stm.R
**What it is**  
End-to-end STM analysis pipeline for the test100 subset, with chunking, normalization, topic modeling, effects, plots, and CSV exports.

**Key knobs**  
- K = 5, SEED = 42
- Chunk size: CHUNK_TOKS = 700, USE_CHUNKS = TRUE
- Paths: data at STM-topic-extract/data/test100, metadata at .../metadata/test100_meta.csv
- Trial outputs auto-indexed: STM-topic-extract/outputs/stm_trial<N>/

**Load & join**  
Read metadata, standardize gender to {Female, Male}, fill empty interviewer as "NULL".  
Read all *.txt transcripts, merge with metadata; drop empty texts.

**Chunking**  
Tokenize each transcript (punct removed) and split into ~700-token chunks.  
Keep provenance: parent_id (original file), doc_id (file#chunk).

**Text cleaning & normalization**  
- Strip speaker labels ("Name:", line starts with capitalized tokens + colon)
- Trim/collapse whitespace
- Unicode normalization: Convert curly quotes/dashes → ASCII; remove apostrophes (e.g., don't → dont)
- Remove stray leading/trailing hyphens; keep letters/spaces/internal hyphens
- Custom stopwords tuned for oral histories (fillers, transcript boilerplate, contraction forms after apostrophe removal)
- textProcessor() + prepDocuments() with lower.thresh = 3 (or 5 if larger corpus)
- Build docs_out, vocab_out, meta_out; factorize gender, interviewer; drop rows with missing gender

**Model**  
Fit STM with K=5, init.type="Spectral", max.em.its=100.  
Covariates: prevalence ~ gender + interviewer (no content covariate → classic labels available).

**Topic labels**  
labelTopics(fit, n = 15) → collect prob/frex/lift/score per topic (matrix-aware).  
Save tidy topic_labels.csv.

**Document–topic outputs**  
Build long theta_doc (mean γ per doc/topic, aggregated from chunks) and wide theta_wide.  
Save:
- document_topics_long.csv
- document_topics_wide.csv

**Effects (covariates)**  
estimateEffect(1:K ~ gender + interviewer, ...).  
Export:
- gender_effects.csv (Female − Male effect per topic)
- interviewer_effects.csv (each interviewer vs baseline)

**Visualizations** (saved in plots/)
- topics_by_gender.png — bar chart of average γ by topic × gender
- topics_by_interviewer.png — bar chart of average γ by topic × interviewer
- interviewer_gender_stacked.png — stacked counts by interviewer × gender, colored by dominant topic (selected via max γ per group)

**Summary tables**
- document_summary_stats.csv: per (gender, interviewer) — count, Simpson-style diversity, max γ
- topic_gender_comparison.csv: per topic — Female vs Male avg prevalence + FREX words; sorted by absolute gender difference

**Files you'll see under the new trial folder**
- /csv/: document_topics_*, topic_labels.csv, gender_effects.csv, interviewer_effects.csv, summaries
- /plots/: three PNGs listed above
- stm_model_K05.rds: the fitted model

**Small gotcha to remember**  
In the stacked chart, "dominant topic" is chosen via single highest γ document within each (interviewer, gender) group.  
If you prefer the topic with the highest average γ across that group (often more stable), switch to computing mean γ per topic then take which.max(avg_gamma).