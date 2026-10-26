# =============================================================================
# utils.R
# Shared helpers for the R stages. Source at the top of every R script:
#   source(file.path(cs_repo_root(), "src", "R", "utils.R"))
# (each script defines cs_repo_root() locally so it can find this file).
# =============================================================================

# PROJ must not try to download datum-shift grids. When the network lookup
# fails (no internet, as on many compute nodes) and terra is loaded, sf can
# silently drop polygon vertices during NAD83 <-> WGS84 transforms (a 1 km tile
# came back as a triangle in testing). Set before the packages load.
Sys.setenv(PROJ_NETWORK = "OFF")
suppressPackageStartupMessages({
  library(yaml)
  library(sf)
  library(terra)
  library(dplyr)
})
invisible(sf_proj_network(FALSE))

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
    r <- vrt(f)
    nd <- cfg$height_sources$morford$nodata          # optional; GEE exports carry no NoData flag
    if (!is.null(nd)) NAflag(r) <- nd
    return(r)
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
  # Guard: the grid must cover the AOP. A mismatch means a reprojection or
  # geometry failure upstream; stop rather than write a grid with holes.
  a_aop  <- as.numeric(sum(st_area(st_union(aop))))
  a_grid <- as.numeric(sum(st_area(dissolved)))
  if (abs(a_grid - a_aop) / a_aop > 0.001)
    stop(sprintf("Grid area (%.0f m2) differs from AOP area (%.0f m2) by %.2f%%; check PROJ/CRS setup.",
                 a_grid, a_aop, 100 * (a_grid - a_aop) / a_aop))
  list(grid = dissolved, pieces = pieces)
}

# Raster template whose cells are exactly the 1 ha grid cells: same origin,
# size, and EPSG:5070 CRS as st_make_grid() in cs_build_grid(). grid_id k is
# raster cell cs_grid_cells(template, k).
cs_grid_template <- function(cfg, site) {
  aop <- st_read(cs_dpath(cfg, "site_aop_shapefile", site = site), quiet = TRUE) |> st_transform(5070)
  bb <- st_bbox(aop)
  nc <- ceiling((bb[["xmax"]] - bb[["xmin"]]) / 100)
  nr <- ceiling((bb[["ymax"]] - bb[["ymin"]]) / 100)
  rast(xmin = bb[["xmin"]], xmax = bb[["xmin"]] + nc * 100, ymin = bb[["ymin"]], ymax = bb[["ymin"]] + nr * 100,
       ncols = nc, nrows = nr, crs = "EPSG:5070")
}
cs_grid_cells <- function(template, grid_id) {
  col <- (grid_id - 1) %% ncol(template)
  row_from_bottom <- (grid_id - 1) %/% ncol(template)
  (nrow(template) - 1 - row_from_bottom) * ncol(template) + col + 1
}

cs_read_grid <- function(cfg, site) {
  f <- cs_dpath(cfg, "site_grid_file", site = site)
  if (!file.exists(f)) stop("Grid not found: ", f, ". Run 05_crown_metrics/make_grid.R first.")
  st_read(f, layer = "grid", quiet = TRUE)
}
