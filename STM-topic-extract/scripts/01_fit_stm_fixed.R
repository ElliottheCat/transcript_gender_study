# ---- Libraries ----
pkgs <- c("stm","quanteda","readtext","data.table","lubridate","ggplot2","tm","SnowballC","igraph")
new  <- pkgs[!pkgs %in% installed.packages()[, "Package"]]
if (length(new)) install.packages(new, repos = "https://cloud.r-project.org")
invisible(lapply(pkgs, library, character.only = TRUE))

set.seed(20250821)  # make results reproducible

# ---- Config ----
ROOT      <- getwd()
DATA_DIR  <- file.path(ROOT, "data", "testing")
META_PATH <- file.path(ROOT, "data", "metadata", "metadata_with_gender.csv")
if (!file.exists(META_PATH)) stop(sprintf("Missing metadata CSV at: %s", META_PATH))
if (!dir.exists(DATA_DIR)) stop(sprintf("Missing transcripts dir at: %s", DATA_DIR))

K          <- 10           # topics count (reduced for testing with small dataset)
CHUNK_TOKS <- 700          # chunk the document into smaller texts ≈ 400–800 works well
USE_CHUNKS <- TRUE         # set FALSE to turn off segmentation. We use this to avoid overfitting topics and take into account the local context on long documents.


# ---- Read metadata ----
cat("Reading metadata...\n")
meta_full <- fread(META_PATH)
cat(sprintf("Loaded %d total metadata records\n", nrow(meta_full)))

# Get list of files actually present in the data directory
available_files <- list.files(DATA_DIR, pattern = "\\.txt$", full.names = FALSE)
cat(sprintf("Found %d transcript files in %s\n", length(available_files), DATA_DIR))

# Filter metadata to only include files that exist
meta <- meta_full[filename %in% available_files]
cat(sprintf("Filtered to %d metadata records matching available files\n", nrow(meta)))

if (nrow(meta) == 0) {
  stop("No metadata records match the available transcript files!")
}

# Show which files we're working with
cat("Working with files:\n")
print(meta$filename)

# Normalize expected columns
setnames(meta, old = grep("^gender$", names(meta), ignore.case=TRUE, value=TRUE, invert=TRUE), new = names(meta))  # keep as-is, just for safety

# Standardize gender values
meta[, gender := fifelse(tolower(predicted_gender) %in% c("female","f","woman","women"), "Female", fifelse(tolower(predicted_gender) %in% c("male","m","man","men"), "Male", NA_character_))]
# Year for smooth effect
meta[, year := suppressWarnings(year(parse_date_time(interview_date, orders = c("Y b d","Y B d","Y","b d Y","B d Y"))))]
# Fall back if parse failed
meta[is.na(year), year := NA_integer_]

# ---- Read transcripts ----
cat("Reading transcript files...\n")
# readtext builds a data.frame with doc_id + text automatically
rt <- readtext::readtext(file.path(DATA_DIR, "*.txt"), encoding = "UTF-8")
setDT(rt)
setnames(rt, c("doc_id","text"))  # doc_id is the filename
cat(sprintf("Loaded %d transcript files\n", nrow(rt)))

# Join metadata on filename
cat("Merging transcripts with metadata...\n")
docs <- merge(rt, meta, by.x="doc_id", by.y="filename", all.x=TRUE)
cat(sprintf("Successfully merged: %d documents with metadata\n", nrow(docs)))

# Verify we have text content
empty_docs <- sum(is.na(docs$text) | nchar(docs$text) == 0)
if (empty_docs > 0) {
  cat(sprintf("Warning: %d documents have no text content\n", empty_docs))
  docs <- docs[!is.na(text) & nchar(text) > 0]
  cat(sprintf("Proceeding with %d documents with content\n", nrow(docs)))
}

# Check for missing metadata
missing_meta <- sum(is.na(docs$gender))
if (missing_meta > 0) {
    cat(sprintf("Warning: %d documents missing gender metadata\n", missing_meta))
}

