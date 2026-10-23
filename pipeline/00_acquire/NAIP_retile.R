# =============================================================================
# NAIP_retile.R
# Crop/mosaic NAIP scenes (exported from GEE) to the NEON 1 km LiDAR tile grid.
# Logic unchanged from Crown_Segmentation/Imagery/NAIP_retile.R; site and
# resolution are now arguments so the 60 cm product can be retiled the same way.
# Imagery is not reprojected (output keeps the NAIP scene CRS).
#
# Usage: Rscript pipeline/00_acquire/NAIP_retile.R --site HARV --res 60
# Input:  {deepforest_root}/Imagery/NAIP/{site}/{res}cm/*.tif
# Output: {deepforest_root}/Imagery/NAIP/{site}/{res}cm/match_NEON/NAIP_{res}cm_{site}_{visit}_{tile}.tif
# =============================================================================
cs_repo_root <- function() {
  f <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  if (length(f)) normalizePath(file.path(dirname(f), "..", "..")) else getwd()
}
source(file.path(cs_repo_root(), "src", "R", "utils.R"))
args <- cs_args(list(site = "REQUIRED", res = "REQUIRED"))
cfg  <- cs_config(cs_repo_root())
setwd(file.path(cfg$deepforest_root, "Imagery"))

res  <- as.integer(args$res)
site <- args$site

# Define paths
raster_dir <- paste0("./NAIP/",site,"/",res,"cm/")   # Directory containing .tif files
shapefile_path <- "../Shapefiles/LiDAR_Tiles.shp"  # Path to the shapefile
output_dir <- paste0("./NAIP/",site,"/",res,"cm/match_NEON/")  # Directory for cropped output rasters
dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

tif_files <- list.files(raster_dir, pattern = "\\.tif$", full.names = TRUE)

if (!length(tif_files)) stop("No NAIP scenes in ", normalizePath(raster_dir, mustWork = FALSE),
                             ". Export them from GEE first.")

# Define target projection (UTM Zone 19N)
#target_crs <- "EPSG:32619"

# Load shapefile
polygons <- st_read(shapefile_path)
head(polygons)
polygons<-polygons[grep(site, polygons$TileID),]
head(polygons)
dim(polygons)

#polygons<-subset(polygons, TileID!="2022_HARV_7_727000_4709000")

# Process each polygon separately
for (i in 1:nrow(polygons)) {
  poly <- polygons[i, ]  # Extract single polygon
  #poly <- st_transform(poly, target_crs)  # Reproject polygon to match target CRS
  poly_name <- substr(poly$TileID, 6, nchar(poly$TileID))
  poly_vect <- vect(poly)
  output_filename <- file.path(output_dir, paste0("NAIP_",res,"cm_", poly_name, ".tif"))

  # Identify and process intersecting raster tiles
  intersecting_rasters <- list()
  raster_index <- 1
 
  for (tif in tif_files) {
    r <- rast(tif)  # Load raster on-demand

    # Check for spatial intersection
    if (relate(ext(r), poly_vect, "intersects")) {
      print(r)
      cropped_raster <- crop(r, poly_vect)  # Crop before adding to list
      tmpfile <- tempfile(fileext = ".tif")
      writeRaster(cropped_raster, tmpfile, overwrite = TRUE)
      intersecting_rasters[[raster_index]] <- tmpfile
      raster_index <- raster_index + 1
      rm(cropped_raster); gc()
    }

    rm(r)  # Remove raster from memory after checking
    gc()
  }

  if (length(intersecting_rasters) == 0) {
    print(paste("No matching rasters for", poly_name))
    next  # Skip if no rasters intersect
  }

  # Mosaic if multiple rasters intersect
#  if (length(intersecting_rasters) > 3) {
#    message("Too many rasters intersect, skipping tile: ", poly_name)
#    next
#  }
  if (length(intersecting_rasters) > 1) {
    ras_list <- lapply(intersecting_rasters, rast)
    merged_raster <- do.call(mosaic, c(ras_list, list(fun = mean)))
  } else {
    merged_raster <- rast(intersecting_rasters[[1]])
  }

  # Reproject raster to UTM Zone 19N
#  reprojected_raster <- project(merged_raster, target_crs, method = "bilinear", res = target_res)

  # Mask the merged raster with the polygon
  masked_raster <- mask(merged_raster, poly_vect)
  masked_raster[is.nan(masked_raster)] <- NA  # Convert NaN to NA

  # Drop Band 4 (N_median), keep Band 1 (R), Band 2 (G), and Band 3 (B)
  bands <- c(1, 2, 3)
  masked_raster <- masked_raster[[bands]]

  # Convert to Byte format (0-255 range)
  masked_raster <- clamp(masked_raster, 0, 255)  # Ensure pixel values stay in 8-bit range
  #masked_raster <- as.int(masked_raster, "INT1U")  # Convert to 8-bit unsigned integer

  # Update band descriptions and ColorInterp to match NEON
  names(masked_raster) <- c("Red", "Green", "Blue")

  # Write output with appropriate metadata
  writeRaster(masked_raster, output_filename, overwrite = TRUE,
              datatype = "INT1U",  # Match NEON datatype
              gdal = c("COMPRESS=LZW", "TILED=YES", "INTERLEAVE=PIXEL"))
  print(paste("Saved:", output_filename))

  # Cleanup memory
  # rm(masked_raster, reprojected_raster, merged_raster, intersecting_rasters)
  rm(masked_raster, merged_raster, intersecting_rasters)
  terra::tmpFiles(remove = TRUE)
  gc()
}

