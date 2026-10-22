# =============================================================================
# make_grid.R
# Build the canonical 1 ha (100 m, EPSG:5070) grid for a site, once.
# Previously rebuilt inside every array task of GenerateDatasetsIndv.R and again
# in ExtractGridLAI.R; now both downstream steps read this file so grid_id is
# guaranteed identical. Cells are dissolved across AOP tile boundaries.
#
# Usage:   Rscript pipeline/05_crown_metrics/make_grid.R --site HARV
# Output:  {deepforest_root}/Shapefiles/{site}_grid_1ha.gpkg        (layer "grid")
#          {deepforest_root}/Shapefiles/{site}_grid_1ha_tiles.csv   (grid_id x AOP TileID)
# =============================================================================
cs_repo_root <- function() {
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) normalizePath(file.path(dirname(f), "..", "..")) else getwd()
}
source(file.path(cs_repo_root(), "src", "R", "utils.R"))
cs_osc_env()

args <- cs_args(list(site = "REQUIRED"))
cfg  <- cs_config(cs_repo_root())

g   <- cs_build_grid(cfg, args$site)
out <- cs_dpath(cfg, "site_grid_file", site = args$site)
st_write(g$grid, out, layer = "grid", delete_dsn = TRUE, quiet = TRUE)
write.csv(g$pieces, sub("\\.gpkg$", "_tiles.csv", out), row.names = FALSE)
cat("Wrote", nrow(g$grid), "grid cells to", out, "\n")
