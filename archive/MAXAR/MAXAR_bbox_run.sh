#!/bin/bash
#SBATCH --job-name=bbox;  # Job name
#SBATCH --output=./outfiles/bbox.out    # Output file for each array task
#SBATCH --time=0:05:00 #5 min
#SBATCH --mail-type=ALL
#SBATCH --account=PUOM0017

module load gdal/3.3.1
module load sqlite/3.36.0
module load proj/8.1.0
module load R/4.4.0-gnu11.2

./extract_bbox_fromXML.sh
Rscript make_bbox.R 
