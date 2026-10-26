# =============================================================================
# summarize_alpha.R
# Combine recover_alpha.R chunks for every product x height source at a site,
# write per-cell tables and 1 ha GeoTIFFs, report coverage (including missing
# array tasks), and validate each set against the reference (NEON10, NEON CHM).
# Run it while alpha jobs are still going to see progress and failed chunks.
#
# Usage:  Rscript pipeline/06_size_abundance/summarize_alpha.R --site HARV [--reference NEON10]
#
# Data outputs  ({scaling_root}/Results/Parameters/{site}/{set}/):
#   {site}_{set}_parameters.csv   one row per cell: alpha and N_tot posterior summaries
#   {site}_{set}_parameters.tif   EPSG:5070, 100 m; layers alpha_mean, alpha_sd,
#                                 ntot_mean, ntot_sd, n_crowns, converged
# Report outputs (repo):
#   reports/tables/alpha_{site}_coverage.csv     cells, chunks found/missing, skips, convergence
#   reports/tables/alpha_{site}_validation.csv   R2, RMSE, MAE, bias vs reference (alpha, N_tot)
#   reports/figures/alpha_{site}/                1:1 heatmaps, maps, difference maps
#   reports/alpha_{site}_report.md
# =============================================================================
cs_repo_root <- function() {
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) normalizePath(file.path(dirname(f), "..", "..")) else getwd()
}
source(file.path(cs_repo_root(), "src", "R", "utils.R"))
cs_osc_env()
suppressPackageStartupMessages({ library(data.table); library(ggplot2) })

args <- cs_args(list(site = "REQUIRED", reference = "NEON10"))
cfg  <- cs_config(cs_repo_root())
site <- args$site; ref <- args$reference
sa   <- cfg$size_abundance
max_rhat <- sa$max_rhat
fig_dir <- dirname(cs_rpath(cfg, "figures", paste0("alpha_", site), "x"))
dir.create(fig_dir, showWarnings = FALSE, recursive = TRUE)
tab <- function(name) cs_rpath(cfg, "tables", paste0("alpha_", site, "_", name, ".csv"))
th  <- theme_bw(base_size = 11)
save_fig <- function(p, name, w = 9, h = 5) ggsave(file.path(fig_dir, name), p, width = w, height = h, dpi = 200)

param_root <- dirname(dirname(cs_spath(cfg, "parameters_dir", site = site, product = "x")))
sets <- sort(basename(list.dirs(param_root, recursive = FALSE)))
sets <- sets[vapply(sets, function(s) dir.exists(file.path(param_root, s, "Chunks")), logical(1))]
if (!length(sets)) stop("No parameter chunks under ", param_root)

pick_var <- function(d, wanted, what) {
  v <- unique(d$variable)
  if (!is.null(wanted)) { if (!wanted %in% v) stop(what, " variable '", wanted, "' not in: ", paste(v, collapse = ", ")); return(wanted) }
  if (length(v) != 1) stop("Several ", what, " variables (", paste(v, collapse = ", "),
                           "); set size_abundance.", what, "_variable in config/products.yaml")
  v
}

template <- cs_grid_template(cfg, site)
grid <- cs_read_grid(cfg, site)
cells_all <- list(); coverage <- list()

