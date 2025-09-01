#!/usr/bin/env Rscript
# /srv/ushmm-topics/stm_pipeline.R

suppressPackageStartupMessages({
  library(readtext)
  library(quanteda)
  library(SnowballC)
  library(data.table)
  library(stm)
  library(ggplot2)
  library(lubridate)
  library(dplyr)
  library(reshape2)
})

# ----------- Config -----------
WORKDIR <- "STM-topic-extract"
DATA_DIR <- file.path(WORKDIR, "data", "test100")  # Use test100 data
META_PATH <- file.path(WORKDIR, "data", "metadata", "test100_meta.csv")  # Use test100 metadata

# Create indexed trial folder
base_out <- file.path(WORKDIR, "outputs")
existing_trials <- list.dirs(base_out, full.names = FALSE, recursive = FALSE)
existing_trials <- existing_trials[grepl("^stm_trial", existing_trials)]
if (length(existing_trials) > 0) {
  trial_numbers <- as.numeric(gsub("stm_trial", "", existing_trials))
  next_trial <- max(trial_numbers, na.rm = TRUE) + 1
} else {
  next_trial <- 1
}
OUT <- file.path(base_out, sprintf("stm_trial%d", next_trial))
cat(sprintf("Creating trial folder: %s\n", OUT))
K       <- 12          # set your chosen K from searchK results
SEED    <- SEED <- as.integer(runif(1, min = 1, max = 1e6)) # use random seed to get different results.
CHUNK_TOKS <- 700
USE_CHUNKS <- TRUE

set.seed(SEED)
dir.create(OUT, showWarnings = FALSE, recursive = TRUE)
dir.create(file.path(OUT, "csv"), showWarnings = FALSE)
dir.create(file.path(OUT, "plots"), showWarnings = FALSE)

# Save the random seed (in case we want to reproduce the results.)
writeLines(as.character(SEED), file.path(OUT, "seed.txt"))
cat(sprintf("Seed for this run: %d (saved to %s)\n", SEED, file.path(OUT, "seed.txt")))

# ----------- Load test100 data and metadata -----------
cat("Loading test100 data...\n")

# Check paths
if (!dir.exists(DATA_DIR)) stop(sprintf("Data directory not found: %s", DATA_DIR))
if (!file.exists(META_PATH)) stop(sprintf("Metadata file not found: %s", META_PATH))

# Load metadata
meta_full <- fread(META_PATH)
cat(sprintf("Loaded metadata: %d rows\n", nrow(meta_full)))

# Load transcript files
available_files <- list.files(DATA_DIR, pattern = "\\.txt$", full.names = FALSE)
cat(sprintf("Found %d transcript files\n", length(available_files)))

# Filter metadata to match available files
meta <- meta_full[filename %in% available_files]
cat(sprintf("Matched %d files with metadata\n", nrow(meta)))

# Read transcripts
rt <- readtext::readtext(file.path(DATA_DIR, "*.txt"), encoding = "UTF-8")
setDT(rt)
setnames(rt, c("doc_id", "text"))

# Merge with metadata
docs <- merge(rt, meta, by.x="doc_id", by.y="filename", all.x=TRUE)
docs <- docs[!is.na(text) & nchar(text) > 0]

# Standardize gender and interviewer
docs[, gender := fifelse(tolower(predicted_gender) %in% c("female","f","woman","women"), "Female", 
                        fifelse(tolower(predicted_gender) %in% c("male","m","man","men"), "Male", NA_character_))]
docs[, interviewer := fifelse(interviewer == "" | is.na(interviewer), "NULL", interviewer)]

cat(sprintf("Final dataset: %d documents\n", nrow(docs)))
cat("Gender distribution:\n")
print(table(docs$gender, useNA = "always"))
cat("Interviewer distribution:\n")
print(table(docs$interviewer, useNA = "always"))

# Chunking function (same as searchK)
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
  meta_lookup <- unique(docs[, .(filename = doc_id, gender, interviewer, interviewee, rg_number)])
  chunks <- merge(chunks_list, meta_lookup, by="filename", all.x=TRUE)
  stm_input <- chunks
  stm_input[, parent_id := filename]
  stm_input[, doc_id := sprintf("%s#%03d", parent_id, chunk_id)]
} else {
  stm_input <- docs[, .(doc_id, filename = doc_id, rg_number, text, gender, interviewer, interviewee)]
  stm_input[, parent_id := doc_id]
}

