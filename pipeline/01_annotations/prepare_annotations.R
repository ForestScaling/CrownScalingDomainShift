# =============================================================================
# prepare_annotations.R
# Turn ArcGIS crown annotations into DeepForest training/testing crops + CSVs for
# one imagery product. Replaces prepareAnnotations.R and the archived
# developTrainingData.R / developTestingData_step*.R.
#
# The same annotation shapefiles are reused for every product (30 cm, 60 cm),
# so differences in model performance isolate image resolution.
#
# Key change from prepareAnnotations.R: imagery is never reprojected. Each crop
# is cut from the same 1 km tile used for landscape prediction, in that tile's
# native CRS, and the annotation boxes are transformed into it. Previously all
# crops were forced to EPSG:32619, which rotated and resampled the HARV test
# crops (HARV is UTM 18N), so evaluation imagery differed from production imagery.
#
# Usage:
#   Rscript pipeline/01_annotations/prepare_annotations.R --product NAIP30
#   Rscript pipeline/01_annotations/prepare_annotations.R --product NAIP60
#
# Inputs:  {deepforest_root}/Imagery/NAIP/{Training,Testing}/bbox/*.shp
#          1 km tiles from products.yaml tile_glob
# Outputs: {deepforest_root}/Imagery/NAIP/{split}/Crop_Images_{product}/
#            {block}.tif, annotations.csv
#          reports/tables/annotation_blocks_{product}.csv  (one row per block)
# =============================================================================

cs_repo_root <- function() {
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) normalizePath(file.path(dirname(f), "..", "..")) else getwd()
}
source(file.path(cs_repo_root(), "src", "R", "utils.R"))

args <- cs_args(list(product = "REQUIRED"))
cfg  <- cs_config(cs_repo_root())
pcfg <- cs_product(cfg, args$product)
if (isTRUE(pcfg$published_crowns)) stop(args$product, " uses published crowns; no annotations needed.")

block_rows <- list()

for (site in names(cfg$sites)) {
  split    <- cfg$sites[[site]]$split
  bbox_dir <- cs_dpath(cfg, "annotation_bbox_dir", split = split)
  crop_dir <- cs_dpath(cfg, "crop_dir", split = split, product = args$product)
  dir.create(crop_dir, showWarnings = FALSE, recursive = TRUE)

  shapefiles <- sort(list.files(bbox_dir, pattern = "\\.shp$", full.names = TRUE))
  if (!length(shapefiles)) stop("No annotation shapefiles in ", bbox_dir)
  cat("\n==", split, "(", site, "):", length(shapefiles), "annotation blocks ==\n")

  # Tile footprints for this site/product (header reads only)
  tiles <- cs_list_tiles(cfg, args$product, site)
  tile_rasters <- lapply(tiles$path, rast)
  tile_crs <- unique(vapply(tile_rasters, function(r) as.character(crs(r, describe = TRUE)$code), character(1)))
  if (length(tile_crs) > 1) stop(site, " tiles have mixed CRS: ", paste(tile_crs, collapse = ", "))
  target_crs <- crs(tile_rasters[[1]])
  cat("Tile CRS:", crs(tile_rasters[[1]], describe = TRUE)$name,
      "| resolution:", paste(res(tile_rasters[[1]]), collapse = " x "), "\n")
  if (abs(res(tile_rasters[[1]])[1] - pcfg$res_m) > 1e-6)
    warning("Tile resolution ", res(tile_rasters[[1]])[1], " does not match products.yaml res_m ", pcfg$res_m)

  annotations <- list()

  for (shp in shapefiles) {
    block <- tools::file_path_sans_ext(basename(shp))
    sa <- st_read(shp, quiet = TRUE)
    if (is.na(st_crs(sa))) stop(block, ": annotation shapefile has no CRS")
    sa <- st_transform(sa, target_crs)
    sa <- sa[!st_is_empty(sa), ]
    block_ext <- ext(vect(sa))

    # Crop from whichever tile(s) the block falls on; mosaic if it straddles tiles
    hits <- which(vapply(tile_rasters, function(r) {
      e <- ext(r)
      e$xmin < block_ext$xmax && e$xmax > block_ext$xmin && e$ymin < block_ext$ymax && e$ymax > block_ext$ymin
    }, logical(1)))
    if (!length(hits)) { warning(block, ": no ", args$product, " tile overlaps; skipped"); next }
    pieces  <- lapply(tile_rasters[hits], function(r) crop(r, block_ext, snap = "out"))
    cropped <- if (length(pieces) > 1) do.call(merge, unname(pieces)) else pieces[[1]]
    cropped <- cropped[[1:3]]
    names(cropped) <- c("Red", "Green", "Blue")
    img_name <- paste0(block, ".tif")
    writeRaster(cropped, file.path(crop_dir, img_name), overwrite = TRUE, datatype = "INT1U")

    # Map coordinates -> pixel indices (origin top-left), clipped to the crop
    e <- ext(cropped); rx <- res(cropped)[1]; ry <- res(cropped)[2]
    bb <- do.call(rbind, lapply(st_geometry(sa), function(g) as.numeric(st_bbox(g))))
    px <- data.frame(
      image_path = img_name,
      xmin  = pmax(0,             round((bb[, 1] - e$xmin) / rx)),
      ymin  = pmax(0,             round((e$ymax - bb[, 4]) / ry)),
      xmax  = pmin(ncol(cropped), round((bb[, 3] - e$xmin) / rx)),
      ymax  = pmin(nrow(cropped), round((e$ymax - bb[, 2]) / ry)),
      label = "Tree", stringsAsFactors = FALSE)
    n_in <- nrow(px)
    px <- px[px$xmax > px$xmin & px$ymax > px$ymin, ]     # drop boxes collapsed by rounding
    annotations[[block]] <- px

    block_rows[[length(block_rows) + 1]] <- data.frame(
      product = args$product, split = split, site = site, block = block, image = img_name,
      tile = paste(tiles$tile[hits], collapse = ";"), n_annotated = n_in, n_kept = nrow(px),
      width_px = ncol(cropped), height_px = nrow(cropped))
    cat(sprintf("  %-40s %4d crowns (%d dropped) %dx%d px\n", block, nrow(px), n_in - nrow(px),
                ncol(cropped), nrow(cropped)))
  }

  out <- do.call(rbind, annotations)
  write.csv(out, file.path(crop_dir, "annotations.csv"), row.names = FALSE, quote = FALSE)
  cat("Wrote", nrow(out), "annotations to", file.path(crop_dir, "annotations.csv"), "\n")
}

blocks <- do.call(rbind, block_rows)
write.csv(blocks, cs_rpath(cfg, "tables", paste0("annotation_blocks_", args$product, ".csv")), row.names = FALSE)
print(aggregate(n_kept ~ split, blocks, sum))