# ---- Optional: segment long documents into chunks of ~CHUNK_TOKS tokens ----
segment_one <- function(id, txt, n_per = CHUNK_TOKS){
  toks <- quanteda::tokens(txt, remove_punct = TRUE)
  if (length(toks[[1]]) == 0L) return(data.table(filename=id, chunk_id=1L, text=""))
  n <- length(toks[[1]])
  bins <- ceiling(seq_len(n) / n_per)
  DT <- data.table(chunk_id = bins, token = toks[[1]])
  DT <- DT[, .(text = paste(token, collapse = " ")), by = chunk_id]
  DT[, filename := id]  # Use filename to match metadata structure
  setcolorder(DT, c("filename","chunk_id","text"))
  DT[]
}

if (USE_CHUNKS) {
  cat("Segmenting documents into chunks...\n")
  chunks_list <- docs[, {
  if (.GRP %% 100 == 0) cat(sprintf("  Processing document %d/%d\n", .GRP, .N))
    segment_one(doc_id, text, CHUNK_TOKS)  # Fixed: removed rg_number
  }, 
  by = doc_id]
  cat("Chunks created:\n")
  print(head(chunks_list,3))  # Show first few chunks for debugging
  cat("docs_list created:\n")
  print(head(docs,3))  # Show first few documents for debugging
  
  # carry metadata to each chunk - merge using filename
  cat("Adding metadata to chunks...\n")
  # Create a lookup table with filename as key
  meta_lookup <- unique(docs[, .(filename = doc_id, gender, year, interviewee, rg_number)])
  chunks <- merge(chunks_list, meta_lookup, by="filename", all.x=TRUE)
  
  stm_input <- chunks
  stm_input[, parent_id := filename]           # remember original doc
  stm_input[, doc_id := sprintf("%s#%03d", parent_id, chunk_id)]  # unique id per chunk
} else {
  stm_input <- docs[, .(doc_id, filename = doc_id, rg_number, text, gender, year, interviewee)]
  stm_input[, parent_id := doc_id]
  cat(sprintf("Using %d full documents (no chunking)\n", nrow(stm_input)))
}

# ---- Inspect the processed data ----
cat("\nData inspection:\n")
cat("First few rows of stm_input:\n")
print(head(stm_input, 3))
cat("\nDimensions:", nrow(stm_input), "rows x", ncol(stm_input), "columns\n")
cat("Column names:", paste(names(stm_input), collapse = ", "), "\n\n")


# ---- Preprocess with stm helpers ----
cat("Preprocessing text...\n")

# Remove speaker labels (names followed by colons at start of lines)
cat("Removing speaker labels (names followed by colons)...\n")
# More comprehensive pattern to catch various speaker label formats
speaker_patterns <- c(
  "^[A-Za-z]+ [A-Za-z]+:",        # "First Last:" at start of line
  "^[A-Za-z]+:",                  # "Name:" at start of line  
  "\\n[A-Za-z]+ [A-Za-z]+:",      # "\nFirst Last:" 
  "\\n[A-Za-z]+:",                # "\nName:"
  "\\r[A-Za-z]+ [A-Za-z]+:",      # "\rFirst Last:"
  "\\r[A-Za-z]+:"                 # "\rName:"
)

for (pattern in speaker_patterns) {
  stm_input[, text := gsub(pattern, "", text, perl = TRUE)]
}

# Clean up extra whitespace after removing speaker labels
stm_input[, text := gsub("\\n\\s+", "\n", text, perl = TRUE)]  # Remove extra spaces after newlines
stm_input[, text := gsub("^\\s+", "", text, perl = TRUE)]      # Remove leading whitespace
stm_input[, text := trimws(text)]                              # Trim overall whitespace

# Remove empty or NA text
initial_rows <- nrow(stm_input)  # Fix: define initial_rows before using it
stm_input <- stm_input[nchar(text) > 0 & !is.na(text)]
cat(sprintf("Removed %d empty/NA texts, %d remaining\n", initial_rows - nrow(stm_input), nrow(stm_input)))


cat("Running textProcessor (this may take several minutes for large datasets)...\n")
# Process text: tokenize, remove stopwords, punctuation, etc.
# only removes very common function words like "the", "and", etc.
# Does not stem words, as we want to keep the original form for labeling. Oral histories often use specific tenses/forms that carry meaning, stemming makes output harder to interpret for researchers. (e.g. Loses important distinctions: "children" vs "childhood")

