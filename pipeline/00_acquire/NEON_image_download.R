library(neonUtilities)
library(neonOS)
library(terra)

setwd("/fs/ess/PUOM0017/ForestScaling/DeepForest/Imagery/")

NEON_TOKEN<-read.delim("../NEON_token_AE",header = FALSE)[1,1]

site_list<-c("ABBY","BART","BLAN","CLBJ","GUAN","HARV","KONZ",
             "MLBS","RMNP","SCBI","SERC","YELL")

for (i in (length(site_list)-1):length(site_list)) {

  print(site_list[i])

  byFileAOP(dpID = "DP3.30010.001",
            site = site_list[i],
            year = 2022,
            token = NEON_TOKEN,
            savepath = "./NEON/",
            check.size = FALSE) 
}
site_list<-c("BONA","DELA","JERC","LENO","NIWO","OSBS","SOAP","SJER","TALL","TEAK","WREF")

for (i in 1:length(site_list)) {

  print(site_list[i])

  byFileAOP(dpID = "DP3.30010.001",
            site = site_list[i],
            year = 2023,
            token = NEON_TOKEN,
            savepath = "./NEON/",
            check.size = FALSE) 
}
# byFileAOP(dpID = "DP3.30010.001",
#           site = "BART",
#           year = 2022,
#           token = NEON_TOKEN,
#           savepath = "./NEON/BART/",
# 	  check.size = FALSE)
# 
# byFileAOP(dpID = "DP3.30010.001",
#           site = "HARV",
#           year = 2022,
#           token = NEON_TOKEN,
#           savepath = "./NEON/HARV/",
# 	  check.size = FALSE)
