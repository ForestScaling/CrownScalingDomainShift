#!/bin/bash
#SBATCH --job-name=cs06_alphareport
#SBATCH --account=PUOM0017
#SBATCH --time=2:00:00
#SBATCH --mem=48G
#SBATCH --output=logs/slurm/%x_%j.out
source slurm/env_R.sh
Rscript pipeline/06_size_abundance/summarize_alpha.R --site "$SITE"
