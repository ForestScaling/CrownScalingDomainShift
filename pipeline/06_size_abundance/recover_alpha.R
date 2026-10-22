# =============================================================================
# recover_alpha.R
# Bayesian recovery of alpha and N_tot per 1 ha cell with ScalingFromSky,
# one chunk of cells per Slurm array task. Replaces RecoverAlpha.R,
# RecoverAlphaParallel.R, and RecoverAlphaParallel_weinstein.R.
#
# Fixes relative to RecoverAlphaParallel.R:
#   - chunk size read from its own argument (was args[1], the task id, so the
#     9-task array covered only 45 cells: 1, 3-4, 7-9, ..., 73-81)
#   - N_tot posterior written to _trees.csv (both files previously held alpha)
#   - four-tile test subset removed
#   - missing-LAI check uses nrow() (length() of a data frame counts columns,
#     so the check never fired)
#   - minimum crowns per cell enforced from config (was commented out)
#   - one script for every product; the Weinstein column workaround is gone
#     because crown_metrics.R now writes identical columns for all products
#   - skipped cells and the reason are written out, so coverage is reportable
#
# Prior: LAI-informed, mean/sd from products.yaml (Eichenwald et al. 2025).
#
# Usage:
#   Rscript pipeline/06_size_abundance/recover_alpha.R --product NAIP30 --site HARV --task-id 1
#   Rscript pipeline/06_size_abundance/recover_alpha.R --product NAIP30 --site HARV --count-chunks
# Output: {scaling_root}/Results/Parameters/{site}/{product}/Chunks/
#           {site}_{product}_chunk{NNN}_alpha.csv | _trees.csv | _skipped.csv
# =============================================================================
cs_repo_root <- function() {
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) normalizePath(file.path(dirname(f), "..", "..")) else getwd()
}
source(file.path(cs_repo_root(), "src", "R", "utils.R"))
cs_osc_env()

args <- cs_args(list(product = "REQUIRED", site = "REQUIRED", task_id = NA,
                     chunk_size = NA, ncores = "1", count_chunks = FALSE))
cfg  <- cs_config(cs_repo_root())
sa   <- cfg$size_abundance
chunk_size <- if (is.na(args$chunk_size)) sa$chunk_size else as.integer(args$chunk_size)
ncores <- as.integer(args$ncores)
options(mc.cores = ncores)

suppressPackageStartupMessages({
  library(data.table)
  library(rstan)
  library(ScalingFromSky)
})

# ---- Data -------------------------------------------------------------------
files <- list.files(cs_spath(cfg, "crown_datasets_dir"),
                    pattern = paste0("^", args$site, "_", args$product, "_trees_.*\\.csv$"),
                    full.names = TRUE)
if (!length(files)) stop("No crown datasets for ", args$site, " ", args$product)
df <- rbindlist(lapply(files, fread), fill = TRUE)
df <- df[!is.na(grid_id) & is.finite(DBH)]

grid_list <- sort(unique(df$grid_id))
n_chunks  <- ceiling(length(grid_list) / chunk_size)
if (isTRUE(args$count_chunks)) { cat(n_chunks, "\n"); quit(save = "no") }

task <- as.integer(args$task_id)
if (is.na(task) || task < 1 || task > n_chunks) stop("--task-id must be 1..", n_chunks)
my_grids <- grid_list[((task - 1) * chunk_size + 1):min(task * chunk_size, length(grid_list))]
cat(args$product, args$site, "| chunk", task, "of", n_chunks, "|", length(my_grids), "cells of",
    length(grid_list), "\n")

lai_df <- fread(file.path(cs_spath(cfg, "lai_dir"), paste0(args$site, "_gridLAI.csv")))
set.seed(sa$seed + task)

# ---- Fit each cell ----------------------------------------------------------
alpha_out <- list(); trees_out <- list(); skipped <- list()
skip <- function(g, n, why) {
  cat("  grid", g, "skipped:", why, "\n")
  skipped[[length(skipped) + 1]] <<- data.frame(grid = g, n_crowns = n, reason = why)
}

for (g in my_grids) {
  dbh <- df[grid_id == g, DBH]
  n <- length(dbh)
  if (n < sa$min_crowns_per_cell) { skip(g, n, "too_few_crowns"); next }
  lai <- lai_df[grid_id == g]
  if (nrow(lai) == 0 || !is.finite(lai$lai_val[1])) { skip(g, n, "no_lai"); next }
  cat("grid", g, "| crowns", n, "| DBH", sprintf("%.1f-%.1f cm", min(dbh), max(dbh)), "\n")

  res <- tryCatch({
    kde   <- get_potential_breakpoint_and_kde(dbh)
    trunc <- determine_truncation_and_filter(kde)
    fit   <- fit_alpha_model(bayesian_data = trunc$bayesian_data,
                             breakpoint = trunc$final_breakpoint,
                             LAI = lai$lai_val[1],
                             prior_mean = sa$prior_mean, prior_sd = sa$prior_sd)
    trees <- estimate_total_trees(alpha_model_output = fit)
    list(fit = fit, trees = trees, breakpoint = trunc$final_breakpoint)
  }, error = function(e) { skip(g, n, paste("model_error:", conditionMessage(e))); NULL })
  if (is.null(res)) next

  a <- as.data.frame(res$fit$posterior_summary);   a$grid <- g; a$n_crowns <- n
  t <- as.data.frame(res$trees$posterior_summary); t$grid <- g; t$n_crowns <- n
  a$breakpoint <- res$breakpoint   # as returned by ScalingFromSky (same scale as its KDE)
  alpha_out[[length(alpha_out) + 1]] <- a
  trees_out[[length(trees_out) + 1]] <- t
}

# ---- Write ------------------------------------------------------------------
out_dir <- cs_spath(cfg, "parameters_dir", site = args$site, product = args$product)
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
stem <- file.path(out_dir, sprintf("%s_%s_chunk%03d", args$site, args$product, task))
tag  <- function(x) {
  if (!length(x)) return(data.table(grid = integer()))
  x <- rbindlist(x, fill = TRUE)
  x[, `:=`(site = args$site, product = args$product)]
}
fwrite(tag(alpha_out), paste0(stem, "_alpha.csv"))
fwrite(tag(trees_out), paste0(stem, "_trees.csv"))
fwrite(if (length(skipped)) rbindlist(skipped) else data.table(grid = integer(), n_crowns = integer(), reason = character()),
       paste0(stem, "_skipped.csv"))
cat("Fitted", length(alpha_out), "| skipped", length(skipped), "\n")
