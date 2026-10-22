"""
cs_utils.py
-----------
Shared helpers for the Python stages (train, evaluate, predict). Everything that
was previously copy-pasted across six scripts lives here once.

Paths come from config/paths.yaml and config/products.yaml; nothing here
hardcodes an OSC path.
"""

import glob
import os
import re
from pathlib import Path

import numpy as np
import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
TILE_RE = re.compile(r"(\d{6}_\d{7})")   # NEON 1 km tile id, e.g. 725000_4705000


# =============================================================================
# Configuration
# =============================================================================
def load_config():
    """Return a single dict merging paths.yaml and products.yaml."""
    with open(REPO_ROOT / "config" / "paths.yaml") as f:
        cfg = yaml.safe_load(f)
    with open(REPO_ROOT / "config" / "products.yaml") as f:
        cfg.update(yaml.safe_load(f))
    return cfg


def product_cfg(cfg, product):
    if product not in cfg["products"]:
        raise KeyError(f"Unknown product '{product}'. Options: {list(cfg['products'])}")
    return cfg["products"][product]


def dpath(cfg, key, **fmt):
    """Absolute path under deepforest_root for a templated key in paths.yaml."""
    return os.path.join(cfg["deepforest_root"], cfg[key].format(**fmt))


def repo_path(cfg, key, *parts):
    """Absolute path inside the repo for reports_dir / logs_dir."""
    p = REPO_ROOT / cfg[key] / Path(*parts) if parts else REPO_ROOT / cfg[key]
    p.parent.mkdir(parents=True, exist_ok=True)
    return str(p)


def tile_id(path):
    """Extract the NEON tile id from any filename; raises if absent."""
    m = TILE_RE.findall(os.path.basename(path))
    if not m:
        raise ValueError(f"No tile id found in {path}")
    return m[-1]


# =============================================================================
# Inputs
# =============================================================================
def list_tiles(cfg, product, site):
    """Sorted list of (tile_id, raster_path) for a product/site."""
    pattern = os.path.join(cfg["deepforest_root"],
                           product_cfg(cfg, product)["tile_glob"].format(site=site, tile="*"))
    files = sorted(glob.glob(pattern))
    if not files:
        raise FileNotFoundError(f"No imagery tiles match {pattern}")
    return [(tile_id(f), f) for f in files]


def find_chm(cfg, site, tile):
    """Path to the NEON CHM tile, or None. The visit folder is globbed."""
    year = cfg["sites"][site]["chm_year"]
    hits = glob.glob(dpath(cfg, "chm_glob", site=site, tile=tile, chm_year=year))
    if len(hits) > 1:
        raise RuntimeError(f"Multiple CHM files for {site} {tile}: {hits}")
    return hits[0] if hits else None


def model_path(cfg, product):
    site = cfg["training"]["train_site"]
    return os.path.join(cfg["deepforest_root"], cfg["trained_models_dir"],
                        f"{product}_{site}_trained.pt")


# =============================================================================
# Model loading
# =============================================================================
def load_model(cfg, product, kind):
    """
    kind = "prebuilt": DeepForest release weights (out-of-the-box benchmark).
    kind = "trained":  fine-tuned weights saved by 02_train/train.py.
    Score threshold is set on both the config and the underlying RetinaNet so it
    takes effect regardless of DeepForest version.
    """
    import torch
    from deepforest import main

    model = main.deepforest()
    if kind == "prebuilt":
        model.use_release()
    elif kind == "trained":
        weights = model_path(cfg, product)
        if not os.path.isfile(weights):
            raise FileNotFoundError(f"Trained weights not found: {weights}. Run 02_train first.")
        model.create_model()
        model.model.load_state_dict(torch.load(weights, map_location="cpu"))
    else:
        raise ValueError("kind must be 'prebuilt' or 'trained'")

    thr = cfg["detection"]["score_threshold"]
    model.config["score_threshold"] = thr
    if hasattr(model.model, "score_thresh"):
        model.model.score_thresh = thr
    model.model.eval()
    return model


# =============================================================================
# Geometry
# =============================================================================
def project(raster_path, boxes):
    """
    Convert image-pixel boxes from DeepForest into map coordinates of the source
    raster (after github.com/bw4sz gist). Returns a GeoDataFrame in the raster CRS.
    """
    import geopandas
    import rasterio
    import shapely

    with rasterio.open(raster_path) as src:
        bounds, (px, py), crs = src.bounds, src.res, src.crs

    boxes = boxes.copy()
    boxes["left"] = boxes["xmin"] * px + bounds.left
    boxes["right"] = boxes["xmax"] * px + bounds.left
    boxes["top"] = bounds.top - boxes["ymin"] * py
    boxes["bottom"] = bounds.top - boxes["ymax"] * py
    geoms = [shapely.geometry.box(l, b, r, t) for l, b, r, t in
             zip(boxes["left"], boxes["bottom"], boxes["right"], boxes["top"])]
    # DeepForest 1.4+ may already attach a pixel-space geometry column; replace it.
    boxes = boxes.drop(columns=["geometry"], errors="ignore")
    return geopandas.GeoDataFrame(boxes, geometry=geoms, crs=crs)


def filter_by_chm(boxes, chm_path, height_threshold=3):
    """
    Drop crowns whose mean CHM height is below height_threshold (m).
    Boxes are compared in the CHM CRS and returned in their original CRS.
    """
    import geopandas
    import rasterio
    from rasterio.mask import mask

    if len(boxes) == 0:
        return boxes
    orig_crs = boxes.crs
    keep = []
    with rasterio.open(chm_path) as src:
        work = boxes.to_crs(src.crs) if boxes.crs != src.crs else boxes
        nodata = src.nodata
        for geom in work.geometry:
            try:
                arr, _ = mask(src, [geom], crop=True, filled=False)
            except ValueError:            # box falls entirely outside the CHM tile
                keep.append(False)
                continue
            vals = arr[0].compressed().astype(float)
            if nodata is not None:
                vals = vals[vals != nodata]
            vals = vals[~np.isnan(vals)]
            keep.append(vals.size > 0 and vals.mean() >= height_threshold)
    out = boxes.loc[np.array(keep, dtype=bool)]
    return geopandas.GeoDataFrame(out, geometry="geometry", crs=orig_crs)


def crowns_filename(product, kind, patch, overlap, thr, res_m, site, tile):
    """Standard crown shapefile name. Focal view is rounded, not truncated."""
    focal = int(round(patch * res_m))
    return (f"{product}_{kind}_p{patch}_o{int(round(overlap * 1000)):03d}"
            f"_t{int(round(thr * 100)):03d}_f{focal}_{site}_{tile}.shp")
