source(file.path(Sys.getenv("LMOD_PKG"), "init/R"))
module("load", "proj/9.2.1")
module("load", "gdal/3.7.3")

dyn.load("/apps/spack/0.21/pitzer/linux-rhel9-skylake/proj/gcc/12.3.0/9.2.1-buhooyr/lib64/libproj.so")
dyn.load("/apps/spack/0.21/pitzer/linux-rhel9-skylake/gdal/gcc/12.3.0/3.7.3-wmnbnyd/lib64/libgdal.so")

library(neonUtilities)
library(neonOS)
library(terra)

setwd("/fs/ess/PUOM0017/ForestScaling/DeepForest/Imagery/")

NEON_TOKEN<-read.delim("../NEON_token_AE",header = FALSE)[1,1]

site_list<-c("BART","HARV")

for (i in (length(site_list)-1):length(site_list)) {
  
  print(site_list[i])
  
  byFileAOP(dpID = "DP3.30012.001",
            site = site_list[i],
            year = 2019,
            token = NEON_TOKEN,
            savepath = "./NEON/",
            check.size = FALSE) 
}
