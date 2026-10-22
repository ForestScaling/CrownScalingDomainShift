"""
train.py
--------
Fine-tune the DeepForest release model on hand-annotated crops for one imagery
product. Replaces BART_30cm_NAIP_TrainModel.py; same procedure, parameterized.

Usage:
    python pipeline/02_train/train.py --product NAIP30
    python pipeline/02_train/train.py --product NAIP60 --fast-dev-run

Inputs:
    {crop_dir}/annotations.csv for the training split (01_annotations)
Outputs:
    {deepforest_root}/TrainedModels/{product}_{train_site}_trained.pt
    logs/train_{product}/   (Lightning CSV loss log)
"""

import argparse
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src" / "python"))
import cs_utils as cs  # noqa: E402

import pandas as pd  # noqa: E402
import torch  # noqa: E402
from deepforest import main  # noqa: E402

try:                                           # Lightning namespace differs by version
    from pytorch_lightning import seed_everything
    from pytorch_lightning.loggers import CSVLogger
except ImportError:
    from lightning.pytorch import seed_everything
    from lightning.pytorch.loggers import CSVLogger

ap = argparse.ArgumentParser()
ap.add_argument("--product", required=True)
ap.add_argument("--epochs", type=int, default=None, help="override config training.epochs")
ap.add_argument("--fast-dev-run", action="store_true", help="1 batch, for pipeline checks")
args = ap.parse_args()

cfg = cs.load_config()
cs.product_cfg(cfg, args.product)
site = cfg["training"]["train_site"]
split = cfg["sites"][site]["split"]
epochs = args.epochs or cfg["training"]["epochs"]
seed_everything(cfg["training"]["seed"], workers=True)

crop_dir = cs.dpath(cfg, "crop_dir", split=split, product=args.product)
annotations_file = os.path.join(crop_dir, "annotations.csv")
if not os.path.isfile(annotations_file):
    sys.exit(f"Annotations not found: {annotations_file}. Run 01_annotations first.")
annotations_df = pd.read_csv(annotations_file)
print(f"Training {args.product} on {len(annotations_df)} crowns in "
      f"{annotations_df['image_path'].nunique()} images ({site}), {epochs} epochs")

# ---- Model and trainer ------------------------------------------------------
# config["epochs"] is ignored by DeepForest 2.x; max_epochs on create_trainer is
# what takes effect. All config edits happen before create_trainer().
model = main.deepforest()
model.use_release()
model.config["train"]["csv_file"] = annotations_file
model.config["train"]["root_dir"] = crop_dir
model.config["train"]["fast_dev_run"] = args.fast_dev_run

logger = CSVLogger(save_dir=cs.repo_path(cfg, "logs_dir"), name=f"train_{args.product}")
model.create_trainer(max_epochs=epochs, logger=logger)
model.trainer.fit(model)

# ---- Checkpoint round-trip check ------------------------------------------
sample_image = os.path.join(crop_dir, annotations_df["image_path"].iloc[0])
pred_train = model.predict_image(path=sample_image)
with tempfile.TemporaryDirectory() as tmp:
    ckpt = os.path.join(tmp, "checkpoint.ckpt")
    model.trainer.save_checkpoint(ckpt)
    pred_reload = main.deepforest.load_from_checkpoint(ckpt).predict_image(path=sample_image)
try:
    assert pred_train is not None and not pred_train.empty, "no predictions after training"
    pd.testing.assert_frame_equal(pred_train, pred_reload)
    print("Checkpoint verification passed.")
except AssertionError as e:
    print(f"WARNING: checkpoint verification failed: {e}")

# ---- Save weights (state dict; loaded by cs_utils.load_model) --------------
if args.fast_dev_run:
    print("fast-dev-run: weights not saved.")
else:
    out = cs.model_path(cfg, args.product)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    torch.save(model.model.state_dict(), out)
    print(f"Model saved to: {out}")
