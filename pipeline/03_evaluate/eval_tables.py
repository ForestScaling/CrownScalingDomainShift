"""
eval_tables.py
--------------
Model Evaluation tables for the manuscript, from saved predictions (no model
needed). For every evaluate.py run found in reports/tables, computes per test
block, per forest type, and overall:

    n_ground_truth, n_predictions, true_positives, recall, precision,
    mean_iou        mean IoU of each ground-truth crown with its assigned
                    prediction (0 if unassigned), as in DeepForest's results
    mean_iou_tp     mean IoU over true positives only
    ap40, ap50      average precision at IoU 0.4 (the evaluation threshold) and 0.5
    ap50_95         COCO mAP averaged over IoU 0.50:0.05:0.95

Matching for recall/precision/IoU follows DeepForest.evaluate_boxes: one-to-one
Hungarian assignment on IoU per image, true positive when IoU > threshold.
AP uses COCO-style greedy matching by descending score (IoU >= threshold) with
101-point interpolation.

Usage:  python pipeline/03_evaluate/eval_tables.py
Inputs: reports/tables/eval_{product}_{model}_predictions.csv (evaluate.py)
        {crop_dir}/annotations.csv for the Testing split
        config/annotation_blocks.csv (block -> forest_type)
Output: reports/tables/eval_by_block.csv, eval_by_forest_type.csv,
        eval_manuscript_table.csv (one row per product x model x forest type + Overall)
"""

import glob
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src" / "python"))
import cs_utils as cs  # noqa: E402

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
from scipy.optimize import linear_sum_assignment  # noqa: E402

COCO_THRESHOLDS = np.round(np.arange(0.5, 0.96, 0.05), 2)


def iou_matrix(a, b):
    """IoU between every box in a (n,4) and b (m,4), xmin ymin xmax ymax."""
    if len(a) == 0 or len(b) == 0:
        return np.zeros((len(a), len(b)))
    ix0 = np.maximum(a[:, None, 0], b[None, :, 0]); iy0 = np.maximum(a[:, None, 1], b[None, :, 1])
    ix1 = np.minimum(a[:, None, 2], b[None, :, 2]); iy1 = np.minimum(a[:, None, 3], b[None, :, 3])
    inter = np.clip(ix1 - ix0, 0, None) * np.clip(iy1 - iy0, 0, None)
    area_a = (a[:, 2] - a[:, 0]) * (a[:, 3] - a[:, 1])
    area_b = (b[:, 2] - b[:, 0]) * (b[:, 3] - b[:, 1])
    return inter / (area_a[:, None] + area_b[None, :] - inter)


def hungarian_iou(gt, pr):
    """Per ground-truth IoU with its one-to-one assigned prediction (0 if none)."""
    out = np.zeros(len(gt))
    if len(gt) and len(pr):
        m = iou_matrix(gt, pr)
        r, c = linear_sum_assignment(-m)
        out[r] = m[r, c]
    return out


def greedy_tp(gt, pr, scores, thr):
    """COCO greedy matching: returns TP flags for predictions in descending-score order."""
    order = np.argsort(-scores, kind="mergesort")
    tp = np.zeros(len(pr), dtype=bool)
    if len(gt) == 0:
        return scores[order], tp
    m = iou_matrix(pr[order], gt)
    taken = np.zeros(len(gt), dtype=bool)
    for i in range(len(order)):
        cand = np.where(~taken & (m[i] >= thr))[0]
        if cand.size:
            j = cand[np.argmax(m[i, cand])]
            taken[j] = tp[i] = True
    return scores[order], tp


def average_precision(per_image, thr):
    """101-point interpolated AP pooled over images. per_image: list of (gt, pr, scores)."""
    n_gt = sum(len(g) for g, _, _ in per_image)
    if n_gt == 0:
        return np.nan
    s_all, tp_all = [], []
    for g, p, s in per_image:
        s_sorted, tp = greedy_tp(g, p, s, thr)
        s_all.append(s_sorted); tp_all.append(tp)
    if not s_all or sum(len(s) for s in s_all) == 0:
        return 0.0
    s = np.concatenate(s_all); tp = np.concatenate(tp_all)
    order = np.argsort(-s, kind="mergesort"); tp = tp[order]
    ctp, cfp = np.cumsum(tp), np.cumsum(~tp)
    recall = ctp / n_gt
    precision = ctp / np.maximum(ctp + cfp, np.finfo(float).eps)
    precision = np.maximum.accumulate(precision[::-1])[::-1]       # monotone envelope
    rec_pts = np.linspace(0, 1, 101)
    idx = np.searchsorted(recall, rec_pts, side="left")
    return float(np.mean([precision[i] if i < len(precision) else 0.0 for i in idx]))


