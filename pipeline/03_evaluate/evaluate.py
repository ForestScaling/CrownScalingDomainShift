"""
evaluate.py
-----------
Evaluate a model against the geographically isolated test annotations (HARV).
Replaces HARV_30cm_NAIP_Trained_Evaluate.py. --model prebuilt gives the
out-of-the-box benchmark on the same test crops.

Usage:
    python pipeline/03_evaluate/evaluate.py --product NAIP30 --model trained
    python pipeline/03_evaluate/evaluate.py --product NAIP30 --model prebuilt

Outputs (inside repo):
    reports/tables/eval_{product}_{model}_detections.csv   one row per ground-truth crown
    reports/tables/eval_{product}_{model}_summary.csv      overall recall/precision + settings
    reports/figures/eval_{product}_{model}/*.png           overlays (white = annotation,
                                                           salmon dashed = prediction)
Per-forest-type tables and mAP are added in Phase 2.
"""

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src" / "python"))
import cs_utils as cs  # noqa: E402

import geopandas  # noqa: E402
import matplotlib  # noqa: E402
matplotlib.use("Agg")
import matplotlib.patches as patches  # noqa: E402
import pandas as pd  # noqa: E402
from matplotlib import pyplot as plt  # noqa: E402
from PIL import Image  # noqa: E402
from shapely.geometry import box  # noqa: E402
from deepforest import evaluate  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--product", required=True)
ap.add_argument("--model", choices=["trained", "prebuilt"], default="trained")
ap.add_argument("--no-figures", action="store_true")
args = ap.parse_args()

cfg = cs.load_config()
test_site = next(s for s, v in cfg["sites"].items() if v["split"] == "Testing")
crop_dir = cs.dpath(cfg, "crop_dir", split="Testing", product=args.product)
csv_file = os.path.join(crop_dir, "annotations.csv")
if not os.path.isfile(csv_file):
    sys.exit(f"Test annotations not found: {csv_file}. Run 01_annotations first.")

model = cs.load_model(cfg, args.product, args.model)
tag = f"{args.product}_{args.model}"
iou = cfg["detection"]["iou_threshold"]

# ---- Predict on test crops and score ---------------------------------------
predictions = model.predict_file(csv_file=csv_file, root_dir=crop_dir)
ground_truth = pd.read_csv(csv_file)
ground_truth["geometry"] = [box(r.xmin, r.ymin, r.xmax, r.ymax) for r in ground_truth.itertuples()]
ground_truth = geopandas.GeoDataFrame(ground_truth, geometry="geometry")

result = evaluate.evaluate_boxes(predictions=predictions, ground_df=ground_truth,
                                 root_dir=crop_dir, iou_threshold=iou, savedir=None)

detections = result["results"]
detections.to_csv(cs.repo_path(cfg, "reports_dir", "tables", f"eval_{tag}_detections.csv"), index=False)

summary = pd.DataFrame([{
    "product": args.product, "model": args.model, "test_site": test_site,
    "n_images": ground_truth["image_path"].nunique(),
    "n_ground_truth": len(ground_truth), "n_predictions": len(predictions),
    "box_recall": result["box_recall"], "box_precision": result["box_precision"],
    "score_threshold": cfg["detection"]["score_threshold"], "iou_threshold": iou,
}])
summary.to_csv(cs.repo_path(cfg, "reports_dir", "tables", f"eval_{tag}_summary.csv"), index=False)
print(summary.T.to_string(header=False))

# ---- Overlay figures --------------------------------------------------------
if not args.no_figures:
    fig_dir = os.path.join(cs.REPO_ROOT, cfg["reports_dir"], "figures", f"eval_{tag}")
    os.makedirs(fig_dir, exist_ok=True)
    for image_name in ground_truth["image_path"].unique():
        fig, ax = plt.subplots(figsize=(10, 10))
        ax.imshow(Image.open(os.path.join(crop_dir, image_name)))
        for df, color, style in [(ground_truth, "white", "-"), (predictions, "lightsalmon", "--")]:
            for r in df[df["image_path"] == image_name].itertuples():
                ax.add_patch(patches.Rectangle((r.xmin, r.ymin), r.xmax - r.xmin, r.ymax - r.ymin,
                                               linewidth=2, edgecolor=color, linestyle=style,
                                               facecolor="none"))
        ax.set_title(f"{image_name}: {tag}")
        ax.axis("off")
        fig.savefig(os.path.join(fig_dir, f"{Path(image_name).stem}.png"), dpi=300, bbox_inches="tight")
        plt.close(fig)
