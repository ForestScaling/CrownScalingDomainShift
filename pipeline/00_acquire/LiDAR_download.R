#install.packages("sf", repos = "http://cran.us.r-project.org")
#install.packages("terra", repos = "http://cran.us.r-project.org")
#install.packages("lidR", repos = "http://cran.us.r-project.org")
#install.packages("dsmSearch", repos = "http://cran.us.r-project.org")

#library(lidR)
library(neonUtilities)
library(neonOS)
#library(terra)
#library(dsmSearch)

setwd("/fs/ess/PUOM0017/ForestScaling/DeepForest/LiDAR/")
#setwd("/media/aly/Penobscot/ForestScaling/Crown_Segmentation/LiDAR")

NEON_TOKEN<-read.delim("../NEON_token_AE",header = FALSE)[1,1]

#Point clouds
#byFileAOP(dpID = "DP1.30003.001",
#          site = "HARV",
#          year = 2022,
#          token = NEON_TOKEN,
#          savepath = "./NEON/HARV/",
#          check.size = FALSE)

#CHM
byFileAOP(dpID = "DP3.30015.001",
          site = "HARV",
          year = 2022,
          token = NEON_TOKEN,
          savepath = "./NEON/HARV/",
          check.size = FALSE)

#DTM
#byFileAOP(dpID = "DP3.30024.001",
#          site = "BART",
#          year = 2022,
#          token = NEON_TOKEN,
#          savepath = "./NEON/BART/",
#          check.size = FALSE)

#byFileAOP(dpID = "DP3.30015.001",
#          site = "HARV",
#          year = 2022,
#          token = NEON_TOKEN,
#          savepath = "./NEON/HARV/",
#	  check.size = FALSE)
