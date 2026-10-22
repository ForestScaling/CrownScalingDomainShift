#!/bin/bash
#SBATCH --job-name=cs04_predict
#SBATCH --account=PUOM0017
#SBATCH --time=24:00:00
#SBATCH --mem=32G
#SBATCH --output=logs/slurm/%x_%A_%a.out
## Uncomment to run inference on GPU (faster, but array tasks may queue longer)
##SBATCH --gpus-per-node=1
source slurm/env_python.sh
python pipeline/04_predict/predict_tiles.py --product "$PRODUCT" --site "$SITE" --model "${MODEL:-trained}" \
  --task-id "$SLURM_ARRAY_TASK_ID" --n-tasks "$SLURM_ARRAY_TASK_COUNT" --skip-existing