def metrics(images, iou_thr):
    """images: dict image -> (gt array, pred array, scores). Returns one metrics row."""
    gts = [g for g, _, _ in images.values()]
    n_gt = sum(len(g) for g in gts); n_pr = sum(len(p) for _, p, _ in images.values())
    ious = np.concatenate([hungarian_iou(g, p) for g, p, _ in images.values()]) if n_gt else np.array([])
    tp = int((ious > iou_thr).sum())
    per_image = list(images.values())
    return {
        "n_images": len(images), "n_ground_truth": n_gt, "n_predictions": n_pr, "true_positives": tp,
        "recall": tp / n_gt if n_gt else np.nan, "precision": tp / n_pr if n_pr else np.nan,
        "mean_iou": float(ious.mean()) if n_gt else np.nan,
        "mean_iou_tp": float(ious[ious > iou_thr].mean()) if tp else np.nan,
        "ap40": average_precision(per_image, iou_thr),
        "ap50": average_precision(per_image, 0.5),
        "ap50_95": float(np.mean([average_precision(per_image, t) for t in COCO_THRESHOLDS])),
    }


def stem(x):
    return os.path.splitext(os.path.basename(str(x)))[0]


def main():
    cfg = cs.load_config()
    iou_thr = cfg["detection"]["iou_threshold"]
    tables = os.path.join(cs.REPO_ROOT, cfg["reports_dir"], "tables")

    blocks = pd.read_csv(cs.REPO_ROOT / "config" / "annotation_blocks.csv")
    blocks["block"] = blocks["block"].map(stem)
    test_blocks = blocks[blocks["split"] == "Testing"].set_index("block")

    runs = sorted(glob.glob(os.path.join(tables, "eval_*_predictions.csv")))
    if not runs:
        sys.exit("No eval_*_predictions.csv found. Re-run evaluate.py (it now saves predictions).")

    by_block, by_type = [], []
    for f in runs:
        m = re.match(r"eval_(.+)_(trained|prebuilt)_predictions\.csv$", os.path.basename(f))
        product, model = m.group(1), m.group(2)
        crop_dir = cs.dpath(cfg, "crop_dir", split="Testing", product=product)
        gt = pd.read_csv(os.path.join(crop_dir, "annotations.csv"))
        pr = pd.read_csv(f)
        gt["block"], pr["block"] = gt["image_path"].map(stem), pr["image_path"].map(stem)

        unknown = sorted(set(gt["block"]) - set(test_blocks.index))
        if unknown:
            sys.exit(f"{product}: test blocks missing from config/annotation_blocks.csv: {unknown}")

        images = {}
        for b in sorted(gt["block"].unique()):
            g = gt.loc[gt.block == b, ["xmin", "ymin", "xmax", "ymax"]].to_numpy(float)
            p = pr.loc[pr.block == b]
            images[b] = (g, p[["xmin", "ymin", "xmax", "ymax"]].to_numpy(float), p["score"].to_numpy(float))

        for b, v in images.items():
            by_block.append({"product": product, "model": model, "block": b,
                             "forest_type": test_blocks.loc[b, "forest_type"], **metrics({b: v}, iou_thr)})
        groups = {t: [b for b in images if test_blocks.loc[b, "forest_type"] == t]
                  for t in sorted(test_blocks["forest_type"].unique())}
        groups["Overall"] = list(images)
        for t, bl in groups.items():
            if bl:
                by_type.append({"product": product, "model": model, "forest_type": t,
                                **metrics({b: images[b] for b in bl}, iou_thr)})
        print(f"{product} {model}: {len(images)} test blocks, {sum(len(v[0]) for v in images.values())} crowns")

    by_block, by_type = pd.DataFrame(by_block), pd.DataFrame(by_type)
    by_block.to_csv(os.path.join(tables, "eval_by_block.csv"), index=False)
    by_type.to_csv(os.path.join(tables, "eval_by_forest_type.csv"), index=False)

    ms = by_type[["product", "model", "forest_type", "true_positives", "recall", "precision",
                  "mean_iou", "ap40", "ap50_95"]].copy()
    for c in ["recall", "precision", "mean_iou", "ap40", "ap50_95"]:
        ms[c] = ms[c].round(3)
    ms.to_csv(os.path.join(tables, "eval_manuscript_table.csv"), index=False)
    print(ms.to_string(index=False))


if __name__ == "__main__":
    main()
