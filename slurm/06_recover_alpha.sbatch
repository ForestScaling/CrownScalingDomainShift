#!/bin/bash
#SBATCH --job-name=cs06_alpha
#SBATCH --account=PUOM0017
#SBATCH --time=10:00:00
#SBATCH --mem=64G
#SBATCH --cpus-per-task=8
#SBATCH --output=logs/slurm/%x_%A_%a.out
source slurm/env_R.sh
export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK
Rscript pipeline/06_size_abundance/recover_alpha.R --product "$PRODUCT" --site "$SITE" \
  --task-id "$SLURM_ARRAY_TASK_ID" --ncores "$SLURM_CPUS_PER_TASK"
