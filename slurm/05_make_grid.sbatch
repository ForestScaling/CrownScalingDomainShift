#!/bin/bash
#SBATCH --job-name=cs05_grid
#SBATCH --account=PUOM0017
#SBATCH --time=1:00:00
#SBATCH --mem=16G
#SBATCH --output=logs/slurm/%x_%j.out
source slurm/env_R.sh
Rscript pipeline/05_crown_metrics/make_grid.R --site "$SITE"
