#!/bin/bash
#SBATCH --job-name=cs05_crowns
#SBATCH --account=PUOM0017
#SBATCH --time=3:00:00
#SBATCH --mem=16G
#SBATCH --output=logs/slurm/%x_%A_%a.out
source slurm/env_R.sh
Rscript pipeline/05_crown_metrics/crown_metrics.R --product "$PRODUCT" --site "$SITE" \
  --task-id "$SLURM_ARRAY_TASK_ID" --height "${HEIGHT:-neon_chm}"