# Text preprocessing (same as searchK)
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



# --- Unicode & punctuation normalization ---
suppressPackageStartupMessages(library(stringi))

normalize_for_stm <- function(x) {
  x <- ifelse(is.na(x), "", x)

  # 1) Normalize curly quotes & dashes to ASCII (base R, no deps)
  x <- chartr("\u2018\u2019\u201C\u201D\u2013\u2014", "''\"\"--", x)

  # 2) Remove apostrophes so "don't" -> "dont" (matches stoplist)
  x <- gsub("'", "", x, perl = TRUE)

  # 3) Remove stray leading/trailing hyphens glued to words (-ii, a-)
  x <- gsub("\\b-+|-+\\b", " ", x, perl = TRUE)

  # 4) Keep letters, spaces, and internal hyphens (e.g., anti-semitic)
  x <- gsub("[^\\p{L}\\s-]", " ", x, perl = TRUE)

  # 5) Tidy up: collapse multi-hyphens & whitespace
  x <- gsub("-{2,}", "-", x, perl = TRUE)
  x <- gsub("\\s+", " ", x, perl = TRUE)

  trimws(x)
}


stm_input[, text := normalize_for_stm(text)]


cat(sprintf("After cleaning: %d chunks from %d documents\n", nrow(stm_input), length(unique(stm_input$parent_id))))

# Custom stopwords (oral history fillers + contractions after normalization)
custom_stopwords <- unique(tolower(c(
  # conversational fillers
  "person","really","thing","things","kind","sort",
  "know","like","well","think","said","going","yeah","okay","right","now","just",
  "get","got","went","came","come","one","two","three","time","times","yes","no",

  # transcript boilerplate
  "interview","interviewer","interviewee","narrator","speaker","transcript",
  "tape","side","end","beginning","wwwushmmorg","website","infohometeamcaptionscom",
  "indecipherable","inaudible",

  # contractions after apostrophes removed by normalize_for_stm(), 
  "dont","didnt","doesnt","isnt","arent","wasnt","werent","havent","hasnt","hadnt",
  "wont","wouldnt","cant","couldnt","shouldnt","mustnt","im","ive","ill","id",
  "youre","youve","youll","youd","hes","shes","thats","theres","theyre","weve",
  "wed","well","lets","whats","wheres","whos","hows","its","itd","itll",

  # https://gist.github.com/sebleier/554280 NLTK stopwords:
  "i", "me", "my", "myself", "we", "our", "ours", "ourselves", "you", "your", "yours", "yourself", "yourselves", "he", "him", "his", "himself", "she", "her", "hers", "herself", "it", "its", "itself", "they", "them", "their", "theirs", "themselves", "what", "which", "who", "whom", "this", "that", "these", "those", "am", "is", "are", "was", "were", "be", "been", "being", "have", "has", "had", "having", "do", "does", "did", "doing", "a", "an", "the", "and", "but", "if", "or", "because", "as", "until", "while", "of", "at", "by", "for", "with", "about", "against", "between", "into", "through", "during", "before", "after", "above", "below", "to", "from", "up", "down", "in", "out", "on", "off", "over", "under", "again", "further", "then", "once", "here", "there", "when", "where", "why", "how", "all", "any", "both", "each", "few", "more", "most", "other", "some", "such", "no", "nor", "not", "only", "own", "same", "so", "than", "too", "very", "s", "t", "can", "will", "just", "don", "should", "now"
)))


# Process documents (same as searchK for consistency)
cat("Running textProcessor...\n")
meta_for_stm <- as.data.frame(stm_input[, .(doc_id, parent_id, gender, interviewer, interviewee)])

# Function that takes in a vector of raw texts (in a variety of languages) and performs basic operations.
# This function is essentially a wrapper tm package where various user specified options can be selected.
processed <- textProcessor(
  documents = stm_input$text,
  metadata  = meta_for_stm,
  lowercase = TRUE, removestopwords = TRUE, removenumbers = TRUE,
  removepunctuation = TRUE, stem = FALSE, verbose = TRUE,
  customstopwords = custom_stopwords)
  # use our customed stopwords list for better results. We are expanding this list as we experiment. 


# documents: A list containing the documents in the stm format.
# vocab: Character vector of vocabulary.
# meta: Data frame or matrix containing the user-supplied metadata for the retained documents.
word_threshold <- if (length(processed$documents) < 100) 3 else 5
prep <- prepDocuments(processed$documents, processed$vocab, processed$meta, lower.thresh = word_threshold)

