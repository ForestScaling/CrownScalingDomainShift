#!/bin/bash
#SBATCH --job-name=cs01_annotations
#SBATCH --account=PUOM0017
#SBATCH --time=2:00:00
#SBATCH --mem=32G
#SBATCH --output=logs/slurm/%x_%j.out
source slurm/env_R.sh
Rscript pipeline/01_annotations/prepare_annotations.R --product "$PRODUCT"
