"""
check_paths.py
--------------
Preflight: resolve every configured input and output location for each site
and product and report what exists. Cheap (file globs and header reads
only); run it before submitting expensive stages.

Usage:
    python pipeline/check_paths.py                 # all sites, all products
    python pipeline/check_paths.py --site HARV --product NAIP60

Exit status is 1 if a CHM tile is missing for any imagery tile, since that
silently degrades prediction and crown metrics.
"""

import argparse
import glob
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src" / "python"))
import cs_utils as cs  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--site", nargs="*", default=None)
ap.add_argument("--product", nargs="*", default=None)
args = ap.parse_args()

cfg = cs.load_config()
sites = args.site or list(cfg["sites"])
products = args.product or list(cfg["products"])
problems = 0


def line(label, ok, detail=""):
    print(f"  [{'OK' if ok else '--'}] {label:<34} {detail}")


for site in sites:
    s = cfg["sites"][site]
    print(f"\n== {site} ({s['split']}) ==")

    aop = cs.dpath(cfg, "site_aop_shapefile", site=site)
    line("AOP shapefile", os.path.exists(aop), aop)
    grid = cs.dpath(cfg, "site_grid_file", site=site)
    line("1 ha grid (make_grid.R)", os.path.exists(grid), grid)

    chm_all = glob.glob(cs.dpath(cfg, "chm_glob", site=site, tile="*", chm_year=s["chm_year"]))
    line("NEON CHM tiles", bool(chm_all), f"{len(chm_all)} files")
    chm_tiles = {cs.tile_id(f) for f in chm_all}

    mor = glob.glob(cs.dpath(cfg, "morford_glob", site=site))
    line("Morford CHM chunks", bool(mor), f"{len(mor)} files")
    lai = glob.glob(cs.dpath(cfg, "lai_glob", site=site, lai_year=s["lai_year"]))
    line("NEON LAI tiles", bool(lai), f"{len(lai)} files")
    lai_csv = os.path.join(cfg["scaling_root"], cfg["lai_dir"], f"{site}_gridLAI.csv")
    line("Grid LAI (extract_grid_lai.R)", os.path.exists(lai_csv), lai_csv)

    for product in products:
        p = cs.product_cfg(cfg, product)
        print(f"  -- {product}")
        if not p.get("published_crowns"):
            try:
                tiles = {t for t, _ in cs.list_tiles(cfg, product, site)}
            except FileNotFoundError:
                tiles = set()
            line("imagery tiles", bool(tiles), f"{len(tiles)} tiles")
            no_chm = sorted(tiles - chm_tiles)
            line("imagery tiles with a CHM", not no_chm and bool(tiles),
                 f"{len(tiles) - len(no_chm)}/{len(tiles)}" + (f"  missing e.g. {no_chm[:3]}" if no_chm else ""))
            problems += bool(no_chm)
            mp = cs.model_path(cfg, product)
            line("trained model", os.path.exists(mp), mp)
            crowns_dir = cs.dpath(cfg, "crowns_dir", product=product, site=site)
        else:
            crowns_dir = os.path.join(cfg["deepforest_root"], p["crowns_dir_override"].format(site=site))
        shp = glob.glob(os.path.join(crowns_dir, "*.shp"))
        raw = glob.glob(os.path.join(crowns_dir, "unfiltered", "*.shp"))
        line("crown shapefiles (predict)", bool(shp), f"{len(shp)} filtered, {len(raw)} unfiltered")
        for h in cfg["height_sources"]:
            label = product if h == "neon_chm" else f"{product}_{h}"
            csvs = glob.glob(os.path.join(cfg["scaling_root"], cfg["crown_datasets_dir"],
                                          f"{site}_{label}_trees_*.csv"))
            line(f"crown datasets ({h})", bool(csvs), f"{len(csvs)} files")

print(f"\n{'No blocking problems found.' if not problems else 'Missing CHM tiles: fix before predict/crowns.'}")
sys.exit(1 if problems else 0)