docs_out  <- prep$documents
vocab_out <- prep$vocab
meta_out  <- as.data.table(prep$meta)

cat("Has curly apostrophe left? ",
    any(grepl("\u2019", vocab_out, useBytes = TRUE)), "\n")
cat("Is 'we' in vocab? ", "we" %in% vocab_out, "\n")
grep("^don.?t$", vocab_out, value = TRUE)[1:5]


# Clean up covariates
# Statistical models treat factors as categorical variables
# "These variables can include numeric and factor variables. While including variables of class Dates or other non-numeric, non-factor types will work in stm it may not always work for downstream functions such as estimateEffect." -- stm package description
meta_out[, gender := factor(gender, levels=c("Female","Male"))]
meta_out[, interviewer := factor(interviewer)]

# Remove rows with missing gender (keep interviewer NULL values)
complete_rows <- !is.na(meta_out$gender)
meta_out <- meta_out[complete_rows]
docs_out <- docs_out[complete_rows]

cat(sprintf("Final processed data: %d documents, %d vocabulary terms\n", 
           length(docs_out), length(vocab_out)))
cat("Final gender distribution:\n")
print(table(meta_out$gender, useNA = "always"))
cat("Final interviewer distribution:\n")
print(table(meta_out$interviewer, useNA = "always"))

# ----------- Fit STM with Gender + Interviewer Covariates -----------
cat("Fitting STM model with gender + interviewer covariates...\n")
set.seed(SEED)

# Estimation of the Structural Topic Model using semi-collapsed variational EM. The function takes sparse representation of a document-term matrix, an integer number of topics, and covariates and returns fitted model parameters. Covariates can be used in the prior for topic prevalence, in the prior for topical content or both. See an overview of functions in the package here: stm-package

# ---- Important note on initialization from STM pacakge ----
# The argument init.type allows the user to specify an initialization method. The default choice, "Spectral", provides a deterministic initialization using the spectral algorithm given in Arora et al 2014. See Roberts, Stewart and Tingley (2016) for details and a comparison of different approaches. Particularly when the number of documents is relatively large we highly recommend the Spectral algorithm which often performs extremely well. Note that the random seed plays no role in the spectral initialization as it is completely deterministic (unless using the K=0 or random projection settings). 
# The other option "LDA" which uses a few passes of a Gibbs sampler is perfectly reproducible across machines as long as the seed is set.

# Use prevalence covariates for both, didnt' use content covariate (STM limitation) to have FREX/PROB/LIFT/SCORE in the standard output

fit <- stm(documents = docs_out,
           vocab     = vocab_out,
           K         = K,
           data      = meta_out,
           prevalence = ~ gender + interviewer,  # How topics vary by gender and interviewer
           
           init.type = "LDA",
           max.em.its = 200,
           verbose = TRUE,
           seed = SEED)

cat("STM model fitting completed!\n")
# write a single R object to a file, and to restore it.
saveRDS(fit, file.path(OUT, "csv", sprintf("stm_model_K%02d.rds", K))) 

# ----------- Export: document-topic proportions -----------
cat("Extracting and saving results...\n")

# Get document-topic matrix (theta): Number of Documents by Number of Topics matrix of topic proportions.
theta <- data.table(fit$theta)
theta[, doc_id := meta_out$doc_id]
theta_long <- melt(theta, id.vars="doc_id", variable.name="topic", value.name="gamma")
theta_long <- as.data.table(theta_long)  # Ensure it's a data.table
theta_long[, topic := as.integer(gsub("V","", topic))]

# Add metadata back
theta_meta <- merge(theta_long, meta_out[, .(doc_id, parent_id, gender, interviewer)], by="doc_id")

# Aggregate chunks back to documents if needed
if (USE_CHUNKS) {
  theta_doc <- theta_meta[, .(gamma = mean(gamma, na.rm = TRUE)), by=.(parent_id, topic, gender, interviewer)]
  setnames(theta_doc, "parent_id", "doc_id")
} else {
  theta_doc <- theta_meta[, .(gamma = mean(gamma, na.rm = TRUE)), by=.(doc_id, topic, gender, interviewer)]
}

# Wide format for document topics
theta_wide <- dcast(theta_doc, doc_id + gender + interviewer ~ paste0("topic_", topic), value.var = "gamma", fill = 0)

