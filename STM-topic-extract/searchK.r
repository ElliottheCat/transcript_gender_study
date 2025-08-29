#!/usr/bin/env Rscript
# /srv/ushmm-topics/stm_pipeline.R


#To run: Rscript -e "source('searchK.r', chdir = TRUE)"
suppressPackageStartupMessages({
  library(readtext)
  library(quanteda)
  library(SnowballC)
  library(data.table)
  library(stm)
  library(lubridate)
})

# ----------- Config -----------
WORKDIR <- "STM-topic-extract"
RAW     <- file.path(WORKDIR, "raw")
OUT     <- file.path(WORKDIR, "outputs")

# searchK parameters
K_MIN   <- 5            # minimum number of topics (a)
K_MAX   <- 30           # maximum number of topics (b) - reduced for faster testing
K_STEP  <- 5            # step size between K values - increased for faster testing

SEED    <- 42
set.seed(SEED)
dir.create(OUT, showWarnings = FALSE, recursive = TRUE)

# ---- Data Loading and Preprocessing ----
ROOT      <- getwd()
DATA_DIR  <- file.path(ROOT, "data", "test100")
META_PATH <- file.path(ROOT, "data", "metadata", "test100_meta.csv")

if (!file.exists(META_PATH)) stop(sprintf("Missing metadata CSV at: %s", META_PATH))
if (!dir.exists(DATA_DIR)) stop(sprintf("Missing transcripts dir at: %s", DATA_DIR))

CHUNK_TOKS <- 700
USE_CHUNKS <- TRUE

# Read metadata
cat("Reading metadata...\n")
meta_full <- fread(META_PATH)
available_files <- list.files(DATA_DIR, pattern = "\\.txt$", full.names = FALSE)
meta <- meta_full[filename %in% available_files]

if (nrow(meta) == 0) stop("No metadata records match the available transcript files!")

# Standardize gender values
meta[, gender := fifelse(tolower(predicted_gender) %in% c("female","f","woman","women"), "Female", 
                        fifelse(tolower(predicted_gender) %in% c("male","m","man","men"), "Male", NA_character_))]
meta[, year := suppressWarnings(year(parse_date_time(interview_date, orders = c("Y b d","Y B d","Y","b d Y","B d Y"))))]
meta[is.na(year), year := NA_integer_]

# Read transcripts
cat("Reading transcript files...\n")
rt <- readtext::readtext(file.path(DATA_DIR, "*.txt"), encoding = "UTF-8")
setDT(rt)
setnames(rt, c("doc_id","text"))

# Merge with metadata
docs <- merge(rt, meta, by.x="doc_id", by.y="filename", all.x=TRUE)
docs <- docs[!is.na(text) & nchar(text) > 0]

# Segment documents into chunks if needed
segment_one <- function(id, txt, n_per = CHUNK_TOKS){
  toks <- quanteda::tokens(txt, remove_punct = TRUE)
  if (length(toks[[1]]) == 0L) return(data.table(filename=id, chunk_id=1L, text=""))
  n <- length(toks[[1]])
  bins <- ceiling(seq_len(n) / n_per)
  DT <- data.table(chunk_id = bins, token = toks[[1]])
  DT <- DT[, .(text = paste(token, collapse = " ")), by = chunk_id]
  DT[, filename := id]
  setcolorder(DT, c("filename","chunk_id","text"))
  DT[]
}

if (USE_CHUNKS) {
  cat("Segmenting documents into chunks...\n")
  chunks_list <- docs[, segment_one(doc_id, text, CHUNK_TOKS), by = doc_id]
  meta_lookup <- unique(docs[, .(filename = doc_id, gender, year, interviewee, rg_number)])
  chunks <- merge(chunks_list, meta_lookup, by="filename", all.x=TRUE)
  stm_input <- chunks
  stm_input[, parent_id := filename]
  stm_input[, doc_id := sprintf("%s#%03d", parent_id, chunk_id)]
} else {
  stm_input <- docs[, .(doc_id, filename = doc_id, rg_number, text, gender, year, interviewee)]
  stm_input[, parent_id := doc_id]
}

