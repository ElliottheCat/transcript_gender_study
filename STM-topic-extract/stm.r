#!/usr/bin/env Rscript
# /srv/ushmm-topics/stm_pipeline.R

suppressPackageStartupMessages({
  library(readtext)
  library(quanteda)
  library(SnowballC)
  library(data.table)
  library(stm)
})

# ----------- Config -----------
WORKDIR <- "STM-topic-extract"
RAW     <- file.path(WORKDIR, "raw")
OUT     <- file.path(WORKDIR, "outputs")
K       <- 30           # set your chosen K; or run searchK() first (below)
SEED    <- 42
dir.create(OUT, showWarnings = FALSE, recursive = TRUE)

# ----------- Load texts -----------
# Collect all .txt files
rt <- readtext::readtext(file.path(RAW, "*.txt"), encoding = "UTF-8")
# make stable doc_ids from filenames
rt$doc_id <- tools::file_path_sans_ext(basename(rt$doc_id))

# ----------- Light, respectful cleaning -----------
# 1) Drop leading Q:/A:/Question:/Answer: labels at line starts (case-insensitive)
drop_qa <- function(x) {
  x <- gsub("(?m)^\\s*(?:Q(?:uestion)?|A(?:nswer)?)\\s*[:.]+\\s*", "", x, perl = TRUE)
  x
}
rt$text <- vapply(rt$text, drop_qa, "", USE.NAMES = FALSE)

# (Optional) If you have many speaker-name “Name:” lines and short line breaks,
# you could collapse single linebreaks into spaces only when there are a lot of colons,
# but we keep it conservative here to avoid harming narrative structure.

# ----------- Bring in metadata (optional) -----------
meta <- data.frame(doc_id = rt$doc_id, stringsAsFactors = FALSE)
metafile <- file.path(WORKDIR, "metadata.csv")
if (file.exists(metafile)) {
  m <- data.table::fread(metafile, encoding = "UTF-8")
  # ensure doc_id is character
  m[, doc_id := as.character(doc_id)]
  meta <- merge(meta, m, by = "doc_id", all.x = TRUE, sort = FALSE)
}
# standardize a couple of optional covariates
if (!"gender" %in% names(meta)) meta$gender <- factor("unknown")
meta$gender <- factor(meta$gender)  # {female,male,unknown,...}
if (!"year"   %in% names(meta)) meta$year <- NA_integer_

# ----------- Tokenize → DFM -----------
corp <- corpus(rt, text_field = "text")
toks <- tokens(
  corp,
  remove_punct   = TRUE,
  remove_numbers = TRUE
)
toks <- tokens_tolower(toks)

# remove common stopwords in multiple relevant languages
sw <- unique(c(stopwords("en"), stopwords("de"), stopwords("pl"), stopwords("hu")))
toks <- tokens_remove(toks, sw)

# light stemming to reduce sparsity, but keep meaning
toks <- tokens_wordstem(toks, language = "en")  # acceptable for English-heavy corpora

dfm  <- dfm(toks)
# Trim extremely rare terms to stabilize estimation (tweak as needed)
dfm  <- dfm_trim(dfm, min_docfreq = 5, min_termfreq = 20)

# Convert to stm format
out <- convert(dfm, to = "stm")
docs  <- out$documents
vocab <- out$vocab
meta  <- meta[match(names(dfm), meta$doc_id), , drop = FALSE]

# ----------- (Recommended) pick K with searchK -----------
# Run once, inspect, then set K above. Comment out after you decide K.
# set.seed(SEED)
# kgrid <- c(15, 20, 25, 30, 35, 40)
# sk <- searchK(docs, vocab, K = kgrid,
#               data = meta,
#               prevalence = ~ gender + s(year))
# saveRDS(sk, file.path(OUT, "searchK.rds"))

# ----------- Fit STM -----------
set.seed(SEED)
# Use prevalence; add content=~gender if you explicitly want wording to vary by gender.
fit <- stm(documents = docs,
           vocab     = vocab,
           K         = K,
           data      = meta,
           prevalence= ~ gender + s(year),
           init.type = "Spectral",
           seed      = SEED)

saveRDS(fit, file.path(OUT, sprintf("model_K%02d.rds", K)))

# ----------- Export: document-topic proportions -----------
gamma <- as.data.frame(fit$theta)
colnames(gamma) <- sprintf("topic_%02d", seq_len(K))
gamma$doc_id    <- meta$doc_id
gamma$top_topic <- max.col(gamma[, sprintf("topic_%02d", 1:K)], ties.method = "first")
gamma$top_gamma <- apply(gamma[, sprintf("topic_%02d", 1:K)], 1, max)

write.csv(gamma,
          file = file.path(OUT, "document_topics.csv"),
          row.names = FALSE)

# ----------- Export: top terms per topic -----------
labs <- labelTopics(fit, n = 15)
# labs$prob and labs$frex each list top words per topic; use FREX for interpretability
top_terms <- data.table::data.table(
  topic      = rep(seq_len(K), each = length(labs$frex[[1]])),
  rank       = rep(seq_along(labs$frex[[1]]), times = K),
  term_frex  = unlist(labs$frex, use.names = FALSE),
  term_prob  = unlist(labs$prob, use.names = FALSE)
)
data.table::fwrite(top_terms, file.path(OUT, "topic_top_terms.csv"))

# ----------- (Optional) prevalence effects (e.g., gender) -----------
if ("gender" %in% names(meta)) {
  ee <- estimateEffect(1:K ~ gender + s(year),
                       fit, meta = meta, uncertainty = "Global")
  # summarize difference vs a baseline (first level of gender)
  glev <- levels(meta$gender)
  if (length(glev) >= 2) {
    base <- glev[1]
    # model.matrix contrast: we’ll predict means by level then difference
    pred <- lapply(glev, function(g) {
      thedata <- within(meta, gender <- factor(g, levels = glev))
      sapply(1:K, function(k) {
        # posterior expected prevalence for this topic at this gender (year median)
        ymed <- if (all(is.na(meta$year))) 0 else median(meta$year, na.rm = TRUE)
        summary(ee, topics = k, covariate = "gender")$tables[[1]][g, "est"]
      })
    })
    eff <- data.table::data.table(
      topic = 1:K,
      # difference (second level minus baseline), if available
      diff_gender_vs_base = if (length(glev) >= 2) (pred[[2]] - pred[[1]]) else NA_real_
    )
    data.table::fwrite(eff, file.path(OUT, "topic_prevalence_effects.csv"))
  }
}

cat("Done. CSVs written to: ", OUT, "\n")