# Add custom stopwords for oral history interviews
custom_stopwords <- c(
  # Common interview discourse markers
  "know", "like", "well", "think", "said", "going", "didnt", "dont", "yeah", 
  "okay", "right", "now", "just", "get", "got", "went", "came", "come",
  "one", "two", "three", "time", "times", "people", "person", "like",
  # Interview-specific words
  "interview", "tape", "side", "end", "beginning", "transcript",
  # Common names that might appear after removing colons
  "interviewer", "interviewee", "narrator", "speaker"
)

# Convert metadata to data.frame to avoid data.table scoping issues
meta_for_stm <- as.data.frame(stm_input[, .(doc_id, parent_id, gender, year, interviewee)])

processed <- textProcessor(
  documents = stm_input$text,
  metadata  = meta_for_stm,
  lowercase = TRUE, removestopwords = TRUE, removenumbers = TRUE,
  removepunctuation = TRUE, stem = FALSE, verbose = TRUE,
  customstopwords = custom_stopwords)

cat("Preparing documents (removing rare words)...\n")
# removes very rare words that might confuse the topic model (like typos or very specific names)
# Increase threshold for small datasets to get more meaningful words
word_threshold <- if (length(processed$documents) < 100) 3 else 5
cat(sprintf("Using word frequency threshold: %d\n", word_threshold))
prep <- prepDocuments(processed$documents, processed$vocab, processed$meta, lower.thresh = word_threshold)

docs_out  <- prep$documents
vocab_out <- prep$vocab
meta_out  <- as.data.table(prep$meta)

# Make sure gender is a factor with two levels
meta_out[, gender := factor(gender, levels=c("Female","Male"))]

# ---- Fit STM (prevalence + content) ----
cat("Fitting STM model...\n")
cat(sprintf("Model parameters: K=%d topics, %d documents, %d vocabulary terms\n", K, length(docs_out), length(vocab_out)))

# Simplified model for small dataset testing
# Check if we have enough data for complex models
n_docs <- length(docs_out)
cat(sprintf("Number of documents: %d\n", n_docs))
cat(sprintf("Number of vocabulary terms: %d\n", length(vocab_out)))

# Check gender distribution
gender_counts <- table(meta_out$gender, useNA = "always")
cat("Gender distribution (after chunking):\n")
print(gender_counts)

# Show unique documents by gender
if (USE_CHUNKS && "parent_id" %in% names(meta_out)) {
  unique_docs <- unique(meta_out[, .(parent_id, gender)])
  unique_gender_counts <- table(unique_docs$gender, useNA = "always")
  cat("Unique document gender distribution:\n")
  print(unique_gender_counts)
  cat(sprintf("Original files: %d, Total chunks: %d\n", nrow(unique_docs), nrow(meta_out)))
}

if (n_docs >= 50 && all(gender_counts >= 5, na.rm = TRUE)) {
  # Full model for larger datasets with sufficient gender representation
  form_prev <- ~ gender + s(year, df=3)  # reduced df for smaller datasets
  form_cont <- ~ gender
  cat("Using full model with gender covariates\n")
} else {
  # Simplified model for very small datasets or insufficient gender variation
  form_prev <- ~ gender  # no spline for year with small data
  form_cont <- NULL      # no content covariate for small data
  cat("Using simplified model (no content covariate) for small dataset or insufficient gender variation\n")
}

stm_fit <- stm(documents = docs_out,
               vocab      = vocab_out,
               K          = K,
               prevalence = form_prev,
               content    = form_cont,
               data       = meta_out,
               max.em.its = 100,      # reduced iterations for testing
               init.type  = "Spectral",
               verbose    = TRUE)

cat("Saving model...\n")
dir.create("models", showWarnings = FALSE)
saveRDS(stm_fit, file = sprintf("models/stm_k%02d.rds", K))

# ---- Per-document topic mixtures (theta) ----
theta <- as.data.table(stm_fit$theta)
theta[, doc_id := meta_out$doc_id]
theta <- melt(theta, id.vars="doc_id", variable.name="topic", value.name="gamma")
theta[, topic := as.integer(gsub("V","", topic))]

# Map back to parent documents (aggregate chunk-level to document-level if chunked)
theta <- merge(theta, meta_out[, .(doc_id, parent_id, gender, year)], by="doc_id")
if (USE_CHUNKS) {
  # Simple mean aggregation instead of weighted mean to avoid dimension issues
  theta_doc <- theta[, .(gamma = mean(gamma, na.rm = TRUE)), by=.(parent_id, topic, gender, year)]
  setnames(theta_doc, "parent_id", "doc_id")
} else {
  theta_doc <- theta[, .(gamma = mean(gamma, na.rm = TRUE)), by=.(doc_id, topic, gender, year)]
}