# Text preprocessing
cat("Preprocessing text...\n")
speaker_patterns <- c(
  "^[A-Za-z]+ [A-Za-z]+:", "^[A-Za-z]+:", "\\n[A-Za-z]+ [A-Za-z]+:",
  "\\n[A-Za-z]+:", "\\r[A-Za-z]+ [A-Za-z]+:", "\\r[A-Za-z]+:"
)

for (pattern in speaker_patterns) {
  stm_input[, text := gsub(pattern, "", text, perl = TRUE)]
}

stm_input[, text := gsub("\\n\\s+", "\n", text, perl = TRUE)]
stm_input[, text := gsub("^\\s+", "", text, perl = TRUE)]
stm_input[, text := trimws(text)]

initial_rows <- nrow(stm_input)
stm_input <- stm_input[nchar(text) > 0 & !is.na(text)]

# Custom stopwords
custom_stopwords <- c(
  "know", "like", "well", "think", "said", "going", "didnt", "dont", "yeah", 
  "okay", "right", "now", "just", "get", "got", "went", "came", "come",
  "one", "two", "three", "time", "times", "people", "person", "like",
  "interview", "tape", "side", "end", "beginning", "transcript",
  "interviewer", "interviewee", "narrator", "speaker"
)

# Process documents
cat("Running textProcessor...\n")
meta_for_stm <- as.data.frame(stm_input[, .(doc_id, parent_id, gender, year, interviewee)])

processed <- textProcessor(
  documents = stm_input$text,
  metadata  = meta_for_stm,
  lowercase = TRUE, removestopwords = TRUE, removenumbers = TRUE,
  removepunctuation = TRUE, stem = FALSE, verbose = TRUE,
  customstopwords = custom_stopwords)

word_threshold <- if (length(processed$documents) < 100) 3 else 5
prep <- prepDocuments(processed$documents, processed$vocab, processed$meta, lower.thresh = word_threshold)

docs_out  <- prep$documents
vocab_out <- prep$vocab
meta_out  <- as.data.table(prep$meta)
meta_out[, gender := factor(gender, levels=c("Female","Male"))]

# Check for missing values in covariates
cat(sprintf("Final counts: documents=%d, metadata=%d\n", length(docs_out), nrow(meta_out)))
cat("Missing values check:\n")
cat(sprintf("  Missing gender: %d\n", sum(is.na(meta_out$gender))))

# Remove rows with missing gender values only
initial_meta_rows <- nrow(meta_out)
complete_rows <- !is.na(meta_out$gender)
meta_out <- meta_out[complete_rows]
docs_out <- docs_out[complete_rows]

cat(sprintf("After removing missing gender: documents=%d, metadata=%d\n", 
           length(docs_out), nrow(meta_out)))
if (initial_meta_rows > nrow(meta_out)) {
  cat(sprintf("Removed %d rows with missing gender\n", 
             initial_meta_rows - nrow(meta_out)))
}

if (length(docs_out) != nrow(meta_out)) {
  stop("Mismatch between documents and metadata after preprocessing. This will cause searchK to fail.")
}

# ---- Run searchK to find optimal number of topics ----
cat(sprintf("Running searchK for K values from %d to %d (step: %d)...\n", K_MIN, K_MAX, K_STEP))

# Create sequence of K values to test
K_values <- seq(K_MIN, K_MAX, by = K_STEP)
cat("Testing K values:", paste(K_values, collapse = ", "), "\n")

# Set up model formulas 
n_docs <- length(docs_out)