# Save document-topic data
fwrite(theta_doc,  file.path(OUT, "csv", "document_topics_long.csv"))
fwrite(theta_wide, file.path(OUT, "csv", "document_topics_wide.csv"))

# ----------- Export: Topic Labels -----------
n_words_per_topic <- 15
labs <- labelTopics(fit, n = n_words_per_topic)

# Create topic labels table with proper handling
safe_paste <- function(x, default = "no_words") {
  if (is.null(x) || length(x) == 0 || all(is.na(x))) {
    return(default)
  }
  # Remove any NA values and convert to character
  x_clean <- as.character(x[!is.na(x)])
  if (length(x_clean) == 0) {
    return(default)
  }
  return(paste(x_clean, collapse = ", "))
}

# Debug: Print structure of labs and model
cat("DEBUG: STM model and labelTopics structure:\n")
cat("Number of topics K:", K, "\n")
cat("Vocabulary size:", length(vocab_out), "\n")
cat("Sample vocabulary:", paste(head(vocab_out, 10), collapse=", "), "\n")

# Check model structure
cat("STM model beta dimensions:", dim(fit$beta$logbeta[[1]]), "\n")

# Check labelTopics result
cat("labelTopics result structure:\n")
str(labs, max.level = 2)

if (!is.null(labs$frex)) {
  cat("FREX list length:", length(labs$frex), "\n")
  if (length(labs$frex) > 0 && length(labs$frex[[1]]) > 0) {
    cat("First topic FREX words:", paste(labs$frex[[1]], collapse=", "), "\n")
  } else {
    cat("FREX list is empty or has no words\n")
  }
} else {
  cat("FREX is NULL\n")
}

# Try alternative approach
cat("Trying alternative topic word extraction...\n")
tryCatch({
  # Get top words directly from beta matrix
  beta_matrix <- exp(fit$beta$logbeta[[1]])  # Convert log probabilities to probabilities
  for (i in 1:min(3, K)) {  # Check first 3 topics
    top_indices <- order(beta_matrix[i,], decreasing = TRUE)[1:10]
    top_words <- vocab_out[top_indices]
    cat(sprintf("Topic %d direct extraction: %s\n", i, paste(top_words, collapse=", ")))
  }
}, error = function(e) {
  cat("Error in direct extraction:", e$message, "\n")
})

# Works when labelTopics returns prob/frex/lift/score matrices (no content covariate)
to_row_paste <- function(M) {
  # M is a K x n char matrix
  apply(M, 1, function(x) paste(x[!is.na(x) & nzchar(x)], collapse = ", "))
}

topic_labels <- data.table(
  topic       = labs$topicnums,
  prob_words  = to_row_paste(labs$prob),
  frex_words  = to_row_paste(labs$frex),
  lift_words  = to_row_paste(labs$lift),
  score_words = to_row_paste(labs$score)
)

# Peek
for (i in seq_len(K)) {
  cat(sprintf("Topic %d FREX: %s\n", i, topic_labels$frex_words[i]))
}

fwrite(topic_labels, file.path(OUT, "csv", "topic_labels.csv"))




# ----------- Estimate Effects (Gender + Interviewer) -----------
cat("Estimating covariate effects...\n")

# Prevalence effects (convert data.table to data.frame for estimateEffect)
ee_prev <- estimateEffect(1:K ~ gender + interviewer, fit, meta = as.data.frame(meta_out), uncertainty = "Global")

# Extract gender effects
gender_effects <- data.table()
for (k in 1:K) {
  tryCatch({
    est_summary <- summary(ee_prev, topics = k)
    coefs <- est_summary$tables[[1]]
    if ("genderMale" %in% rownames(coefs)) {
      gender_effects <- rbind(gender_effects, data.table(
        topic = k,
        gender_effect = -coefs["genderMale", "Estimate"],  # Female - Male
        gender_se = coefs["genderMale", "Std. Error"],
        gender_p = coefs["genderMale", "Pr(>|t|)"]
      ))
    }
  }, error = function(e) {
    cat(sprintf("Error in topic %d gender effect: %s\n", k, e$message))
  })
}

# Extract interviewer effects (compared to first interviewer)
interviewer_levels <- levels(meta_out$interviewer)
interviewer_effects <- data.table()

