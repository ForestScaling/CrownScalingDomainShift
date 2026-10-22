# CrownScaling

Scalability of DeepForest crown segmentation across imagery resolutions in northeastern
US forests: fine-tune on BART, evaluate on HARV, predict across NEON AOP extents, and
recover size-abundance parameters (alpha, N_tot) at 1 ha.

Consolidates `Crown_Segmentation` and `ScalingAcrossResolution`. Data stays in place on
OSC; the repo can live anywhere and finds data through `config/paths.yaml`.

> Status: Phase 1 (consolidation + bug fixes). See `CHANGES.md`.

## Layout

```
config/paths.yaml       data roots and file-layout templates
config/products.yaml    products (NEON10, NAIP30, NAIP60), sites, thresholds, priors
src/python/cs_utils.py  shared Python helpers
src/R/utils.R           shared R helpers
pipeline/00_acquire     one-time downloads and NAIP retiling
pipeline/01_annotations QGIS boxes -> DeepForest crops + annotations.csv
pipeline/02_train       fine-tune DeepForest
pipeline/03_evaluate    score against HARV test annotations
pipeline/04_predict     tile-wide crown prediction + CHM filter
pipeline/05_crown_metrics  1 ha grid; crown area, diameter, height, DBH
pipeline/06_size_abundance LAI per cell; alpha and N_tot per cell
slurm/                  submit.sh + one .sbatch per stage
reports/                tables and figures for the manuscript (small, versioned)
logs/                   Slurm and training logs (git-ignored)
```

## Run order (per product)

Run everything from the repo root on OSC. Each line is one Slurm submission.

```bash
# once per product with new imagery
Rscript pipeline/00_acquire/NAIP_retile.R --site BART --res 60   # and HARV

bash slurm/submit.sh annotations NAIP60
bash slurm/submit.sh train       NAIP60
bash slurm/submit.sh evaluate    NAIP60 trained
bash slurm/submit.sh evaluate    NAIP60 prebuilt     # out-of-box benchmark
bash slurm/submit.sh predict     NAIP60 HARV trained

# once per site
bash slurm/submit.sh grid HARV
bash slurm/submit.sh lai  HARV

bash slurm/submit.sh crowns NAIP60 HARV
bash slurm/submit.sh alpha  NAIP60 HARV
# NEON10 (published Weinstein crowns) starts at `crowns`
```

## Phase 1 smoke tests

Cheapest first; each one exercises new code before committing compute.

1. `bash slurm/submit.sh annotations NAIP30`, then check
   `reports/tables/annotation_blocks_NAIP30.csv` (one row per block, crown counts) and open
   a crop or two in QGIS over the tile.
2. `bash slurm/submit.sh train NAIP30 --fast-dev-run` (one batch, no weights saved).
3. Full `train NAIP30`, then `evaluate NAIP30 trained` and `evaluate NAIP30 prebuilt`.
4. Predict two tiles interactively:
   `python pipeline/04_predict/predict_tiles.py --product NAIP30 --site BART --tiles 316000_4881000 320000_4879000`
   (BART CHM filtering was silently skipped before; confirm the "->" counts drop).
5. `grid HARV`, then `Rscript pipeline/05_crown_metrics/crown_metrics.R --product NEON10 --site HARV --task-id 1`
   and compare columns with an old `HARV_Weinstein_trees_*.csv`.
6. `Rscript pipeline/06_size_abundance/recover_alpha.R --product NEON10 --site HARV --count-chunks`
   then one chunk with `--task-id 1`.

## Requirements

Python env `deepforest2` (miniconda3/24.1.2-py310) with deepforest, rasterio, geopandas,
pyyaml. R 4.4.0 with sf, terra, dplyr, data.table, yaml, itcSegment, rstan,
ScalingFromSky. New dependency: R `yaml` (`install.packages("yaml")` if missing).
