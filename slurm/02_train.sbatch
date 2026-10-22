#!/bin/bash
#SBATCH --job-name=cs02_train
#SBATCH --account=PUOM0017
#SBATCH --time=12:00:00
#SBATCH --gpus-per-node=1
#SBATCH --output=logs/slurm/%x_%j.out
source slurm/env_python.sh
nvidia-smi || echo "WARNING: no GPU visible; training will run on CPU"
python pipeline/02_train/train.py --product "$PRODUCT" ${EXTRA:-}
