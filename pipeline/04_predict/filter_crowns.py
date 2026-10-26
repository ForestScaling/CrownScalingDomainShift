"""
filter_crowns.py
----------------
Apply (or re-apply) the CHM height filter to crown shapefiles that already
exist, without re-running DeepForest. Idempotent and safe to re-run.

On first run for a tile, the existing shapefile is moved to
    {crowns_dir}/unfiltered/
and the filtered result is written back to the original path. Later runs
always filter from the unfiltered copy, so nothing is filtered twice.
predict_tiles.py now writes the unfiltered copy itself, so this script is
only needed to repair runs made without a working CHM path, or to change
the height threshold.

Before touching any file, every tile is checked for a CHM; if any are
missing the script stops and lists them (use --allow-missing-chm to leave
those tiles unfiltered and continue).

Usage:
    python pipeline/04_predict/filter_crowns.py --product NAIP30 --site HARV
    python pipeline/04_predict/filter_crowns.py --product NAIP30 --site HARV --dry-run

Output:
    filtered shapefiles in {crowns_dir}; originals in {crowns_dir}/unfiltered/
    reports/tables/chm_filter_{product}_{site}.csv  (tile, n_unfiltered, n_kept, pct_kept)
"""

import argparse
import glob
import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src" / "python"))
import cs_utils as cs  # noqa: E402

import geopandas  # noqa: E402
import pandas as pd  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--product", required=True)
ap.add_argument("--site", required=True)
ap.add_argument("--allow-missing-chm", action="store_true")
ap.add_argument("--dry-run", action="store_true", help="report what would happen, change nothing")
args = ap.parse_args()

cfg = cs.load_config()
if cs.product_cfg(cfg, args.product).get("published_crowns"):
    sys.exit(f"{args.product} uses published crowns; nothing to filter.")
crowns_dir = cs.dpath(cfg, "crowns_dir", product=args.product, site=args.site)
raw_dir = os.path.join(crowns_dir, "unfiltered")
thr = cfg["detection"]["chm_min_height"]

# Production shapefiles are the top-level ones; also pick up tiles whose only
# copy is already in unfiltered/ (e.g. an interrupted previous run).
names = sorted({os.path.basename(f) for f in
                glob.glob(os.path.join(crowns_dir, "*.shp")) + glob.glob(os.path.join(raw_dir, "*.shp"))})
if not names:
    sys.exit(f"No crown shapefiles in {crowns_dir}")

# ---- Preflight: every tile needs a CHM before anything is changed ----------
chm = {n: cs.find_chm(cfg, args.site, cs.tile_id(n)) for n in names}
missing = [cs.tile_id(n) for n, p in chm.items() if p is None]
print(f"{len(names)} crown files; CHM found for {len(names) - len(missing)}")
if missing:
    print(f"Missing CHM for {len(missing)} tiles, e.g. {missing[:5]}")
    print("CHM glob:", cs.dpath(cfg, "chm_glob", site=args.site, tile="<tile>",
                                chm_year=cfg["sites"][args.site]["chm_year"]))
    if not args.allow_missing_chm:
        sys.exit("Stopping before changing any files. Fix config/paths.yaml chm_glob "
                 "or pass --allow-missing-chm.")
if args.dry_run:
    sys.exit("Dry run: no files changed.")


def move_shapefile(src_shp, dst_dir):
    os.makedirs(dst_dir, exist_ok=True)
    stem = os.path.splitext(src_shp)[0]
    for f in glob.glob(stem + ".*"):
        shutil.move(f, os.path.join(dst_dir, os.path.basename(f)))


rows = []
for i, name in enumerate(names, 1):
    tile = cs.tile_id(name)
    out_path, raw_path = os.path.join(crowns_dir, name), os.path.join(raw_dir, name)
    if not os.path.exists(raw_path):
        move_shapefile(out_path, raw_dir)
    raw = geopandas.read_file(raw_path)
    if chm[name] is None:
        kept = raw
    else:
        kept = cs.filter_by_chm(raw, chm[name], thr)
    kept.to_file(out_path, driver="ESRI Shapefile")
    rows.append({"tile": tile, "chm_found": chm[name] is not None, "n_unfiltered": len(raw),
                 "n_kept": len(kept), "pct_kept": round(100 * len(kept) / max(len(raw), 1), 1)})
    print(f"[{i}/{len(names)}] {tile}: {len(raw)} -> {len(kept)}")

log = pd.DataFrame(rows)
out = cs.repo_path(cfg, "reports_dir", "tables", f"chm_filter_{args.product}_{args.site}.csv")
log.to_csv(out, index=False)
print(f"\nKept {log.n_kept.sum()} of {log.n_unfiltered.sum()} crowns "
      f"({100 * log.n_kept.sum() / log.n_unfiltered.sum():.1f}%); log: {out}")