for (k in 1:K) {
  tryCatch({
    est_summary <- summary(ee_prev, topics = k)
    coefs <- est_summary$tables[[1]]
    for (int_level in interviewer_levels[-1]) {  # Skip baseline
      int_coef <- paste0("interviewer", int_level)
      if (int_coef %in% rownames(coefs)) {
        interviewer_effects <- rbind(interviewer_effects, data.table(
          topic = k,
          interviewer_baseline = interviewer_levels[1],
          interviewer_comparison = int_level,
          interviewer_effect = coefs[int_coef, "Estimate"],
          interviewer_se = coefs[int_coef, "Std. Error"],
          interviewer_p = coefs[int_coef, "Pr(>|t|)"]
        ))
      }
    }
  }, error = function(e) {
    cat(sprintf("Error in topic %d interviewer effect: %s\n", k, e$message))
  })
}

# Save effects
fwrite(gender_effects, file.path(OUT, "csv", "gender_effects.csv"))
fwrite(interviewer_effects, file.path(OUT, "csv", "interviewer_effects.csv"))

# ----------- Create Visualizations -----------
cat("Creating visualizations...\n")

# 1. Topic Distribution by Gender
topic_by_gender <- theta_doc[, .(avg_gamma = mean(gamma)), by = .(topic, gender)]
topic_by_gender[, topic_label := paste0("Topic ", topic)]

p1 <- ggplot(topic_by_gender, aes(x = topic_label, y = avg_gamma, fill = gender)) +
  geom_bar(stat = "identity", position = "dodge") +
  labs(title = "Topic Distribution by Gender",
       subtitle = "Average topic prevalence across gender",
       x = "Topic", y = "Average Topic Prevalence") +
  theme_minimal() +
  theme(axis.text.x = element_text(angle = 45, hjust = 1)) +
  scale_fill_manual(values = c("Female" = "#E69F00", "Male" = "#56B4E9"))

ggsave(file.path(OUT, "plots", "topics_by_gender.png"), p1, width = 12, height = 6, dpi = 300)

# 2. Topic Distribution by Interviewer
topic_by_interviewer <- theta_doc[, .(avg_gamma = mean(gamma)), by = .(topic, interviewer)]
topic_by_interviewer[, topic_label := paste0("Topic ", topic)]

p2 <- ggplot(topic_by_interviewer, aes(x = topic_label, y = avg_gamma, fill = interviewer)) +
  geom_bar(stat = "identity", position = "dodge") +
  labs(title = "Topic Distribution by Interviewer",
       subtitle = "Average topic prevalence across interviewers",
       x = "Topic", y = "Average Topic Prevalence") +
  theme_minimal() +
  theme(axis.text.x = element_text(angle = 45, hjust = 1),
        legend.position = "bottom") +
  guides(fill = guide_legend(ncol = 3))

ggsave(file.path(OUT, "plots", "topics_by_interviewer.png"), p2, width = 14, height = 8, dpi = 300)

# 3. Stacked Bar Chart: Gender Distribution by Interviewer with Topic Prevalence
# First, get document counts by interviewer and gender
doc_counts <- theta_doc[, .N, by = .(interviewer, gender)]
doc_counts_wide <- dcast(doc_counts, interviewer ~ gender, value.var = "N", fill = 0)

# Get top topic for each interviewer-gender combination
top_topics <- theta_doc[, .SD[which.max(gamma)], by = .(interviewer, gender)]
top_topics[, topic_label := paste0("Topic ", topic)]

# Create the visualization data
interviewer_gender_topics <- merge(doc_counts, top_topics[, .(interviewer, gender, topic, topic_label)], 
                                  by = c("interviewer", "gender"))

p3 <- ggplot(interviewer_gender_topics, aes(x = interviewer, y = N, fill = paste(gender, topic_label))) +
  geom_bar(stat = "identity", position = "stack") +
  labs(title = "Gender Distribution by Interviewer with Dominant Topics",
       subtitle = "Height = number of interviewees, Colors = gender + dominant topic",
       x = "Interviewer", y = "Number of Interviewees",
       fill = "Gender + Dominant Topic") +
  theme_minimal() +
  theme(axis.text.x = element_text(angle = 45, hjust = 1),
        legend.position = "right") +
  scale_fill_discrete(name = "Gender + Topic")

ggsave(file.path(OUT, "plots", "interviewer_gender_stacked.png"), p3, width = 14, height = 8, dpi = 300)


# 4. Topic Correlation Analysis
cat("Computing topic correlations...\\n")