for (s in sets) {
  chunk_dir <- file.path(param_root, s, "Chunks")
  read_chunks <- function(kind) {
    f <- list.files(chunk_dir, pattern = paste0("_chunk[0-9]+_", kind, "\\.csv$"), full.names = TRUE)
    if (!length(f)) return(list(files = f, data = data.table()))
    list(files = f, data = rbindlist(lapply(f, fread), fill = TRUE))
  }
  A <- read_chunks("alpha"); Tt <- read_chunks("trees"); S <- read_chunks("skipped")
  chunk_ids <- sort(as.integer(sub(".*_chunk([0-9]+)_alpha\\.csv$", "\\1", A$files)))

  # Expected chunks: same grid list recover_alpha.R builds from the crown datasets
  label_files <- list.files(cs_spath(cfg, "crown_datasets_dir"),
                            pattern = paste0("^", site, "_", s, "_trees_.*\\.csv$"), full.names = TRUE)
  n_cells_data <- if (length(label_files))
    uniqueN(rbindlist(lapply(label_files, fread, select = c("grid_id", "DBH")))[!is.na(grid_id) & is.finite(DBH), grid_id])
    else NA_integer_
  expected <- if (is.na(n_cells_data)) NA_integer_ else ceiling(n_cells_data / sa$chunk_size)
  missing <- if (is.na(expected)) integer() else setdiff(seq_len(expected), chunk_ids)

  sk <- S$data
  skip_n <- function(pat) if (nrow(sk)) sum(grepl(pat, sk$reason)) else 0L
  cov <- data.table(set = s, n_cells_with_crowns = n_cells_data, expected_chunks = expected,
                    chunks_found = length(chunk_ids), missing_chunks = paste(missing, collapse = ","),
                    skipped_too_few_crowns = skip_n("too_few"), skipped_no_lai = skip_n("no_lai"),
                    model_errors = skip_n("model_error"), fitted = 0L, converged = 0L)

  if (nrow(A$data) && nrow(Tt$data)) {
    av <- pick_var(A$data, sa$alpha_variable, "alpha"); tv <- pick_var(Tt$data, sa$ntot_variable, "ntot")
    keep <- c("grid", "mean", "median", "sd", "q5", "q95", "rhat", "ess_bulk")
    a <- A$data[variable == av, c(keep, "n_crowns", "breakpoint"), with = FALSE]
    setnames(a, keep, c("grid_id", paste0("alpha_", keep[-1])))
    t <- Tt$data[variable == tv, keep, with = FALSE]
    setnames(t, keep, c("grid_id", paste0("ntot_", keep[-1])))
    cells <- merge(a, t, by = "grid_id", all = TRUE)
    cells[, converged := is.finite(alpha_mean) & is.finite(ntot_mean) & is.finite(alpha_rhat) & alpha_rhat <= max_rhat & is.finite(ntot_rhat) & ntot_rhat <= max_rhat]
    cells[, set := s]
    cov[, `:=`(fitted = nrow(cells), converged = sum(cells$converged))]

    out_dir <- file.path(param_root, s)
    fwrite(cells, file.path(out_dir, paste0(site, "_", s, "_parameters.csv")))
    layers <- c("alpha_mean", "alpha_sd", "ntot_mean", "ntot_sd", "n_crowns", "converged")
    r <- rast(template, nlyrs = length(layers)); names(r) <- layers
    idx <- cs_grid_cells(template, cells$grid_id)
    for (l in layers) { v <- rep(NA_real_, ncell(template)); v[idx] <- as.numeric(cells[[l]]); values(r[[l]]) <- v }
    writeRaster(r, file.path(out_dir, paste0(site, "_", s, "_parameters.tif")), overwrite = TRUE)
    cells_all[[s]] <- cells
  }
  coverage[[s]] <- cov
  cat(sprintf("%-16s fitted %4d | converged %4d | chunks %d/%s%s\n", s, cov$fitted, cov$converged,
              cov$chunks_found, ifelse(is.na(expected), "?", expected),
              ifelse(length(missing), paste0(" | MISSING: ", cov$missing_chunks), "")))
}
coverage <- rbindlist(coverage)
fwrite(coverage, tab("coverage"))
if (!length(cells_all)) stop("No fitted cells yet.")
cells_all <- rbindlist(cells_all, fill = TRUE)

# ---- Validation against the reference --------------------------------------
fit_stats <- function(x, y) list(n = length(x), r2 = if (length(x) > 2) cor(x, y)^2 else NA_real_,
                                 rmse = sqrt(mean((x - y)^2)), mae = mean(abs(x - y)), bias = mean(x - y))
val <- NULL; pairs <- NULL
if (ref %in% cells_all$set) {
  r0 <- cells_all[set == ref & converged, .(grid_id, alpha_ref = alpha_mean, ntot_ref = ntot_mean)]
  pairs <- merge(cells_all[set != ref & converged, .(set, grid_id, alpha_mean, ntot_mean)], r0, by = "grid_id")
  pairs <- pairs[is.finite(alpha_mean) & is.finite(alpha_ref) & is.finite(ntot_mean) & is.finite(ntot_ref)]
  if (nrow(pairs)) {
    val <- rbind(pairs[, c(parameter = "alpha", fit_stats(alpha_mean, alpha_ref)), by = set],
                 pairs[, c(parameter = "N_tot", fit_stats(ntot_mean, ntot_ref)), by = set])
    setorder(val, parameter, set)
    fwrite(val, tab("validation"))
  }
} else cat("Reference set", ref, "not fitted yet; skipping validation.\n")