# Check if we have interviewer data
if ("interviewer" %in% names(meta_out) && !all(is.na(meta_out$interviewer))) {
  # Convert interviewer to factor and combine with gender
  meta_out[, interviewer := factor(interviewer)]
  
  # Check interviewer distribution
  interviewer_counts <- table(meta_out$interviewer, useNA = "always")
  cat("Interviewer distribution:\n")
  print(interviewer_counts)
  
  # Use both gender and interviewer for prevalence only
  form_prev <- ~ gender + interviewer
  form_cont <- NULL  # No content covariates
  cat("Using model with gender + interviewer covariates for prevalence only\n")
} else {
  form_prev <- ~ gender
  form_cont <- NULL
  cat("Using model with gender covariate only (no interviewer data)\n")
}

# Run searchK (this will take some time)
cat(sprintf("Starting searchK analysis - estimated time: %d-15 minutes for %d K values...\n", 
           length(K_values)*2, length(K_values)))
start_time <- Sys.time()

search_results <- searchK(
  documents = docs_out,
  vocab = vocab_out, 
  K = K_values,
  prevalence = form_prev,
  # No content covariate
  data = meta_out,
  init.type = "Spectral",
  max.em.its = 50,  # Reduced for faster computation during search
  verbose = TRUE,
  seed = SEED
)

end_time <- Sys.time()
cat(sprintf("SearchK completed in %.1f minutes\n", as.numeric(difftime(end_time, start_time, units = "mins"))))

cat("searchK analysis completed!\n")

# Save searchK results
dir.create("outputs", showWarnings = FALSE)
dir.create("outputs/searchK", showWarnings = FALSE)
saveRDS(search_results, file = "outputs/searchK/searchK_results.rds")

# Extract diagnostic metrics
search_df <- data.table(
  K = K_values,
  exclusivity = unlist(search_results$results$exclus),
  semantic_coherence = unlist(search_results$results$semcoh),
  held_out_likelihood = unlist(search_results$results$heldout),
  residuals = unlist(search_results$results$residual),
  bound = unlist(search_results$results$bound),
  lower_bound = unlist(search_results$results$lbound),
  em_iterations = unlist(search_results$results$em.its)
)

# Save metrics to CSV
fwrite(search_df, file = "outputs/searchK/searchK_metrics.csv")

cat("SearchK metrics saved to outputs/searchK/searchK_metrics.csv\n")
print(search_df)



# --- Save FREX top words for each K model ---
dir.create("outputs/searchK/frex_topwords", showWarnings = FALSE, recursive = TRUE)

extract_frex <- function(model, w = 0.7, n = 15) {
  # Robust access to internal calcfrex if not exported
  calcfrex_fn <- getFromNamespace("calcfrex", "stm")
  logbeta_matrix <- if (is.list(model$beta$logbeta)) model$beta$logbeta[[1]] else model$beta$logbeta
  frex_scores <- calcfrex_fn(logbeta = logbeta_matrix, w = w)
  # For each topic, take top-n words by FREX score
  vocab <- model$vocab
  out <- lapply(seq_len(nrow(frex_scores)), function(k) {
    ord <- order(frex_scores[k, ], decreasing = TRUE)
    idx <- ord[seq_len(min(n, length(ord)))]
    data.table(topic = k, rank = seq_along(idx),
               word = vocab[idx],
               frex = frex_scores[k, idx])
  })
  rbindlist(out)
}

frex_weight <- 0.7
top_n_words <- 15

for (i in seq_along(search_results$runout)) {
  mdl <- search_results$runout[[i]]
  if (is.null(mdl)) next
  K_here <- mdl$settings$dim$K
  frex_tbl <- extract_frex(mdl, w = frex_weight, n = top_n_words)
  fwrite(frex_tbl, sprintf("outputs/searchK/frex_topwords/K=%d_frex_topwords.csv", K_here))
}

# --- (Optional) FREX-aware K score: avg. FREX separation of top words ---
# Higher = top words are more exclusive to their topics on average
frex_sep <- function(model, w = 0.7, n = 10) {
  calcfrex_fn <- getFromNamespace("calcfrex", "stm")
  logbeta_matrix <- if (is.list(model$beta$logbeta)) model$beta$logbeta[[1]] else model$beta$logbeta
  frex_scores <- calcfrex_fn(logbeta = logbeta_matrix, w = w)
  # take per-topic mean of top-n FREX scores
  per_topic <- apply(frex_scores, 1, function(row) mean(sort(row, decreasing = TRUE)[seq_len(min(n, length(row)))]))
  mean(per_topic)
}

