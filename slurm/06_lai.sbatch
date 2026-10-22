#!/bin/bash
#SBATCH --job-name=cs06_lai
#SBATCH --account=PUOM0017
#SBATCH --time=3:00:00
#SBATCH --mem=32G
#SBATCH --output=logs/slurm/%x_%j.out
source slurm/env_R.sh
Rscript pipeline/06_size_abundance/extract_grid_lai.R --site "$SITE"