# Compute correlations using both methods
simple_topic_corr <- topicCorr(fit, method = "simple", cutoff = 0.03, verbose = TRUE)
huge_topic_corr <- topicCorr(fit, method = "huge", cutoff = 0.03, verbose = TRUE)

# Extract all components from S4 topicCorr objects
# topicCorr objects contain: $cor (correlations), $posadj (positive adjacency), $poscor (positive correlations)

# Simple method results
simple_cor_dt <- as.data.table(simple_topic_corr$cor, keep.rownames = "topic")
simple_posadj_dt <- as.data.table(simple_topic_corr$posadj, keep.rownames = "topic") 
simple_poscor_dt <- as.data.table(simple_topic_corr$poscor, keep.rownames = "topic")

# Huge method results  
huge_cor_dt <- as.data.table(huge_topic_corr$cor, keep.rownames = "topic")
huge_posadj_dt <- as.data.table(huge_topic_corr$posadj, keep.rownames = "topic")
huge_poscor_dt <- as.data.table(huge_topic_corr$poscor, keep.rownames = "topic")

# Save all correlation components
fwrite(simple_cor_dt, file.path(OUT, "csv", "simple_correlations.csv"))
fwrite(simple_posadj_dt, file.path(OUT, "csv", "simple_positive_adjacency.csv")) 
fwrite(simple_poscor_dt, file.path(OUT, "csv", "simple_positive_correlations.csv"))

fwrite(huge_cor_dt, file.path(OUT, "csv", "huge_correlations.csv"))
fwrite(huge_posadj_dt, file.path(OUT, "csv", "huge_positive_adjacency.csv"))
fwrite(huge_poscor_dt, file.path(OUT, "csv", "huge_positive_correlations.csv"))

# Create network plots using PDF device (ggsave doesn't work with network plots)
pdf(file.path(OUT, "plots", "simple_topic_correlations.pdf"), width = 12, height = 10)
plot(simple_topic_corr,
     topics = NULL,
     vlabels = NULL,
     layout = NULL,
     vertex.color = "lightgreen",
     vertex.label.cex = 0.75,
     vertex.label.color = "black",
     vertex.size = 15,
     main = "Simple Topic Correlation Network")
dev.off()

pdf(file.path(OUT, "plots", "huge_topic_correlations.pdf"), width = 12, height = 10) 
plot(huge_topic_corr,
     topics = NULL,
     vlabels = NULL,
     layout = NULL,
     vertex.color = "lightcoral",
     vertex.label.cex = 0.75,
     vertex.label.color = "black", 
     vertex.size = 15,
     main = "Huge Topic Correlation Network")
dev.off()

cat("Topic correlation networks saved as PDF files\\n")

# ----------- Summary Statistics -----------
cat("Creating summary statistics...\n")

# Document-level summaries
doc_summary <- theta_doc[, .(
  total_documents = length(unique(doc_id)),
  avg_topic_diversity = mean(1 - gamma^2),  # Simpson's diversity index
  max_topic_prevalence = max(gamma)
), by = .(gender, interviewer)]

fwrite(doc_summary, file.path(OUT, "csv", "document_summary_stats.csv"))

# Topic-level summaries
topic_summary <- topic_by_gender[, .(
  gender_difference = avg_gamma[gender == "Female"] - avg_gamma[gender == "Male"],
  female_prevalence = avg_gamma[gender == "Female"],
  male_prevalence = avg_gamma[gender == "Male"]
), by = topic]

# Add topic labels
topic_summary <- merge(topic_summary, topic_labels[, .(topic, frex_words)], by = "topic")
# Sort by absolute gender difference (descending)
topic_summary[, abs_gender_diff := abs(gender_difference)]
setorder(topic_summary, -abs_gender_diff)
topic_summary[, abs_gender_diff := NULL]  # Remove helper column

fwrite(topic_summary, file.path(OUT, "csv", "topic_gender_comparison.csv"))

cat("Analysis complete!\n")
cat("Generated files:\n")
cat("- outputs/csv/document_topics_long.csv\n")
cat("- outputs/csv/document_topics_wide.csv\n") 
cat("- outputs/csv/topic_labels.csv\n")
cat("- outputs/csv/gender_effects.csv\n")
cat("- outputs/csv/interviewer_effects.csv\n")
cat("- outputs/plots/topics_by_gender.png\n")
cat("- outputs/plots/topics_by_interviewer.png\n")
cat("- outputs/plots/interviewer_gender_stacked.png\n")