# Save per-document topic proportions (wide & long)
dir.create("outputs", showWarnings = FALSE)
dir.create("outputs/csv", showWarnings = FALSE)
dir.create("outputs/plots", showWarnings = FALSE)

theta_wide <- dcast(theta_doc, doc_id + gender + year ~ paste0("topic_", topic), value.var = "gamma", fill = 0)
fwrite(theta_doc,  file = sprintf("outputs/csv/doc_topic_long_k%02d.csv", K))
fwrite(theta_wide, file = sprintf("outputs/csv/doc_topic_wide_k%02d.csv", K))

# ---- Topic labeling (coherence/exclusivity + frex/lift/score) ----
n_words_per_topic <- 15
labs <- labelTopics(stm_fit, n = n_words_per_topic)

# Debug: Check how many words we actually got
cat("Topic labeling debug info:\n")
for (i in 1:min(3, K)) {  # Show first 3 topics
  cat(sprintf("Topic %d - frex words: %d, prob words: %d\n", 
              i, length(labs$frex[[i]]), length(labs$prob[[i]])))
  cat(sprintf("  frex: %s\n", paste(labs$frex[[i]], collapse=", ")))
  cat(sprintf("  prob: %s\n", paste(labs$prob[[i]], collapse=", ")))
}

# Handle potential NULL values in labels - more robust approach
safe_paste <- function(x, max_words = 15) {
  if (is.null(x) || length(x) == 0) {
    return("")
  }
  # Convert to character and remove any remaining NULLs
  x_clean <- x[!sapply(x, is.null)]
  if (length(x_clean) == 0) {
    return("")
  }
  # Take up to max_words and paste with commas
  words_to_use <- head(as.character(x_clean), max_words)
  paste(words_to_use, collapse=", ")
}

# Extract each component separately and ensure they're character vectors
frex_labels <- character(K)
lift_labels <- character(K)
score_labels <- character(K)
prob_labels <- character(K)

for (i in 1:K) {
  frex_labels[i] <- safe_paste(labs$frex[[i]], max_words = n_words_per_topic)
  lift_labels[i] <- safe_paste(labs$lift[[i]], max_words = n_words_per_topic)
  score_labels[i] <- safe_paste(labs$score[[i]], max_words = n_words_per_topic)
  prob_labels[i] <- safe_paste(labs$prob[[i]], max_words = n_words_per_topic)
}

topic_labels <- data.table(
  topic = seq_len(K),
  frex  = frex_labels,
  lift  = lift_labels,
  score = score_labels,
  prob  = prob_labels
)

fwrite(topic_labels, file = sprintf("outputs/csv/topic_labels_k%02d.csv", K))

# ---- Create readable topic summary with full 15 words ----
# Create a more readable CSV with topic names and full word lists
topic_summary <- data.table(
  topic_number = seq_len(K),
  topic_name = paste0("Topic ", seq_len(K)),
  top_15_frex_words = frex_labels,
  top_15_prob_words = prob_labels,
  description = paste0("Topic about: ", sapply(strsplit(frex_labels, ", "), function(x) paste(head(x, 3), collapse=", ")))
)

fwrite(topic_summary, file = sprintf("outputs/csv/topic_summary_readable_k%02d.csv", K))

# Also create a simple version with just numbers and words
simple_topics <- data.table(
  topic = seq_len(K),
  words = frex_labels
)

fwrite(simple_topics, file = sprintf("outputs/csv/topics_simple_k%02d.csv", K))

cat("Topic summaries saved:\n")
cat(sprintf("- Full details: outputs/csv/topic_labels_k%02d.csv\n", K))
cat(sprintf("- Readable format: outputs/csv/topic_summary_readable_k%02d.csv\n", K))
cat(sprintf("- Simple format: outputs/csv/topics_simple_k%02d.csv\n", K))

# ---- Gender effect on topic prevalence (with uncertainty) ----
# "Female - Male" difference in expected topic proportion
# Use same formula as in the model
if (n_docs >= 50) {
  eff_formula <- 1:K ~ gender + s(year, df=3)
} else {
  eff_formula <- 1:K ~ gender
}

