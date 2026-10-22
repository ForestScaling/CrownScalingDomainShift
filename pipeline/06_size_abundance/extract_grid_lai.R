# =============================================================================
# extract_grid_lai.R
# Mean NEON LAI per 1 ha cell, used for the LAI-informed alpha prior.
# Site-specific, not product-specific: run once per site. Replaces ExtractGridLAI.R.
#
# Fixes: reads the shared grid (same grid_id as crown_metrics.R); checks for
# missing LAI tiles before mosaicking (previously crashed instead of skipping);
# site and year come from config rather than hardcoded HARV.
#
# Usage:  Rscript pipeline/06_size_abundance/extract_grid_lai.R --site HARV
# Output: {scaling_root}/data/LAI/{site}_gridLAI.csv  (grid_id, lai_val)
# =============================================================================
cs_repo_root <- function() {
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) normalizePath(file.path(dirname(f), "..", "..")) else getwd()
}
source(file.path(cs_repo_root(), "src", "R", "utils.R"))
cs_osc_env()

args <- cs_args(list(site = "REQUIRED"))
cfg  <- cs_config(cs_repo_root())
site <- args$site

grid   <- cs_read_grid(cfg, site)
pieces <- read.csv(sub("\\.gpkg$", "_tiles.csv", cs_dpath(cfg, "site_grid_file", site = site)))
all_lai <- Sys.glob(cs_dpath(cfg, "lai_glob", site = site, lai_year = cfg$sites[[site]]$lai_year))
if (!length(all_lai)) stop("No LAI rasters found for ", site)

results <- list()
for (tile_name in unique(pieces$TileID)) {
  tile <- cs_tile_id(tile_name)
  xy <- as.numeric(strsplit(tile, "_")[[1]])
  # 3x3 neighbourhood so cells straddling tile edges are fully covered
  nb <- as.vector(outer(xy[1] + c(-1000, 0, 1000), xy[2] + c(-1000, 0, 1000),
                        function(x, y) paste0(x, "_", y)))
  lai_avail <- all_lai[cs_tile_id(all_lai) %in% nb]
  if (!length(lai_avail)) { cat("No LAI for", tile, "- skipped\n"); next }

  lai <- if (length(lai_avail) > 1) do.call(mosaic, c(lapply(lai_avail, rast), list(fun = "mean")))
         else rast(lai_avail)
  cells <- grid[grid$grid_id %in% pieces$grid_id[pieces$TileID == tile_name], ]
  cells <- st_transform(cells, crs(lai))
  vals  <- terra::extract(lai, vect(cells), fun = mean, na.rm = TRUE, ID = FALSE)[, 1]
  results[[tile]] <- data.frame(grid_id = cells$grid_id, lai_val = vals)
  cat(tile, ":", nrow(cells), "cells\n")
}

lai_df <- do.call(rbind, results)
lai_df <- lai_df[!duplicated(lai_df$grid_id), ]   # cells on tile seams appear once
out_dir <- cs_spath(cfg, "lai_dir")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
write.csv(lai_df, file.path(out_dir, paste0(site, "_gridLAI.csv")), row.names = FALSE)
cat("Wrote LAI for", nrow(lai_df), "of", nrow(grid), "cells\n")
