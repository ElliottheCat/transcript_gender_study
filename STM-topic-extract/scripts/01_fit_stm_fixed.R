# ---- Libraries ----
pkgs <- c("stm","quanteda","readtext","data.table","lubridate","ggplot2")
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

K          <- 30          # topics count
CHUNK_TOKS <- 700          # chunk the document into smaller texts ≈ 400–800 works well
USE_CHUNKS <- TRUE         # set FALSE to turn off segmentation. We use this to avoid overfitting topics and take into account the local context on long documents.


# ---- Read metadata ----
cat("Reading metadata...\n")
meta <- fread(META_PATH)
cat(sprintf("Loaded %d metadata records\n", nrow(meta)))

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
# Remove empty or NA text
initial_rows <- nrow(stm_input)  # Fix: define initial_rows before using it
stm_input <- stm_input[nchar(text) > 0 & !is.na(text)]
cat(sprintf("Removed %d empty/NA texts, %d remaining\n", initial_rows - nrow(stm_input), nrow(stm_input)))


cat("Running textProcessor (this may take several minutes for large datasets)...\n")
# Process text: tokenize, remove stopwords, punctuation, etc.
# only removes very common function words like "the", "and", etc.
# Does not stem words, as we want to keep the original form for labeling. Oral histories often use specific tenses/forms that carry meaning, stemming makes output harder to interpret for researchers. (e.g. Loses important distinctions: "children" vs "childhood")
processed <- textProcessor(
  documents = stm_input$text,
  metadata  = stm_input[, .(doc_id, parent_id, gender, year, interviewee)],
  lowercase = TRUE, removestopwords = TRUE, removenumbers = TRUE,
  removepunctuation = TRUE, stem = FALSE, verbose = TRUE)

cat("Preparing documents (removing rare words)...\n")
# removes very rare words that might confuse the topic model (like typos or very specific names)
prep <- prepDocuments(processed$documents, processed$vocab, processed$meta, lower.thresh = 5)  # drop very rare terms

docs_out  <- prep$documents
vocab_out <- prep$vocab
meta_out  <- as.data.table(prep$meta)

# Make sure gender is a factor with two levels
meta_out[, gender := factor(gender, levels=c("Female","Male"))]

# ---- Fit STM (prevalence + content) ----
cat("Fitting STM model...\n")
cat(sprintf("Model parameters: K=%d topics, %d documents, %d vocabulary terms\n", K, length(docs_out), length(vocab_out)))

# prevalence: allows gender + smooth(year) to change topic proportions
# content: allows wording to vary by gender
form_prev <- ~ gender + s(year, df=5)  # drop s(year) if many NAs
form_cont <- ~ gender                  # only *one* content covariate allowed

stm_fit <- stm(documents = docs_out,
               vocab      = vocab_out,
               K          = K,
               prevalence = form_prev,
               content    = form_cont,
               data       = meta_out,
               max.em.its = 150,
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
  theta_doc <- theta[, .(gamma = weighted.mean(gamma, w = 1)), by=.(parent_id, topic, gender, year)]
  setnames(theta_doc, "parent_id", "doc_id")
} else {
  theta_doc <- theta[, .(gamma = mean(gamma)), by=.(doc_id, topic, gender, year)]
}

# Save per-document topic proportions (wide & long)
dir.create("outputs", showWarnings = FALSE)
dir.create("outputs/csv", showWarnings = FALSE)
dir.create("outputs/plots", showWarnings = FALSE)

theta_wide <- dcast(theta_doc, doc_id + gender + year ~ paste0("topic_", topic), value.var = "gamma", fill = 0)
fwrite(theta_doc,  file = sprintf("outputs/csv/doc_topic_long_k%02d.csv", K))
fwrite(theta_wide, file = sprintf("outputs/csv/doc_topic_wide_k%02d.csv", K))

# ---- Topic labeling (coherence/exclusivity + frex/lift/score) ----
labs <- labelTopics(stm_fit, n = 15)
topic_labels <- data.table(
  topic = seq_len(K),
  frex  = sapply(labs$frex,  function(x) paste(x, collapse=", ")),
  lift  = sapply(labs$lift,  function(x) paste(x, collapse=", ")),
  score = sapply(labs$score, function(x) paste(x, collapse=", ")),
  prob  = sapply(labs$prob,  function(x) paste(x, collapse=", "))
)
fwrite(topic_labels, file = sprintf("outputs/csv/topic_labels_k%02d.csv", K))

# ---- Gender effect on topic prevalence (with uncertainty) ----
# "Female - Male" difference in expected topic proportion
eff <- estimateEffect(1:K ~ gender + s(year, df=5),
                      stmobj = stm_fit, metadata = meta_out, uncertainty = "Global")

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
# SAGE-style labels by group ("perspectives")
sage <- sageLabels(stm_fit, n = 15)
# Convert to a tidy table
# sage$covar is a list: one element per content group (Female, Male)
get_tbl <- function(covar_list, group_name) {
  data.table(
    topic   = seq_len(K),
    words   = sapply(covar_list, function(x) paste(x, collapse = ", ")),
    group   = group_name
  )
}
content_tbl <- rbindlist(list(
  get_tbl(sage$covar$gender$Female, "Female"),
  get_tbl(sage$covar$gender$Male,   "Male")
), use.names=TRUE, fill=TRUE)
fwrite(content_tbl, file = sprintf("outputs/csv/topic_content_words_by_gender_k%02d.csv", K))

# ---- Convenience: top-3 topics per document (for spot checks) ----
top3 <- theta_doc[order(doc_id, -gamma), .SD[1:3], by=doc_id]
fwrite(top3, file = sprintf("outputs/csv/doc_top3_topics_k%02d.csv", K))

# ---- Optional sanity plots ----
pdf(sprintf("outputs/plots/quicklook_k%02d.pdf", K), width=9, height=7)
plot(stm_fit, type="summary", n=10)
# topic correlations (prevalence scale)
tc <- topicCorr(stm_fit)
plot(tc)
dev.off()

message("Done. Artifacts in outputs/csv and outputs/plots . Model saved in models/.")