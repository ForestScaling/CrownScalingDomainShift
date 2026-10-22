# =============================================================================
# crown_metrics.R
# Crown shapefile (one 1 km tile) -> analysis-ready CSV with grid cell, crown
# geometry metrics, height, and DBH. Replaces GenerateDatasetsIndv.R.
#
# Fixes relative to GenerateDatasetsIndv.R:
#   - CHM located by site and tile (was hardcoded to HARV, so BART failed)
#   - tile id parsed by regex (was fixed character positions per product)
#   - geometry dropped by name (was column 14 by position), so every product
#     writes identical columns and no downstream column surgery is needed
#   - crowns transformed to the CHM CRS before measuring and extracting, so
#     area, perimeter, and height are always in metres on the same grid
#   - reads the shared 1 ha grid instead of rebuilding it in every task
#
# Usage:
#   Rscript pipeline/05_crown_metrics/crown_metrics.R --product NAIP30 --site HARV --task-id 3
#   Rscript pipeline/05_crown_metrics/crown_metrics.R --product NAIP30 --site HARV --count
#   --height neon_chm (default) | morford (Phase 3, not yet implemented)
#
# Output: {scaling_root}/data/CrownDatasets/{site}_{product}[_{height}]_trees_{tile}.csv
#         (height suffix only added for non-default height sources)
# =============================================================================
cs_repo_root <- function() {
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) normalizePath(file.path(dirname(f), "..", "..")) else getwd()
}
source(file.path(cs_repo_root(), "src", "R", "utils.R"))
cs_osc_env()
suppressPackageStartupMessages(library(itcSegment))

args <- cs_args(list(product = "REQUIRED", site = "REQUIRED", task_id = NA,
                     height = "neon_chm", count = FALSE))
cfg  <- cs_config(cs_repo_root())

# Production crowns only (exploration subfolders are not listed)
files <- sort(list.files(cs_crowns_dir(cfg, args$product, args$site),
                         pattern = "\\.shp$", full.names = TRUE))
if (isTRUE(args$count)) { cat(length(files), "\n"); quit(save = "no") }
if (!length(files)) stop("No crown shapefiles for ", args$product, " ", args$site)
task <- as.integer(args$task_id)
if (is.na(task) || task < 1 || task > length(files)) stop("--task-id must be 1..", length(files))
if (args$height != "neon_chm") stop("--height ", args$height, " not implemented yet (Phase 3)")

file <- files[task]
tile <- cs_tile_id(file)
cat("Product:", args$product, "| Site:", args$site, "| Tile:", tile, "\n")

chm_path <- cs_find_chm(cfg, args$site, tile)
if (is.na(chm_path)) stop("No CHM for ", args$site, " ", tile)
chm <- rast(chm_path)

crowns <- st_read(file, quiet = TRUE)
if (nrow(crowns) == 0) { cat("No crowns; nothing written.\n"); quit(save = "no") }
crowns <- st_transform(crowns, crs(chm))
crowns$crown_id <- seq_len(nrow(crowns))

# ---- Assign each crown to the 1 ha cell it overlaps most --------------------
grid  <- st_transform(cs_read_grid(cfg, args$site), st_crs(crowns))
inter <- suppressWarnings(st_intersection(crowns[, "crown_id"], grid[, "grid_id"]))
inter$overlap_area <- as.numeric(st_area(inter))
assign <- st_drop_geometry(inter) |>
  group_by(crown_id) |> slice_max(overlap_area, n = 1, with_ties = FALSE) |> ungroup() |>
  select(crown_id, grid_id)
crowns <- left_join(crowns, assign, by = "crown_id")

# ---- Crown geometry ---------------------------------------------------------
crowns$Area      <- as.numeric(st_area(crowns))
crowns$Perimeter <- as.numeric(st_perimeter(crowns))
# Crown diameter following Eichenwald et al. (2025): 0.5 * sqrt(P^2 - 8A)
crowns$Diameter  <- 0.5 * sqrt(crowns$Perimeter^2 - 8 * crowns$Area)

# ---- Height (zonal max within crown) and DBH --------------------------------
crowns$Max_Height <- terra::extract(chm, vect(crowns), fun = max, na.rm = TRUE, ID = FALSE)[, 1]
crowns$Max_Height[!is.finite(crowns$Max_Height)] <- NA   # crowns with no CHM coverage
crowns$DBH <- dbh(H = crowns$Max_Height, CA = crowns$Diameter, biome = 0)

out <- st_drop_geometry(crowns)
out$product       <- args$product
out$site          <- args$site
out$tile          <- tile
out$height_source <- args$height

suffix   <- if (args$height == "neon_chm") "" else paste0("_", args$height)
out_dir  <- cs_spath(cfg, "crown_datasets_dir")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
out_file <- file.path(out_dir, paste0(args$site, "_", args$product, suffix, "_trees_", tile, ".csv"))
write.csv(out, out_file, row.names = FALSE)
cat("Wrote", nrow(out), "crowns to", out_file, "\n")
