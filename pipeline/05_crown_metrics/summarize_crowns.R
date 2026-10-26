# =============================================================================
# summarize_crowns.R
# Assess crown datasets for one site before committing compute to the alpha
# step. Reads every {site}_{product}[_{height}]_trees_*.csv that exists, so it
# can be run after any subset of crowns jobs has finished.
#
# Answers, per product x height source:
#   - how many crowns, tiles, and 1 ha cells; crown size, height, DBH quantiles
#   - how many cells clear the minimum-crown floor (what alpha will fit), and
#     how many array tasks recover_alpha.R will need
#   - data-quality flags: crowns without height, zero heights (unmasked nodata),
#     missing DBH
#   - crown counts per tile and per cell relative to the reference product
#   - NEON CHM vs Morford height agreement on identical crowns
#
# Usage:  Rscript pipeline/05_crown_metrics/summarize_crowns.R --site HARV
#         [--reference NEON10] [--sample 200000]
# Output: reports/tables/crowns_{site}_*.csv, reports/crowns_{site}_report.md,
#         reports/figures/crowns_{site}/*.png
# =============================================================================
cs_repo_root <- function() {
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) normalizePath(file.path(dirname(f), "..", "..")) else getwd()
}
source(file.path(cs_repo_root(), "src", "R", "utils.R"))
cs_osc_env()
suppressPackageStartupMessages({ library(data.table); library(ggplot2) })

args <- cs_args(list(site = "REQUIRED", reference = "NEON10", sample = "200000"))
cfg  <- cs_config(cs_repo_root())
site <- args$site
n_sample  <- as.integer(args$sample)
min_cells <- cfg$size_abundance$min_crowns_per_cell
chunk     <- cfg$size_abundance$chunk_size
fig_dir   <- dirname(cs_rpath(cfg, "figures", paste0("crowns_", site), "x"))
dir.create(fig_dir, showWarnings = FALSE, recursive = TRUE)
tab <- function(name) cs_rpath(cfg, "tables", paste0("crowns_", site, "_", name, ".csv"))
set.seed(1)

# ---- Load every available product x height dataset -------------------------
cols <- c("crown_id", "grid_id", "Area", "Diameter", "Max_Height", "DBH", "tile")
data_dir <- cs_spath(cfg, "crown_datasets_dir")
sets <- list()
for (product in names(cfg$products)) for (h in names(cfg$height_sources)) {
  label <- if (h == "neon_chm") product else paste0(product, "_", h)
  files <- list.files(data_dir, pattern = paste0("^", site, "_", label, "_trees_.*\\.csv$"), full.names = TRUE)
  if (!length(files)) next
  d <- rbindlist(lapply(files, fread, select = cols), fill = TRUE)
  d[, `:=`(product = product, height_source = h)]
  sets[[label]] <- d
  cat(sprintf("%-16s %4d tiles  %9d crowns\n", label, length(files), nrow(d)))
}
if (!length(sets)) stop("No crown datasets for ", site, " in ", data_dir)
dt <- rbindlist(sets, use.names = TRUE)
dt[, set := factor(ifelse(height_source == "neon_chm", product, paste0(product, " (", height_source, ")")))]
rm(sets); invisible(gc())

lai_file <- file.path(cs_spath(cfg, "lai_dir"), paste0(site, "_gridLAI.csv"))
lai <- if (file.exists(lai_file)) fread(lai_file)[is.finite(lai_val), unique(grid_id)] else NULL

# ---- 1. Summary per product x height ---------------------------------------
q <- function(x, p) as.numeric(quantile(x, p, na.rm = TRUE))
cells <- dt[!is.na(grid_id), .N, by = .(set, product, height_source, grid_id)]
summary_tab <- dt[, .(
  n_tiles = uniqueN(tile), n_crowns = .N,
  crowns_per_tile_median = as.numeric(median(table(tile))),
  pct_height_na   = round(100 * mean(is.na(Max_Height)), 2),
  pct_height_zero = round(100 * mean(Max_Height <= 0, na.rm = TRUE), 2),
  pct_dbh_na      = round(100 * mean(!is.finite(DBH)), 2),
  area_p05 = q(Area, .05), area_p50 = q(Area, .5), area_p95 = q(Area, .95),
  diam_p05 = q(Diameter, .05), diam_p50 = q(Diameter, .5), diam_p95 = q(Diameter, .95),
  height_p05 = q(Max_Height, .05), height_p50 = q(Max_Height, .5), height_p95 = q(Max_Height, .95),
  dbh_mean = mean(DBH[is.finite(DBH)]),
  dbh_p05 = q(DBH, .05), dbh_p50 = q(DBH, .5), dbh_p95 = q(DBH, .95)
), by = .(set, product, height_source)]
cell_tab <- cells[, .(
  n_cells = .N,
  n_cells_eligible = sum(N >= min_cells),
  n_cells_eligible_with_lai = if (is.null(lai)) NA_integer_ else sum(N >= min_cells & grid_id %in% lai),
  crowns_per_cell_median = as.numeric(median(N)),
  alpha_array_tasks = ceiling(.N / chunk)
), by = .(set, product, height_source)]
summary_tab <- merge(summary_tab, cell_tab, by = c("set", "product", "height_source"))
summary_tab[, pct_cells_eligible := round(100 * n_cells_eligible / n_cells, 1)]
fwrite(summary_tab, tab("summary"))