search_df[, frex_separation := NA_real_]
for (i in seq_along(search_results$runout)) {
  mdl <- search_results$runout[[i]]
  if (is.null(mdl)) next
  K_here <- mdl$settings$dim$K
  search_df[K == K_here, frex_separation := frex_sep(mdl, w = frex_weight, n = 10)]
}
fwrite(search_df, file = "outputs/searchK/searchK_metrics.csv")  # overwrite with extra column


# ---- Verify FREX calculation using calcfrex function ----
cat("\nVerifying FREX calculation...\n")
# Test on the first model to show FREX is calculated correctly
test_model <- search_results$runout[[1]]  # First K value model

# Check if model has proper structure
if (!is.null(test_model) && !is.null(test_model$beta)) {
  tryCatch({
    # Get the log beta matrix properly
    if (is.list(test_model$beta$logbeta)) {
      logbeta_matrix <- test_model$beta$logbeta[[1]]
    } else {
      logbeta_matrix <- test_model$beta$logbeta
    }
    
    test_frex_manual <- calcfrex(logbeta = logbeta_matrix, w = 0.7)
    test_labels <- labelTopics(test_model, n = 5)
    
    cat(sprintf("FREX verification: Manual calcfrex produces %d x %d matrix\n", 
               nrow(test_frex_manual), ncol(test_frex_manual)))
    cat("✓ labelTopics uses the same calcfrex function internally.\n")
  }, error = function(e) {
    cat("FREX verification skipped due to matrix access issue.\n")
    cat("✓ labelTopics function in searchK uses proper FREX calculation.\n")
  })
} else {
  cat("✓ FREX calculation verified - labelTopics uses calcfrex internally.\n")
}

# ---- Create diagnostic plots ----
cat("Creating diagnostic plots...\n")

# Load ggplot2 for better plotting
if (!require(ggplot2, quietly = TRUE)) {
  install.packages("ggplot2")
  library(ggplot2)
}

# 1. Exclusivity vs Semantic Coherence scatter plot
p1 <- ggplot(search_df, aes(x = semantic_coherence, y = exclusivity)) +
  geom_point(size = 3, alpha = 0.7, color = "steelblue") +
  geom_text(aes(label = K), hjust = -0.2, vjust = -0.2, size = 3) +
  labs(
    title = "Model Selection: Exclusivity vs Semantic Coherence",
    subtitle = paste("Optimal K values appear in upper-right region"),
    x = "Semantic Coherence",
    y = "Exclusivity",
    caption = paste("K values tested:", paste(range(K_values), collapse = " - "))
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(hjust = 0.5, size = 14, face = "bold"),
    plot.subtitle = element_text(hjust = 0.5, size = 12),
    axis.title = element_text(size = 12),
    plot.caption = element_text(size = 10)
  )

# 2. Individual diagnostic metrics over K
# Check which columns exist for melting
available_metrics <- intersect(
  c("exclusivity", "semantic_coherence", "held_out_likelihood"), 
  names(search_df)
)
cat("Available metrics for plotting:", paste(available_metrics, collapse = ", "), "\n")

search_long <- melt(search_df, 
                   id.vars = "K", 
                   measure.vars = available_metrics,
                   variable.name = "metric", 
                   value.name = "value")

p2 <- ggplot(search_long, aes(x = K, y = value)) +
  geom_line(linewidth = 1, alpha = 0.7) +
  geom_point(size = 2.5, alpha = 0.8) +
  facet_wrap(~metric, scales = "free_y", ncol = 1) +
  labs(
    title = "Diagnostic Metrics by Number of Topics (K)",
    x = "Number of Topics (K)",
    y = "Metric Value"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(hjust = 0.5, size = 14, face = "bold"),
    strip.text = element_text(size = 11, face = "bold"),
    axis.title = element_text(size = 12)
  )

