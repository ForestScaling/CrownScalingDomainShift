# Phase 1 changes: consolidation and bug fixes

Source repos (unchanged, still on GitHub): `AlysonEast/Crown_Segmentation` @ 0e263e1,
`AlysonEast/ScalingAcrossResolution` @ b6e889f.

Phase 1 scope: one repo, config-driven paths, shared functions, and fixes to known bugs.
No new analyses yet (per-forest-type tables, mAP, Morford heights, aggregation, and
manuscript reports are Phases 2 to 4).

## Old script → new script

| Old | New |
|---|---|
| `prepareAnnotations.R` (+ archived `developTrainingData.R`, `developTestingData_step*.R`) | `pipeline/01_annotations/prepare_annotations.R --product` |
| `BART_30cm_NAIP_TrainModel.py` | `pipeline/02_train/train.py --product` |
| `HARV_30cm_NAIP_Trained_Evaluate.py` | `pipeline/03_evaluate/evaluate.py --product --model` |
| `BART_30cm_NAIP_Trained.py`, `HARV_30cm_NAIP_Trained.py`, `BART_{30,60}cm_NAIP_prebuilt.py` | `pipeline/04_predict/predict_tiles.py --product --site --model [--patch --overlap]` |
| grid code inside `GenerateDatasetsIndv.R` and `ExtractGridLAI.R` | `pipeline/05_crown_metrics/make_grid.R --site` |
| `GenerateDatasetsIndv.R` + `GenerateDatasets_{Batch,Slurm}.sh` | `pipeline/05_crown_metrics/crown_metrics.R` |
| `ExtractGridLAI.R` | `pipeline/06_size_abundance/extract_grid_lai.R --site` |
| `RecoverAlpha.R`, `RecoverAlphaParallel.R`, `RecoverAlphaParallel_weinstein.R`, `Alpha_Slurm*.sh` | `pipeline/06_size_abundance/recover_alpha.R` |
| `Imagery/NAIP_retile.R` | `pipeline/00_acquire/NAIP_retile.R --site --res` (logic unchanged) |
| `DeepForest.sh` and all stage Slurm scripts | `slurm/submit.sh <stage> ...` + `slurm/*.sbatch` |
| NEON/LiDAR/LAI download scripts | `pipeline/00_acquire/` (copied unchanged; run-once) |
| MAXAR scripts | `archive/MAXAR/` |
| `project()`, `filter_by_chm()`, model loading (copied in 6 scripts) | `src/python/cs_utils.py` |
| OSC module/dyn.load block (copied in 4 scripts) | `src/R/utils.R::cs_osc_env()` |

## Bugs fixed

| # | Where | Problem | Fix |
|---|---|---|---|
| 1 | `RecoverAlphaParallel.R` | `chunk_size <- args[1]` (task id); 9 tasks covered 45 cells | chunk size is its own argument; array size counted at submit |
| 2 | same | `_trees.csv` written from `alpha_results` | N_tot posterior written to `_trees.csv` |
| 3 | all alpha scripts | 4-tile test subset hardcoded | removed |
| 4 | same | `length(LAI)==0` never true; 75-crown floor commented out | `nrow()`; floor from config; skipped cells logged with reason |
| 5 | `prepareAnnotations.R` | all crops forced to EPSG:32619, rotating/resampling HARV (UTM 18N) test crops | imagery never reprojected; crops cut from production tiles in native CRS; annotation vectors transformed instead |
| 6 | `BART_30cm_NAIP_Trained.py` | CHM path not an f-string; CHM filter skipped for every BART tile | shared `find_chm()`; missing CHM warned and counted |
| 7 | both `*_Trained.py` | `torch.load("./TrainedModel")` (a directory); missing tile CSVs | shared `load_model()`; tiles listed from imagery |
| 8 | `BART_60cm_NAIP_prebuilt.py` | read the 30 cm raster; patch-100 output never written | single predict script, path from config |
| 9 | `GenerateDatasetsIndv.R` | CHM hardcoded to HARV; tile id by character position; column 14 dropped by index | site-aware CHM lookup; regex tile id; geometry dropped by name |
| 10 | `ExtractGridLAI.R` | crashed on tiles without LAI; output column name hardcoded to a HARV tile | skip check before mosaic; plain `grid_id, lai_val` output |
| 11 | prebuilt scripts | `int(133*0.3)` named files `f39` | focal view rounded |
| 12 | evaluate | wrote outputs to the working directory | `reports/tables`, `reports/figures` |

## Behaviour changes to review

These are deliberate, but each changes something you might compare against old outputs.

1. **Output folders are product-keyed** (`Outputs/NAIP30/HARV`, `Outputs/NAIP60/HARV`),
   so 30 and 60 cm crowns can't be globbed together downstream. Old `Outputs/NAIP/` is
   untouched. Crown CSVs are `{site}_{NAIP30|NAIP60|NEON10}_trees_{tile}.csv`, so old
   `HARV_NAIP_trees_*` files are never mixed in.
2. **Model file name**: `TrainedModels/NAIP30_BART_trained.pt` (was `NAIP_30cm_BART_trained.pt`).
   You're retraining on the new annotations, so the old file isn't read.
3. **Crops are regenerated** into `Imagery/NAIP/{split}/Crop_Images_{product}/` from the
   1 km tiles. The old `Crop_Images/` folder is untouched. Crop names = annotation
   shapefile names.
4. **Grid cells are dissolved** across AOP tile seams before crown assignment (LAI already
   did this). Crowns on a seam now compare overlap against the whole cell, not each piece.
5. **75-crown minimum is enforced** (README said it was; the code had it commented out).
   Set `size_abundance.min_crowns_per_cell` to 0 to reproduce the old behaviour.
6. **Score threshold is also set on the RetinaNet object** so 0.05 applies regardless of
   DeepForest version. torchvision's RetinaNet default is 0.05 anyway, so old runs
   should be unaffected.
7. **Training saves a Lightning CSV loss log** to `logs/train_{product}/` and seeds with 42.
   The two config lines DeepForest 2.x ignores (`epochs`, `save-snapshot`) are removed.
8. **NAIP60 prediction defaults** to patch 100, overlap 0.25 (60 m focal view, mirroring
   NAIP30's production setting). Marked CONFIRM in `config/products.yaml`.

## Not tested here

Python utilities were tested on synthetic rasters (projection, CHM filtering across CRSs
and nodata, tile/CHM discovery, filenames). DeepForest and R aren't available in my
environment, so the training/evaluation calls and every R script are untested. The
smoke-test order in README.md is designed to surface problems cheaply.
