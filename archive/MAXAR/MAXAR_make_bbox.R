library(sf)
library(dplyr)

# Read the extracted bounding box data
bbox_data <- read.csv("./MAXAR/bounding_boxes.csv")

# Function to create a polygon from bounding box
create_polygon <- function(row) {
  coords <- matrix(c(row$ULLON, row$ULLAT,
                     row$URLON, row$URLAT,
                     row$LRLON, row$LRLAT,
                     row$LLLON, row$LLLAT,
                     row$ULLON, row$ULLAT), # Close the polygon
                   ncol = 2, byrow = TRUE)
  st_polygon(list(coords))
}

# Convert each row into a spatial polygon
bbox_data_sf <- bbox_data %>%
  rowwise() %>%
  mutate(geometry = list(create_polygon(cur_data()))) %>%
  ungroup() %>%
  st_as_sf(crs = 4326) # Use WGS 84 projection

# Save as a shapefile
st_write(bbox_data_sf, "./MAXAR/bounding_boxes.shp", delete_layer = TRUE)

cat("Shapefile 'bounding_boxes.shp' created successfully!\n")