# ---- 2. Counts relative to the reference product ---------------------------
ref <- args$reference
counts_neon <- dt[height_source == "neon_chm"]
tile_counts <- counts_neon[, .N, by = .(product, tile)]
cell_counts <- cells[height_source == "neon_chm", .(product, grid_id, N)]
vs_ref_tile <- vs_ref_cell <- NULL
if (ref %in% tile_counts$product) {
  vs_ref_tile <- merge(tile_counts[product != ref], tile_counts[product == ref, .(tile, N_ref = N)], by = "tile")
  vs_ref_tile[, pct_diff := 100 * (N - N_ref) / N_ref]
  fwrite(vs_ref_tile, tab("tiles_vs_reference"))
  vs_ref_cell <- merge(cell_counts[product != ref], cell_counts[product == ref, .(grid_id, N_ref = N)],
                       by = "grid_id")
  fit_stats <- function(x, y) list(n = length(x), r2 = cor(x, y)^2, rmse = sqrt(mean((x - y)^2)),
                                   mae = mean(abs(x - y)), bias = mean(x - y))
  ref_stats <- merge(
    vs_ref_tile[, .(n_tiles = .N, median_pct_diff_per_tile = median(pct_diff)), by = product],
    vs_ref_cell[, fit_stats(N, N_ref), by = product], by = "product")
  fwrite(ref_stats, tab("counts_vs_reference"))
}

# ---- 3. NEON CHM vs Morford heights on identical crowns --------------------
hc <- NULL
if (all(c("neon_chm", "morford") %in% dt$height_source)) {
  hp <- merge(dt[height_source == "neon_chm", .(product, tile, crown_id, h_neon = Max_Height, dbh_neon = DBH)],
              dt[height_source == "morford",  .(product, tile, crown_id, h_mor = Max_Height, dbh_mor = DBH)],
              by = c("product", "tile", "crown_id"))
  hp <- hp[is.finite(h_neon) & is.finite(h_mor)]
  hc <- hp[, .(n_pairs = .N, r2 = cor(h_mor, h_neon)^2, bias_m = mean(h_mor - h_neon),
               rmse_m = sqrt(mean((h_mor - h_neon)^2)), mae_m = mean(abs(h_mor - h_neon)),
               dbh_bias_cm = mean(dbh_mor - dbh_neon, na.rm = TRUE)), by = product]
  fwrite(hc, tab("height_comparison"))
}

# ---- 4. Figures (distributions from a seeded sample per set) ---------------
smp <- dt[, .SD[sample(.N, min(.N, n_sample))], by = set]
save_fig <- function(p, name, w = 8, h = 5) ggsave(file.path(fig_dir, name), p, width = w, height = h, dpi = 200)
th <- theme_bw(base_size = 11)

save_fig(ggplot(smp[is.finite(DBH) & DBH > 0], aes(DBH, colour = set)) + geom_density() +
           scale_x_log10() + labs(x = "DBH (cm, log scale)", y = "Density", colour = NULL,
           title = paste(site, "DBH distribution"), caption = paste("Up to", n_sample, "crowns per set")) + th,
         "dbh_density.png")
save_fig(ggplot(smp[Area > 0], aes(Area, colour = set)) + geom_density() + scale_x_log10() +
           labs(x = "Crown area (m², log scale)", y = "Density", colour = NULL,
                title = paste(site, "crown area distribution")) + th, "crown_area_density.png")
save_fig(ggplot(smp[is.finite(Max_Height)], aes(Max_Height)) + geom_histogram(binwidth = 1) +
           facet_wrap(~set, scales = "free_y") +
           labs(x = "Max crown height (m)", y = "Crowns", title = paste(site, "crown heights")) + th,
         "height_hist.png", 10, 6)
save_fig(ggplot(cells, aes(N)) + geom_histogram(bins = 60) +
           geom_vline(xintercept = min_cells, linetype = 2, colour = "firebrick") +
           facet_wrap(~set, scales = "free_y") +
           labs(x = "Crowns per 1 ha cell", y = "Cells",
                title = paste(site, "crowns per cell"), subtitle = paste("Dashed line: alpha minimum of", min_cells)) + th,
         "crowns_per_cell_hist.png", 10, 6)

