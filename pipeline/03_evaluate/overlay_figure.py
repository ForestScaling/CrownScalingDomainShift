"""
overlay_figure.py
-----------------
Manuscript figure: HARV test blocks (rows) x imagery products (columns), with
hand annotations (white) and model predictions (salmon, dashed). Each panel is
labelled with that block's recall and precision from eval_by_block.csv.

Usage:
    python pipeline/03_evaluate/overlay_figure.py                      # trained models, NAIP30 + NAIP60
    python pipeline/03_evaluate/overlay_figure.py --model prebuilt
    python pipeline/03_evaluate/overlay_figure.py --products NAIP30 NAIP60 --min-score 0.3

Inputs:  test crops + annotations.csv per product; eval_{product}_{model}_predictions.csv
Output:  reports/figures/eval_overlay_{model}.png (and .pdf)
"""

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src" / "python"))
import cs_utils as cs  # noqa: E402

import matplotlib  # noqa: E402
matplotlib.use("Agg")
import matplotlib.patches as patches  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
import rasterio  # noqa: E402
import warnings  # noqa: E402
warnings.filterwarnings("ignore", category=rasterio.errors.NotGeoreferencedWarning)
from matplotlib import pyplot as plt  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--model", choices=["trained", "prebuilt"], default="trained")
ap.add_argument("--products", nargs="+", default=["NAIP30", "NAIP60"])
ap.add_argument("--min-score", type=float, default=None,
                help="only draw predictions at or above this score (default: all saved predictions)")
args = ap.parse_args()

cfg = cs.load_config()
tables = os.path.join(cs.REPO_ROOT, cfg["reports_dir"], "tables")
stem = lambda x: os.path.splitext(os.path.basename(str(x)))[0]  # noqa: E731

blocks = pd.read_csv(cs.REPO_ROOT / "config" / "annotation_blocks.csv")
blocks["block"] = blocks["block"].map(stem)
test = blocks[blocks["split"] == "Testing"].sort_values(["forest_type", "block"])
by_block_f = os.path.join(tables, "eval_by_block.csv")
by_block = pd.read_csv(by_block_f) if os.path.exists(by_block_f) else None

data = {}
for p in args.products:
    crop_dir = cs.dpath(cfg, "crop_dir", split="Testing", product=p)
    pred_f = os.path.join(tables, f"eval_{p}_{args.model}_predictions.csv")
    if not os.path.exists(pred_f):
        sys.exit(f"Missing {pred_f}; run evaluate.py --product {p} --model {args.model}")
    gt, pr = pd.read_csv(os.path.join(crop_dir, "annotations.csv")), pd.read_csv(pred_f)
    gt["block"], pr["block"] = gt["image_path"].map(stem), pr["image_path"].map(stem)
    if args.min_score is not None:
        pr = pr[pr["score"] >= args.min_score]
    data[p] = (crop_dir, gt, pr)

nr, nc = len(test), len(args.products)
fig, axes = plt.subplots(nr, nc, figsize=(3.2 * nc, 3.2 * nr), squeeze=False)
for i, row in enumerate(test.itertuples()):
    for j, p in enumerate(args.products):
        ax = axes[i, j]
        crop_dir, gt, pr = data[p]
        img_path = os.path.join(crop_dir, f"{row.block}.tif")
        ax.set_xticks([]); ax.set_yticks([])
        if not os.path.exists(img_path):
            ax.text(0.5, 0.5, "no crop", ha="center", va="center", transform=ax.transAxes)
            continue
        with rasterio.open(img_path) as src:
            img = np.moveaxis(src.read([1, 2, 3]), 0, -1)
        ax.imshow(img)
        for df, color, ls in [(gt, "white", "-"), (pr, "lightsalmon", "--")]:
            for r in df[df["block"] == row.block].itertuples():
                ax.add_patch(patches.Rectangle((r.xmin, r.ymin), r.xmax - r.xmin, r.ymax - r.ymin,
                                               linewidth=0.9, edgecolor=color, linestyle=ls, facecolor="none"))
        if by_block is not None:
            m = by_block[(by_block["product"] == p) & (by_block["model"] == args.model) &
                         (by_block["block"] == row.block)]
            if len(m):
                ax.text(0.02, 0.02, f"R {m.recall.iloc[0]:.2f}  P {m.precision.iloc[0]:.2f}",
                        transform=ax.transAxes, fontsize=7, color="white",
                        bbox=dict(facecolor="black", alpha=0.55, pad=1.5, linewidth=0))
        if i == 0:
            ax.set_title(f"{p} ({cfg['products'][p]['res_m']:g} m)", fontsize=10)
        if j == 0:
            ax.set_ylabel(f"{row.forest_type}\n({row.block.split('_')[-1]})", fontsize=9)

handles = [patches.Patch(edgecolor="white", facecolor="dimgray", linewidth=2, label="Hand annotation"),
           patches.Patch(edgecolor="lightsalmon", facecolor="dimgray", linewidth=2, linestyle="--",
                         label=f"{args.model.capitalize()} model prediction")]
fig.legend(handles=handles, loc="lower center", ncol=2, frameon=False, fontsize=9)
fig.tight_layout(rect=(0, 0.03, 1, 1))
out = os.path.join(cs.REPO_ROOT, cfg["reports_dir"], "figures", f"eval_overlay_{args.model}")
os.makedirs(os.path.dirname(out), exist_ok=True)
for ext in ("png", "pdf"):
    fig.savefig(f"{out}.{ext}", dpi=300, bbox_inches="tight")
print(f"Wrote {out}.png/.pdf ({nr} blocks x {nc} products)")
