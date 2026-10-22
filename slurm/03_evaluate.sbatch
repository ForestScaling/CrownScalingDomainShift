#!/bin/bash
#SBATCH --job-name=cs03_evaluate
#SBATCH --account=PUOM0017
#SBATCH --time=2:00:00
#SBATCH --output=logs/slurm/%x_%j.out
source slurm/env_python.sh
python pipeline/03_evaluate/evaluate.py --product "$PRODUCT" --model "${MODEL:-trained}"