if (!is.null(vs_ref_cell)) {
  save_fig(ggplot(vs_ref_cell, aes(N_ref, N)) + geom_bin2d(bins = 60) +
             geom_abline(linetype = 2) + facet_wrap(~product) + coord_equal() +
             labs(x = paste("Crowns per cell,", ref), y = "Crowns per cell", fill = "Cells",
                  title = paste(site, "crowns per cell vs", ref)) + th,
           "crowns_per_cell_vs_reference.png", 9, 5)
}
if (!is.null(hc)) {
  hs <- hp[, .SD[sample(.N, min(.N, n_sample))], by = product]
  save_fig(ggplot(hs, aes(h_neon, h_mor)) + geom_bin2d(bins = 80) + geom_abline(linetype = 2) +
             facet_wrap(~product) + coord_equal() +
             labs(x = "NEON LiDAR CHM height (m)", y = "Morford et al. height (m)", fill = "Crowns",
                  title = paste(site, "crown height: NEON CHM vs Morford")) + th,
           "height_neon_vs_morford.png", 9, 5)
}

grid_file <- cs_dpath(cfg, "site_grid_file", site = site)
if (file.exists(grid_file)) {
  grid <- cs_read_grid(cfg, site)
  mp <- merge(grid, cells[height_source == "neon_chm", .(grid_id, product, N)], by = "grid_id")
  mp$N_plot <- ifelse(mp$N >= min_cells, mp$N, NA)
  save_fig(ggplot(mp) + geom_sf(aes(fill = N_plot), colour = NA) + facet_wrap(~product) +
             scale_fill_viridis_c(na.value = "grey80") +
             labs(fill = "Crowns", title = paste(site, "crowns per 1 ha cell"),
                  subtitle = paste("Grey: below alpha minimum of", min_cells)) +
             theme_void(base_size = 11) + theme(plot.background = element_rect(fill = "white", colour = NA)),
           "crowns_per_cell_map.png", 10, 6)
}

# ---- 5. Readiness report ----------------------------------------------------
flag <- function(s) {
  f <- character()
  if (s$pct_height_na > 5)   f <- c(f, sprintf("%.1f%% crowns without height", s$pct_height_na))
  if (s$pct_height_zero > 1) f <- c(f, sprintf("%.1f%% zero heights (unmasked nodata?)", s$pct_height_zero))
  if (s$pct_dbh_na > 5)      f <- c(f, sprintf("%.1f%% crowns without DBH", s$pct_dbh_na))
  if (s$n_cells_eligible == 0) f <- c(f, "no cells meet the crown minimum")
  if (length(f)) paste(f, collapse = "; ") else "none"
}
md <- c(paste0("# Crown dataset assessment: ", site), "",
        paste0("Generated ", format(Sys.time(), "%Y-%m-%d %H:%M"), ". Alpha minimum: ", min_cells,
               " crowns per cell; chunk size ", chunk, "."), "",
        "| Set | Crowns | Tiles | Cells | Eligible cells | Eligible w/ LAI | Alpha tasks | Height NA % | Flags |",
        "|---|---|---|---|---|---|---|---|---|")
for (i in seq_len(nrow(summary_tab))) {
  s <- summary_tab[i]
  md <- c(md, sprintf("| %s | %s | %d | %d | %d (%.1f%%) | %s | %d | %.2f | %s |", s$set,
                      format(s$n_crowns, big.mark = ","), s$n_tiles, s$n_cells, s$n_cells_eligible,
                      s$pct_cells_eligible, ifelse(is.na(s$n_cells_eligible_with_lai), "LAI not extracted",
                      s$n_cells_eligible_with_lai), s$alpha_array_tasks, s$pct_height_na, flag(s)))
}
if (exists("ref_stats")) {
  md <- c(md, "", paste0("## Crown counts vs ", ref, " (NEON CHM heights)"), "",
          "| Product | Median % difference per tile | Cell R² | Cell RMSE | Cell bias |", "|---|---|---|---|---|",
          sprintf("| %s | %.1f | %.3f | %.1f | %.1f |", ref_stats$product, ref_stats$median_pct_diff_per_tile,
                  ref_stats$r2, ref_stats$rmse, ref_stats$bias))
}
if (!is.null(hc)) {
  md <- c(md, "", "## Morford vs NEON CHM height on identical crowns", "",
          "| Product | Pairs | R² | Bias (m) | RMSE (m) | DBH bias (cm) |", "|---|---|---|---|---|---|",
          sprintf("| %s | %s | %.3f | %.2f | %.2f | %.2f |", hc$product, format(hc$n_pairs, big.mark = ","),
                  hc$r2, hc$bias_m, hc$rmse_m, hc$dbh_bias_cm))
}
md <- c(md, "", paste0("Figures: `reports/figures/crowns_", site, "/`. Tables: `reports/tables/crowns_", site, "_*.csv`."))
md_file <- file.path(cfg$repo_root, cfg$reports_dir, paste0("crowns_", site, "_report.md"))
writeLines(md, md_file)
cat(paste(md, collapse = "\n"), "\n")
