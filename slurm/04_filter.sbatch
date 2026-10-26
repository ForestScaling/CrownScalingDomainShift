#!/bin/bash
#SBATCH --job-name=cs04_filter
#SBATCH --account=PUOM0017
#SBATCH --time=6:00:00
#SBATCH --mem=32G
#SBATCH --output=logs/slurm/%x_%j.out
source slurm/env_python.sh
python pipeline/04_predict/filter_crowns.py --product "$PRODUCT" --site "$SITE"