# ---- Figures ----------------------------------------------------------------
if (!is.null(pairs) && nrow(pairs)) {
  for (pv in list(c("alpha_ref", "alpha_mean", "alpha", "alpha_1to1.png"),
                  c("ntot_ref", "ntot_mean", "N_tot", "ntot_1to1.png"))) {
    save_fig(ggplot(pairs, aes(.data[[pv[1]]], .data[[pv[2]]])) + geom_bin2d(bins = 40) +
               geom_abline(linetype = 2) + facet_wrap(~set) + coord_equal() +
               labs(x = paste(pv[3], "from", ref), y = pv[3], fill = "Cells",
                    title = paste(site, pv[3], "per 1 ha cell vs", ref),
                    subtitle = paste("Converged cells only (R-hat <=", max_rhat, ")")) + th, pv[4])
  }
}
map_df <- merge(grid, cells_all[, .(grid_id, set, alpha_mean, ntot_mean, converged)], by = "grid_id")
map_df$alpha_plot <- ifelse(map_df$converged, map_df$alpha_mean, NA)
mt <- theme_void(base_size = 11) + theme(plot.background = element_rect(fill = "white", colour = NA))
save_fig(ggplot(map_df) + geom_sf(aes(fill = alpha_plot), colour = NA) + facet_wrap(~set) +
           scale_fill_viridis_c(na.value = "grey80") +
           labs(fill = "alpha", title = paste(site, "recovered alpha per 1 ha cell"),
                subtitle = "Grey: fitted but not converged") + mt, "alpha_maps.png", 11, 6)
if (!is.null(pairs) && nrow(pairs)) {
  dmap <- merge(grid, pairs[, .(grid_id, set, d_alpha = alpha_mean - alpha_ref)], by = "grid_id")
  lim <- max(abs(dmap$d_alpha), na.rm = TRUE)
  save_fig(ggplot(dmap) + geom_sf(aes(fill = d_alpha), colour = NA) + facet_wrap(~set) +
             scale_fill_distiller(palette = "RdBu", limits = c(-lim, lim)) +
             labs(fill = paste("alpha -", ref), title = paste(site, "alpha difference from", ref)) + mt,
           "alpha_diff_maps.png", 11, 6)
}

# ---- Report -----------------------------------------------------------------
md <- c(paste0("# Size-abundance recovery: ", site), "",
        paste0("Generated ", format(Sys.time(), "%Y-%m-%d %H:%M"), ". Convergence: R-hat <= ", max_rhat,
               " for both alpha and N_tot."), "",
        "| Set | Cells with crowns | Chunks found / expected | Missing chunks | Too few crowns | No LAI | Model errors | Fitted | Converged |",
        "|---|---|---|---|---|---|---|---|---|",
        sprintf("| %s | %s | %d / %s | %s | %d | %d | %d | %d | %d |", coverage$set, coverage$n_cells_with_crowns,
                coverage$chunks_found, ifelse(is.na(coverage$expected_chunks), "?", coverage$expected_chunks),
                ifelse(nzchar(coverage$missing_chunks), coverage$missing_chunks, "none"),
                coverage$skipped_too_few_crowns, coverage$skipped_no_lai, coverage$model_errors,
                coverage$fitted, coverage$converged))
if (any(nzchar(coverage$missing_chunks))) {
  md <- c(md, "", "Resubmit only the missing chunks, e.g.:", "", "```bash",
          sprintf("CS_ARRAY=%s bash slurm/submit.sh alpha %s %s%s", coverage$missing_chunks[nzchar(coverage$missing_chunks)],
                  sub("_.*", "", coverage$set[nzchar(coverage$missing_chunks)]), site,
                  ifelse(grepl("_", coverage$set[nzchar(coverage$missing_chunks)]),
                         paste0(" ", sub("^[^_]+_", "", coverage$set[nzchar(coverage$missing_chunks)])), "")),
          "```")
}
if (!is.null(val)) {
  md <- c(md, "", paste0("## Validation vs ", ref, " (converged cells in both)"), "",
          "| Parameter | Set | Cells | R² | RMSE | MAE | Bias |", "|---|---|---|---|---|---|---|",
          sprintf("| %s | %s | %d | %.3f | %.3f | %.3f | %.3f |", val$parameter, val$set, val$n, val$r2,
                  val$rmse, val$mae, val$bias))
}
md <- c(md, "", paste0("Rasters and per-cell tables: `", param_root, "/<set>/`. Figures: `reports/figures/alpha_", site, "/`."))
writeLines(md, file.path(cfg$repo_root, cfg$reports_dir, paste0("alpha_", site, "_report.md")))
cat(paste(md, collapse = "\n"), "\n")
