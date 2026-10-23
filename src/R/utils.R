# =============================================================================
# utils.R
# Shared helpers for the R stages. Source at the top of every R script:
#   source(file.path(cs_repo_root(), "src", "R", "utils.R"))
# (each script defines cs_repo_root() locally so it can find this file).
# =============================================================================

suppressPackageStartupMessages({
  library(yaml)
  library(sf)
  library(terra)
  library(dplyr)
})

# ---- OSC module setup (no-op off OSC) ---------------------------------------
# Previously duplicated at the top of every ScalingAcrossResolution script.
cs_osc_env <- function() {
  if (nzchar(Sys.getenv("LMOD_PKG"))) {
    source(file.path(Sys.getenv("LMOD_PKG"), "init/R"))
    module("load", "proj/9.2.1")
    module("load", "gdal/3.7.3")
    dyn.load("/apps/spack/0.21/pitzer/linux-rhel9-skylake/proj/gcc/12.3.0/9.2.1-buhooyr/lib64/libproj.so")
    dyn.load("/apps/spack/0.21/pitzer/linux-rhel9-skylake/gdal/gcc/12.3.0/3.7.3-wmnbnyd/lib64/libgdal.so")
  }
  invisible(NULL)
}

# ---- Config -----------------------------------------------------------------
cs_config <- function(root) {
  cfg <- c(read_yaml(file.path(root, "config", "paths.yaml")),
           read_yaml(file.path(root, "config", "products.yaml")))
  cfg$repo_root <- root
  cfg
}

# Fill {key} placeholders in a template string
cs_fmt <- function(template, ...) {
  vals <- list(...)
  for (k in names(vals)) template <- gsub(paste0("{", k, "}"), vals[[k]], template, fixed = TRUE)
  template
}

cs_dpath <- function(cfg, key, ...) file.path(cfg$deepforest_root, cs_fmt(cfg[[key]], ...))
cs_spath <- function(cfg, key, ...) file.path(cfg$scaling_root,    cs_fmt(cfg[[key]], ...))
cs_rpath <- function(cfg, ...) {
  p <- file.path(cfg$repo_root, cfg$reports_dir, ...)
  dir.create(dirname(p), showWarnings = FALSE, recursive = TRUE)
  p
}

cs_product <- function(cfg, product) {
  if (!product %in% names(cfg$products))
    stop("Unknown product '", product, "'. Options: ", paste(names(cfg$products), collapse = ", "))
  cfg$products[[product]]
}

# Where crown shapefiles for a product live (published crowns have an override)
cs_crowns_dir <- function(cfg, product, site) {
  p <- cs_product(cfg, product)
  if (isTRUE(p$published_crowns)) file.path(cfg$deepforest_root, cs_fmt(p$crowns_dir_override, site = site))
  else cs_dpath(cfg, "crowns_dir", product = product, site = site)
}

# ---- Command-line args: --key value --flag ----------------------------------
cs_args <- function(defaults = list()) {
  a <- commandArgs(trailingOnly = TRUE)
  out <- defaults
  i <- 1
  while (i <= length(a)) {
    if (!startsWith(a[i], "--")) stop("Unexpected argument: ", a[i])
    key <- gsub("-", "_", sub("^--", "", a[i]))
    if (i == length(a) || startsWith(a[i + 1], "--")) { out[[key]] <- TRUE; i <- i + 1 }
    else { out[[key]] <- a[i + 1]; i <- i + 2 }
  }
  missing <- names(out)[vapply(out, function(x) identical(x, "REQUIRED"), logical(1))]
  if (length(missing)) stop("Missing required argument(s): ", paste0("--", missing, collapse = " "))
  out
}

# ---- Tiles ------------------------------------------------------------------
# NEON 1 km tile id from any filename, e.g. "..._725000_4705000_image.shp" -> "725000_4705000"
cs_tile_id <- function(x) {
  m <- regmatches(basename(x), gregexpr("[0-9]{6}_[0-9]{7}", basename(x)))
  vapply(m, function(v) if (length(v)) v[length(v)] else NA_character_, character(1))
}

cs_list_tiles <- function(cfg, product, site) {
  pat <- file.path(cfg$deepforest_root, cs_fmt(cs_product(cfg, product)$tile_glob, site = site, tile = "*"))
  f <- sort(Sys.glob(pat))
  if (!length(f)) stop("No imagery tiles match ", pat)
  data.frame(tile = cs_tile_id(f), path = f, stringsAsFactors = FALSE)
}

cs_find_chm <- function(cfg, site, tile) {
  hits <- Sys.glob(cs_dpath(cfg, "chm_glob", site = site, tile = tile,
                            chm_year = cfg$sites[[site]]$chm_year))
  if (length(hits) > 1) stop("Multiple CHM files for ", site, " ", tile)
  if (length(hits)) hits else NA_character_
}

# Height raster for a source. NEON: the matching 1 km CHM tile. Morford: a
# virtual mosaic of the site's GEE export chunks (built once per R session).
cs_height_raster <- function(cfg, site, source, tile) {
  if (source == "neon_chm") {
    p <- cs_find_chm(cfg, site, tile)
    if (is.na(p)) stop("No NEON CHM for ", site, " ", tile)
    return(rast(p))
  }
  if (source == "morford") {
    f <- sort(Sys.glob(cs_dpath(cfg, "morford_glob", site = site)))
    if (!length(f)) stop("No Morford CHM chunks for ", site)
    return(vrt(f))
  }
  stop("Unknown height source: ", source)
}

# ---- 1 ha grid ---------------------------------------------------------------
# One canonical grid per site, built once by 05_crown_metrics/make_grid.R so
# grid_id is identical across crown metrics, LAI, and parameter recovery.
cs_build_grid <- function(cfg, site) {
  aop <- st_read(cs_dpath(cfg, "site_aop_shapefile", site = site), quiet = TRUE) |>
    st_transform(5070)
  cells <- st_make_grid(aop, cellsize = 100, square = TRUE)
  grid <- st_sf(grid_id = seq_along(cells), geometry = cells)
  grid <- st_intersection(aop, grid)
  grid <- grid[st_geometry_type(grid) %in% c("POLYGON", "MULTIPOLYGON"), ]
  # keep the AOP tile each cell piece came from (used by LAI extraction)
  pieces <- st_drop_geometry(grid)[, c("grid_id", "TileID")]
  dissolved <- grid |> group_by(grid_id) |> summarise(geometry = st_union(geometry), .groups = "drop") |>
    st_make_valid()
  list(grid = dissolved, pieces = pieces)
}

cs_read_grid <- function(cfg, site) {
  f <- cs_dpath(cfg, "site_grid_file", site = site)
  if (!file.exists(f)) stop("Grid not found: ", f, ". Run 05_crown_metrics/make_grid.R first.")
  st_read(f, layer = "grid", quiet = TRUE)
}
