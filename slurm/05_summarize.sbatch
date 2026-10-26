#!/bin/bash
#SBATCH --job-name=cs05_summarize
#SBATCH --account=PUOM0017
#SBATCH --time=3:00:00
#SBATCH --mem=96G
#SBATCH --output=logs/slurm/%x_%j.out
source slurm/env_R.sh
Rscript pipeline/05_crown_metrics/summarize_crowns.R --site "$SITE"
