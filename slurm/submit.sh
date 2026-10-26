#!/bin/bash
# =============================================================================
# submit.sh  -  one entry point for every stage. Run from anywhere.
#
#   bash slurm/submit.sh retile      HARV 60
#   bash slurm/submit.sh annotations NAIP30
#   bash slurm/submit.sh train       NAIP30 [--fast-dev-run]
#   bash slurm/submit.sh evaluate    NAIP30 [trained|prebuilt]
#   bash slurm/submit.sh predict     NAIP30 HARV [trained|prebuilt]
#   bash slurm/submit.sh filter      NAIP30 HARV     (re-apply CHM filter, no re-predict)
#   bash slurm/submit.sh grid        HARV
#   bash slurm/submit.sh crowns      NAIP30 HARV [neon_chm|morford]
#   bash slurm/submit.sh summarize   HARV            (assess crowns before alpha)
#   bash slurm/submit.sh lai         HARV
#   bash slurm/submit.sh alpha       NAIP30 HARV [neon_chm|morford]
#
# Array sizes are counted from the data at submit time (tiles, crown files,
# grid-cell chunks), never hardcoded. Prints the job id on success.
# Email: Slurm mails your OSC account address. Set CS_MAIL_TYPE=ALL to also get
# start notices, or NONE to turn mail off.
# =============================================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
mkdir -p logs/slurm
MAX_PREDICT_TASKS=${MAX_PREDICT_TASKS:-20}

stage=${1:?stage required}; shift
MAIL_TYPE=${CS_MAIL_TYPE:-END,FAIL}
sb() { sbatch --parsable --mail-type="$MAIL_TYPE" "$@"; }

case "$stage" in
  retile)      sb --export=ALL,SITE=$1,RES=$2 slurm/00_retile.sbatch ;;
  annotations) sb --export=ALL,PRODUCT=$1 slurm/01_annotations.sbatch ;;
  train)       sb --export=ALL,PRODUCT=$1,EXTRA="${2:-}" slurm/02_train.sbatch ;;
  evaluate)    sb --export=ALL,PRODUCT=$1,MODEL=${2:-trained} slurm/03_evaluate.sbatch ;;
  predict)
    source slurm/env_python.sh
    n=$(python pipeline/04_predict/predict_tiles.py --product "$1" --site "$2" --list-only)
    tasks=$(( n < MAX_PREDICT_TASKS ? n : MAX_PREDICT_TASKS ))
    echo "Submitting $tasks tasks for $n tiles" >&2
    sb --array=1-"$tasks" --export=ALL,PRODUCT=$1,SITE=$2,MODEL=${3:-trained} slurm/04_predict.sbatch ;;
  filter)      sb --export=ALL,PRODUCT=$1,SITE=$2 slurm/04_filter.sbatch ;;
  grid)        sb --export=ALL,SITE=$1 slurm/05_make_grid.sbatch ;;
  summarize)   sb --export=ALL,SITE=$1 slurm/05_summarize.sbatch ;;
  crowns)
    source slurm/env_R.sh
    n=$(Rscript pipeline/05_crown_metrics/crown_metrics.R --product "$1" --site "$2" --count | tr -d ' ')
    echo "Submitting $n tasks (one per crown shapefile)" >&2
    sb --array=1-"$n" --export=ALL,PRODUCT=$1,SITE=$2,HEIGHT=${3:-neon_chm} slurm/05_crown_metrics.sbatch ;;
  lai)         sb --export=ALL,SITE=$1 slurm/06_lai.sbatch ;;
  alpha)
    source slurm/env_R.sh
    n=$(Rscript pipeline/06_size_abundance/recover_alpha.R --product "$1" --site "$2" --height "${3:-neon_chm}" --count-chunks | tr -d ' ')
    echo "Submitting $n chunk tasks" >&2
    sb --array=1-"$n" --export=ALL,PRODUCT=$1,SITE=$2,HEIGHT=${3:-neon_chm} slurm/06_recover_alpha.sbatch ;;
  *) echo "Unknown stage: $stage" >&2; exit 1 ;;
esac
