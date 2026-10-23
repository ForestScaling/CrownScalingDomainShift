#!/bin/bash
#SBATCH --job-name=cs00_retile
#SBATCH --account=PUOM0017
#SBATCH --time=12:00:00
#SBATCH --mem=20G
#SBATCH --output=logs/slurm/%x_%j.out
source slurm/env_R.sh
Rscript pipeline/00_acquire/NAIP_retile.R --site "$SITE" --res "$RES"