# Convert metadata to data.frame to avoid data.table scoping issues
meta_for_effect <- as.data.frame(meta_out)

eff <- estimateEffect(eff_formula,
                      stmobj = stm_fit, metadata = meta_for_effect, uncertainty = "Global")

# Extract the marginal difference Female-Male per topic at mean(year)
diff_tab <- lapply(1:K, function(k){
  est <- summary(eff, topics = k)
  # first coefficient is intercept; the "genderMale" coefficient is Male vs Female.
  # To report Female - Male, negate that coefficient.
  coefs <- est$tables[[1]]
  # Try to find the gender row robustly
  row <- coefs[grep("gender", rownames(coefs), ignore.case=TRUE), , drop=FALSE]
  if(nrow(row)==0) return(data.table(topic=k, diff=NA_real_, se=NA_real_, p=NA_real_))
  data.table(topic = k,
             diff   = -1 * row[1,"Estimate"],
             se     = row[1,"Std. Error"],
             p      = row[1,"Pr(>|t|)"])
})
diff_tab <- rbindlist(diff_tab)
setorder(diff_tab, p)
fwrite(diff_tab, file = sprintf("outputs/csv/gender_prevalence_effects_k%02d.csv", K))

# ---- Gender-specific wording per topic (content covariate "gender") ----
# Only run if content covariate was used
if (!is.null(form_cont)) {
  cat("Running content analysis with gender covariate...\n")
  tryCatch({
    # SAGE-style labels by group ("perspectives")
    sage <- sageLabels(stm_fit, n = 15)
    
    # Check if sage analysis worked
    if (!is.null(sage) && !is.null(sage$covar) && !is.null(sage$covar$gender)) {
      # Convert to a tidy table
      get_tbl <- function(covar_list, group_name) {
        if (is.null(covar_list) || length(covar_list) == 0) {
          # Return empty table if no data
          return(data.table(
            topic = seq_len(K),
            words = rep("", K),
            group = group_name
          ))
        }
        
        words_vec <- character(K)
        for (i in 1:K) {
          if (i <= length(covar_list)) {
            words_vec[i] <- safe_paste(covar_list[[i]])
          } else {
            words_vec[i] <- ""
          }
        }
        
        data.table(
          topic = seq_len(K),
          words = words_vec,
          group = group_name
        )
      }
      
      content_tbl <- rbindlist(list(
        get_tbl(sage$covar$gender$Female, "Female"),
        get_tbl(sage$covar$gender$Male,   "Male")
      ), use.names=TRUE, fill=TRUE)
      
      fwrite(content_tbl, file = sprintf("outputs/csv/topic_content_words_by_gender_k%02d.csv", K))
      cat("Content analysis completed.\n")
    } else {
      cat("SAGE analysis returned NULL or incomplete results. Skipping content output.\n")
    }
  }, error = function(e) {
    cat("Error in content analysis:", e$message, "\n")
    cat("Skipping content analysis output.\n")
  })
} else {
  cat("Skipping content analysis (no content covariate used in model)\n")
}

# ---- Convenience: top-3 topics per document (for spot checks) ----
top3 <- theta_doc[order(doc_id, -gamma), .SD[1:3], by=doc_id]
fwrite(top3, file = sprintf("outputs/csv/doc_top3_topics_k%02d.csv", K))

# ---- Optional sanity plots ----
cat("Generating plots...\n")
tryCatch({
  pdf(sprintf("outputs/plots/quicklook_k%02d.pdf", K), width=12, height=9)
  
  # Topic summary plot with more words shown
  plot(stm_fit, type="summary", n=10, labeltype="frex", text.cex=0.8)
  
  # Additional plot with more detailed labels
  plot(stm_fit, type="labels", n=8, labeltype="frex", text.cex=0.7)
  
  # Topic correlations (prevalence scale)
  if (K > 1) {  # Need at least 2 topics for correlations
    tc <- topicCorr(stm_fit)
    plot(tc)
  } else {
    cat("Skipping correlation plot (only 1 topic)\n")
  }
  
  dev.off()
  cat("Plots saved successfully.\n")
}, error = function(e) {
  # Make sure to close any open plot devices
  if (dev.cur() > 1) dev.off()
  cat("Error generating plots:", e$message, "\n")
  cat("Continuing without plots...\n")
})

message("Done. Artifacts in outputs/csv and outputs/plots . Model saved in models/.")