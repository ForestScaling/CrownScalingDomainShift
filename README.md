# CrownScalingValidation

Scalability of DeepForest crown segmentation across imagery resolutions in northeastern
US forests. I fine-tune DeepForest on BART annotations, evaluate on geographically
isolated HARV annotations, predict crowns across the NEON AOP extents, and recover
size-abundance parameters (alpha, N_tot) at 1 ha for comparison against the published
10 cm NEON crowns (Weinstein et al. 2021).

This repo consolidates `AlysonEast/Crown_Segmentation` and
`AlysonEast/ScalingAcrossResolution`. Data stays in place on OSC; the repo can live
anywhere and finds data through `config/paths.yaml`. `CHANGES.md` maps every old script
to its replacement and lists the bugs fixed during consolidation.

## Products and height sources

| Key | Imagery | Resolution | Crowns |
|---|---|---|---|
| `NEON10` | NEON AOP RGB | 0.1 m | Published Weinstein et al. crowns (no prediction step) |
| `NAIP30` | NAIP (VT, NH, MA 2023) | 0.3 m | Fine-tuned DeepForest |
| `NAIP60` | NAIP (2021) | 0.6 m | Fine-tuned DeepForest, same annotations as NAIP30 |

| Height source | Data | Used for |
|---|---|---|
| `neon_chm` (default) | NEON LiDAR CHM, DP3.30015.001, 1 km tiles | 3 m crown filter at prediction; crown height and DBH |
| `morford` | Morford et al. (2026) 0.6 m CHM, GEE export chunks per site (EPSG:4326), read as a virtual mosaic | Crown height and DBH, to test operational height data outside NEON |

Crown geometry (area, perimeter, diameter, grid cell) is always measured in the site's
NEON UTM CRS, so only the height extraction changes between sources.

## Layout

```
config/
  paths.yaml              data roots and file-layout templates
  products.yaml           products, sites, height sources, thresholds, priors
  annotation_blocks.csv   hand-made: block -> split, site, forest_type
src/
  python/cs_utils.py      shared Python helpers (config, model loading, projection, CHM filter)
  R/utils.R               shared R helpers (config, args, tile ids, grid, height rasters)
pipeline/
  00_acquire/             downloads (run once) and NAIP retiling to the NEON tile grid
  01_annotations/         QGIS boxes -> DeepForest crops + annotations.csv per product
  02_train/               fine-tune DeepForest
  03_evaluate/            score against HARV test annotations (trained or out-of-box)
  04_predict/             tile-wide crown prediction + 3 m CHM filter
  05_crown_metrics/       1 ha grid; crown area, diameter, height, DBH
  06_size_abundance/      LAI per cell; alpha and N_tot per cell
slurm/
  submit.sh               single entry point for every stage
  *.sbatch                one wrapper per stage
  env_python.sh, env_R.sh module and environment setup
reports/                  tables and figures for the manuscript (not tracked in git)
logs/                     Slurm and training logs (not tracked in git)
archive/MAXAR/            MAXAR scripts, not part of the current pipeline
```

## Run order

Run from the repo root on OSC. Each `submit.sh` call is one Slurm submission. Array
sizes (tiles, crown files, grid-cell chunks) are counted from the data at submit time.

```bash
# --- once per product with new imagery --------------------------------------
bash slurm/submit.sh retile BART 60
bash slurm/submit.sh retile HARV 60

# --- segmentation, per product (NAIP30, NAIP60) -----------------------------
bash slurm/submit.sh annotations NAIP60
bash slurm/submit.sh train       NAIP60
bash slurm/submit.sh evaluate    NAIP60 trained
bash slurm/submit.sh evaluate    NAIP60 prebuilt      # out-of-box benchmark
bash slurm/submit.sh predict     NAIP60 HARV trained

# --- once per site ----------------------------------------------------------
bash slurm/submit.sh grid HARV
bash slurm/submit.sh lai  HARV

# --- size-abundance, per product x height source ----------------------------
bash slurm/submit.sh crowns NAIP60 HARV              # NEON CHM heights
bash slurm/submit.sh alpha  NAIP60 HARV
bash slurm/submit.sh crowns NAIP60 HARV morford      # Morford heights
bash slurm/submit.sh alpha  NAIP60 HARV morford
```

`NEON10` starts at `crowns` because its crowns are published. Wait for each stage to
finish before submitting the next; `grid` and `lai` must exist before `crowns` and
`alpha` for that site.

### Interactive runs

Every script also runs directly, which is the quickest way to test one tile or chunk:

