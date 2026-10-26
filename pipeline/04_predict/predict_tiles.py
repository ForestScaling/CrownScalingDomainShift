"""
predict_tiles.py
----------------
Run a DeepForest model over 1 km imagery tiles, filter by CHM, and write crown
shapefiles. Replaces BART/HARV_30cm_NAIP_Trained.py and the four *_prebuilt.py
scripts (patch-size exploration is now --patch / --overlap flags).

Usage:
    # production run, one Slurm array task handles every n-th tile
    python pipeline/04_predict/predict_tiles.py --product NAIP30 --site HARV --model trained \
        --task-id $SLURM_ARRAY_TASK_ID --n-tasks $SLURM_ARRAY_TASK_COUNT
    # out-of-box exploration on one tile at a 120 m focal view
    python pipeline/04_predict/predict_tiles.py --product NAIP30 --site BART --model prebuilt \
        --tiles 314000_4876000 --patch 400 --overlap 0.05 --out-subdir exploration

Outputs:
    {deepforest_root}/Outputs/{product}/{site}[/{out_subdir}]/{product}_{model}_p.._o.._t.._f.._{site}_{tile}.shp
    Production runs (no --out-subdir) feed 05_crown_metrics; exploration runs go
    to a subfolder so they are never globbed downstream. Unfiltered predictions
    are kept in .../unfiltered/ so the CHM filter can be re-applied without
    re-predicting (see filter_crowns.py).
"""

import argparse
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src" / "python"))
import cs_utils as cs  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--product", required=True)
ap.add_argument("--site", required=True)
ap.add_argument("--model", choices=["trained", "prebuilt"], default="trained")
ap.add_argument("--patch", type=int, default=None, help="override products.yaml predict.patch_size")
ap.add_argument("--overlap", type=float, default=None, help="override predict.patch_overlap")
ap.add_argument("--tiles", nargs="*", default=None, help="subset of tile ids")
ap.add_argument("--task-id", type=int, default=1, help="1-based Slurm array index")
ap.add_argument("--n-tasks", type=int, default=1)
ap.add_argument("--out-subdir", default=None, help="write to a subfolder (exploration runs)")
ap.add_argument("--skip-existing", action="store_true")
ap.add_argument("--list-only", action="store_true", help="print tile count and exit")
ap.add_argument("--allow-missing-chm", action="store_true",
                help="continue (unfiltered) when a tile has no CHM; default is to stop before predicting")
args = ap.parse_args()

cfg = cs.load_config()
pcfg = cs.product_cfg(cfg, args.product)
if pcfg.get("published_crowns"):
    sys.exit(f"{args.product} uses published crowns; nothing to predict.")

tiles = cs.list_tiles(cfg, args.product, args.site)
if args.tiles:
    tiles = [t for t in tiles if t[0] in set(args.tiles)]
if args.list_only:
    print(len(tiles))
    sys.exit(0)
my_tiles = tiles[args.task_id - 1::args.n_tasks]
print(f"{args.product} {args.site} {args.model}: task {args.task_id}/{args.n_tasks}, "
      f"{len(my_tiles)} of {len(tiles)} tiles")

patch = args.patch or pcfg["predict"]["patch_size"]
overlap = args.overlap if args.overlap is not None else pcfg["predict"]["patch_overlap"]
thr = cfg["detection"]["score_threshold"]
out_dir = cs.dpath(cfg, "crowns_dir", product=args.product, site=args.site)
if args.out_subdir:
    out_dir = os.path.join(out_dir, args.out_subdir)
raw_dir = os.path.join(out_dir, "unfiltered")
os.makedirs(raw_dir, exist_ok=True)

# ---- Preflight: confirm every tile has a CHM before spending compute --------
chm_paths = {tile: cs.find_chm(cfg, args.site, tile) for tile, _ in my_tiles}
missing = [t for t, p in chm_paths.items() if p is None]
if missing:
    print(f"Missing CHM for {len(missing)} of {len(my_tiles)} tiles, e.g. {missing[:5]}")
    print("CHM glob:", cs.dpath(cfg, "chm_glob", site=args.site, tile="<tile>",
                                chm_year=cfg["sites"][args.site]["chm_year"]))
    if not args.allow_missing_chm:
        sys.exit("Stopping before prediction. Fix config/paths.yaml chm_glob or pass --allow-missing-chm.")

model = cs.load_model(cfg, args.product, args.model)

n_no_chm = 0
for tile, raster_path in my_tiles:
    out_path = os.path.join(out_dir, cs.crowns_filename(args.product, args.model, patch, overlap,
                                                        thr, pcfg["res_m"], args.site, tile))
    if args.skip_existing and os.path.exists(out_path):
        continue
    t0 = time.time()
    pred = model.predict_tile(raster_path, patch_size=patch, patch_overlap=overlap)
    if pred is None or len(pred) == 0:
        print(f"{tile}: no detections")
        continue
    boxes = cs.project(raster_path, pred)
    n0 = len(boxes)

    keep = [c for c in ["xmin", "ymin", "xmax", "ymax", "score", "label", "geometry"] if c in boxes]
    boxes = boxes[keep]
    boxes.to_file(os.path.join(raw_dir, os.path.basename(out_path)), driver="ESRI Shapefile")

    chm = chm_paths[tile]
    if chm is None:
        n_no_chm += 1
        print(f"{tile}: WARNING no CHM tile found; writing unfiltered crowns")
    else:
        boxes = cs.filter_by_chm(boxes, chm, cfg["detection"]["chm_min_height"])

    boxes.to_file(out_path, driver="ESRI Shapefile")
    print(f"{tile}: {n0} -> {len(boxes)} crowns after CHM filter ({time.time() - t0:.0f}s)")

print(f"Done. Tiles without CHM: {n_no_chm}")