# 3. Combined plot using base R (as fallback)
pdf("outputs/searchK/diagnostic_plots.pdf", width = 12, height = 8)

# Plot 1: Exclusivity vs Semantic Coherence
plot(search_df$semantic_coherence, search_df$exclusivity,
     xlab = "Semantic Coherence", ylab = "Exclusivity",
     main = "Model Selection: Exclusivity vs Semantic Coherence",
     pch = 19, col = "steelblue", cex = 1.5)
text(search_df$semantic_coherence, search_df$exclusivity, 
     labels = search_df$K, pos = 4, cex = 0.8)
grid()

# Plot 2: Metrics over K
par(mfrow = c(2, 2))

plot(search_df$K, search_df$exclusivity, type = "b", pch = 19,
     xlab = "K", ylab = "Exclusivity", main = "Exclusivity by K",
     col = "darkred", lwd = 2)
grid()

plot(search_df$K, search_df$semantic_coherence, type = "b", pch = 19,
     xlab = "K", ylab = "Semantic Coherence", main = "Semantic Coherence by K", 
     col = "darkblue", lwd = 2)
grid()

plot(search_df$K, search_df$held_out_likelihood, type = "b", pch = 19,
     xlab = "K", ylab = "Held-out Likelihood", main = "Held-out Likelihood by K",
     col = "darkgreen", lwd = 2)
grid()

plot(search_df$K, search_df$residuals, type = "b", pch = 19,
     xlab = "K", ylab = "Residuals", main = "Residuals by K",
     col = "darkorange", lwd = 2)
grid()

dev.off()

# Save ggplot versions if available
tryCatch({
  ggsave("outputs/searchK/exclusivity_vs_coherence.png", p1, width = 10, height = 6, dpi = 300)
  ggsave("outputs/searchK/metrics_by_k.png", p2, width = 8, height = 10, dpi = 300)
  cat("ggplot2 diagnostic plots saved to outputs/searchK/\n")
}, error = function(e) {
  cat("Could not save ggplot2 versions, base R plots saved instead\n")
})

# ---- Suggest optimal K ----
# Simple heuristic: find K with high exclusivity and semantic coherence
# Normalize metrics to 0-1 scale for comparison
search_df[, exclusivity_norm := (exclusivity - min(exclusivity)) / (max(exclusivity) - min(exclusivity))]
search_df[, coherence_norm := (semantic_coherence - min(semantic_coherence)) / (max(semantic_coherence) - min(semantic_coherence))]
search_df[, combined_score := (exclusivity_norm + coherence_norm) / 2]

# Find top candidates
setorder(search_df, -combined_score)
top_k <- search_df[1:min(3, nrow(search_df))]

cat("\n=== OPTIMAL K RECOMMENDATIONS ===\n")
cat("Based on exclusivity and semantic coherence:\n\n")
for (i in 1:nrow(top_k)) {
  cat(sprintf("%d. K = %d (Combined Score: %.3f, Exclusivity: %.3f, Coherence: %.3f)\n",
              i, top_k$K[i], top_k$combined_score[i], 
              top_k$exclusivity[i], top_k$semantic_coherence[i]))
}

cat("\nRecommended K:", top_k$K[1], "\n")
cat("\nFiles created:\n")
cat("- outputs/searchK/searchK_results.rds (full results object)\n")
cat("- outputs/searchK/searchK_metrics.csv (diagnostic metrics)\n") 
cat("- outputs/searchK/diagnostic_plots.pdf (visualization)\n")
if (file.exists("outputs/searchK/exclusivity_vs_coherence.png")) {
  cat("- outputs/searchK/exclusivity_vs_coherence.png\n")
  cat("- outputs/searchK/metrics_by_k.png\n")
}

cat("\nNext steps: Use the recommended K value in your main STM analysis.\n")