```bash
python pipeline/04_predict/predict_tiles.py --product NAIP30 --site BART --tiles 316000_4881000
python pipeline/04_predict/predict_tiles.py --product NAIP30 --site BART --model prebuilt \
    --tiles 316000_4881000 --patch 400 --overlap 0.05 --out-subdir exploration
Rscript pipeline/05_crown_metrics/crown_metrics.R --product NAIP30 --site HARV --task-id 1 --height morford
Rscript pipeline/06_size_abundance/recover_alpha.R --product NAIP30 --site HARV --task-id 1
```

Exploration runs (`--out-subdir`) write to a subfolder that downstream stages never read.

## Outputs

Large outputs stay under the data roots, in product-keyed folders so 30 cm, 60 cm, and
height-source runs never mix. Small outputs go to `reports/` inside the repo.

| Stage | Output |
|---|---|
| annotations | `DeepForest/Imagery/NAIP/{Training,Testing}/Crop_Images_{product}/` (crops + `annotations.csv`); `reports/tables/annotation_blocks_{product}.csv` |
| train | `DeepForest/TrainedModels/{product}_BART_trained.pt`; `logs/train_{product}/` (loss log) |
| evaluate | `reports/tables/eval_{product}_{model}_{summary,detections}.csv`; `reports/figures/eval_{product}_{model}/` |
| predict | `DeepForest/Outputs/{product}/{site}/{product}_{model}_p{patch}_o{overlap}_t{thr}_f{focal}_{site}_{tile}.shp` |
| grid | `DeepForest/Shapefiles/{site}_grid_1ha.gpkg`, `{site}_grid_1ha_tiles.csv` |
| lai | `ScalingAcrossResolution/data/LAI/{site}_gridLAI.csv` |
| crowns | `ScalingAcrossResolution/data/CrownDatasets/{site}_{product}[_morford]_trees_{tile}.csv` |
| alpha | `ScalingAcrossResolution/Results/Parameters/{site}/{product}[_morford]/Chunks/*_{alpha,trees,skipped}.csv` |

Folders from the pre-consolidation code (`Outputs/NAIP/`, `Crop_Images/`,
`HARV_NAIP_trees_*`) are left untouched and are never read by this pipeline.

## Configuration

Settings that appear in the Methods live in `config/products.yaml`:

| Setting | Value | Notes |
|---|---|---|
| `detection.score_threshold` | 0.05 | applied to all models |
| `detection.iou_threshold` | 0.4 | evaluation match threshold |
| `detection.chm_min_height` | 3 m | mean NEON CHM within the crown |
| `training.epochs`, `training.seed` | 50, 42 | train site BART |
| `predict.patch_size`, `patch_overlap` | NAIP30: 200 px, 0.25; NAIP60: 100 px, 0.25 | both a 60 m focal view |
| `size_abundance.prior_mean`, `prior_sd` | 1.4, 0.3 | LAI-informed prior (Eichenwald et al. 2025) |
| `size_abundance.min_crowns_per_cell` | 75 | cells below this are skipped and logged |
| `height_sources.morford.scale` | 1.0 | values are metres |

Crown diameter follows Eichenwald et al. (2025): 0.5 · √(P² − 8A). DBH comes from
`itcSegment::dbh()` with crown diameter and zonal-max height.

## Git policy

Only code, config, and hand-made inputs are tracked. `reports/tables/`, `reports/figures/`,
`logs/`, `lightning_logs/`, and all rasters, shapefiles, and model weights are ignored
(see `.gitignore`). Avoid `git add -A`; add files by path.

## Status and next steps

Working: all stages through `predict` for NAIP30 and NAIP60; Morford heights added to
`crowns` and `alpha`.

Still to build:
- Evaluation by forest type (from `config/annotation_blocks.csv`), mAP, and the 30/60 cm overlay figure
- Crown count, size, height, and DBH comparisons across products and height sources
- Aggregation of alpha/N_tot chunks into 1 ha rasters, with 1:1 comparisons (R², RMSE, MAE, bias) against NEON10
- A `manuscript_numbers` export to fill the draft's placeholders
- A chained `run_all.sh` using Slurm dependencies

## Requirements

Python env `deepforest2` (miniconda3/24.1.2-py310): deepforest, rasterio, geopandas, pyyaml.
R 4.4.0 with gcc/12.3.0, proj/9.2.1, gdal/3.7.3: sf, terra, dplyr, data.table, yaml,
itcSegment, rstan, ScalingFromSky.
