# ============================================================
# SVRN Palm Detection Model -- V28 Retraining Script
# ============================================================
# Architecture : YOLOv8n  (nano -- small enough for Unisoc T606)
# Classes      : 0 = LEFT palm (physical), 1 = RIGHT palm
# Input size   : 320x320, INT8 quantised TFLite output
# Training env : Google Colab with T4/A100 GPU (30-60 min)
#
# CHANGES FROM V27:
#   - AI-generated images (SVRN_Upload.zip) REMOVED entirely
#   - 11k Hands count raised: 1500 -> 2500 per class
#   - Bounding boxes: auto-generated via MediaPipe landmarks
#     (replaces hardcoded "0 0.5 0.5 0.9 0.9" approximation)
#   - Kaggle token: Colab Secrets (never plaintext)
#
# HOW TO RUN:
#   1. Rotate your Kaggle key at kaggle.com/settings first
#   2. In Colab: left sidebar -> ?? Secrets -> add KAGGLE_USERNAME + KAGGLE_KEY
#   3. Mount Google Drive (run the mount cell below first)
#   4. Paste this entire script into a Colab code cell and run
#   5. Output: Google Drive /svrn_training/svrn_v28_left_right/
# ============================================================

import os
import sys
import json
import shutil
import random
import time
from pathlib import Path

# -- 0. Environment setup -------------------------------------------------------
print("-- Step 0: Installing dependencies --")
os.system("pip install -q ultralytics mediapipe opencv-python-headless pandas requests")
# Colab ships an OUTDATED kaggle package pre-installed (2.0.2). A plain
# "pip install kaggle" is a no-op if any version is already present -- it must
# be forced with --upgrade, or the stale client mishandles the new KGAT_ token
# type on the download endpoint (403 Forbidden) even though auth checks pass.
os.system("pip install -q --upgrade kaggle")

import cv2
import numpy as np
import pandas as pd
import mediapipe as mp

# -- 1. Kaggle credentials (from Colab Secrets) --------------------------------
# Kaggle supports TWO auth methods -- we try the new one first:
#   (a) NEW token auth: a single 'KGAT_...' token written to ~/.kaggle/access_token
#       (or KAGGLE_API_TOKEN env var). NO username needed. This is what Kaggle's
#       own "Create New Token" UI issues today.
#   (b) CLASSIC auth: ~/.kaggle/kaggle.json with {username, key}. Needs BOTH --
#       a bare key with no username always 401s. Only used as a fallback for
#       older-style keys that don't start with 'KGAT_'.
print("\n-- Step 1: Kaggle credentials --")
from google.colab import userdata, drive

def _get_secret(*names):
    for n in names:
        try:
            v = userdata.get(n)
            if v:
                return n, v.strip()
        except Exception:
            pass
    return None, None

token_name, token_val = _get_secret('KAGGLE_API_TOKEN', 'KAGGLE_KEY')
_, kaggle_user         = _get_secret('KAGGLE_USERNAME')

if not token_val:
    sys.exit("STOP: Add your Kaggle token to Colab Secrets as KAGGLE_API_TOKEN (left sidebar -> "
             "key icon -> Add new secret -> enable Notebook access). Get one at kaggle.com/settings "
             "-> API -> Create New Token.")

kaggle_dir = Path.home() / '.kaggle'
kaggle_dir.mkdir(parents=True, exist_ok=True)

if token_val.startswith('KGAT_'):
    # New token-based auth -- no username required.
    os.environ['KAGGLE_API_TOKEN'] = token_val
    (kaggle_dir / 'access_token').write_text(token_val)
    os.chmod(kaggle_dir / 'access_token', 0o600)
    print(f"  Kaggle auth set via new access-token method (from {token_name}, no username needed).")
else:
    # Classic key format -- needs a paired username.
    if not kaggle_user:
        sys.exit("STOP: This looks like a classic Kaggle API key (not a 'KGAT_...' token), which "
                 "needs a paired username. Either add KAGGLE_USERNAME to Colab Secrets too, or "
                 "generate a new 'API Token' (not the old 'API Key') at kaggle.com/settings -- "
                 "the new token needs no username.")
    os.environ['KAGGLE_USERNAME'] = kaggle_user
    os.environ['KAGGLE_KEY']      = token_val
    (kaggle_dir / 'kaggle.json').write_text(json.dumps({'username': kaggle_user, 'key': token_val}))
    os.chmod(kaggle_dir / 'kaggle.json', 0o600)
    print(f"  Kaggle auth set via classic username+key method (user '{kaggle_user}').")

# Pre-flight: verify the credentials BEFORE the multi-GB download so we fail loudly here.
if os.system('kaggle datasets list -s 11k-hands > /dev/null 2>&1') != 0:
    sys.exit("STOP: Kaggle auth check failed. The token may be expired/revoked, or this Kaggle "
             "package version expects a different auth method. Regenerate a token at "
             "kaggle.com/settings -> API -> Create New Token, update the Colab secret, and re-run.")
print("  Kaggle credentials verified OK.")

# -- 2. Mount Google Drive ------------------------------------------------------
print("\n-- Step 2: Mounting Google Drive --")
try:
    drive.mount('/content/drive', force_remount=False)
    DRIVE_OUT = Path('/content/drive/MyDrive/svrn_training/svrn_v28_left_right')
    DRIVE_OUT.mkdir(parents=True, exist_ok=True)
    print(f"  Output directory: {DRIVE_OUT}")
except Exception as e:
    print(f"  WARNING: Could not mount Drive: {e}")
    DRIVE_OUT = Path('/content/svrn_v28_left_right')
    DRIVE_OUT.mkdir(parents=True, exist_ok=True)
    print(f"  Falling back to local: {DRIVE_OUT}")

# -- 3. Paths -------------------------------------------------------------------
WORK_DIR   = Path('/content/svrn_v28_work')
HANDS_DIR  = WORK_DIR / '11k_hands'
COCO_DIR   = WORK_DIR / 'coco_negatives'
DATASET    = WORK_DIR / 'dataset'
IMAGES_TR  = DATASET / 'images' / 'train'
LABELS_TR  = DATASET / 'labels' / 'train'
IMAGES_VAL = DATASET / 'images' / 'val'
LABELS_VAL = DATASET / 'labels' / 'val'

for d in [WORK_DIR, HANDS_DIR, COCO_DIR, IMAGES_TR, LABELS_TR, IMAGES_VAL, LABELS_VAL]:
    d.mkdir(parents=True, exist_ok=True)

# -- 4. Download 11k Hands dataset (Kaggle) ------------------------------------
# NOTE: different Kaggle mirrors of "11k Hands" (kmader/11k-hands vs
# shyambhu/hands-and-palm-images-dataset) unzip into DIFFERENT folder layouts.
# We never assume a fixed subfolder name -- everything below is found by
# rglob'ing for *.jpg / HandInfo.csv wherever they actually land.
print("\n-- Step 3: Downloading 11k Hands from Kaggle --")
import subprocess
existing_jpg_count = len(list(HANDS_DIR.rglob('*.jpg'))) if HANDS_DIR.exists() else 0
if existing_jpg_count < 1000:
    print("  Downloading dataset (this can take 2-5 minutes) ...")
    # subprocess.run (not os.system) so we CAPTURE the Kaggle CLI's actual stdout/stderr --
    # os.system only gives a numeric exit code, which hides the real reason for failure
    # (dataset terms not accepted, 404, auth scope issue, etc.)
    dl = subprocess.run(
        # NOTE: 'kmader/11k-hands' was REMOVED from Kaggle (site returns "We can't
        # find that page"; the API surfaces this as 403 Forbidden, not 404).
        # 'shyambhu/hands-and-palm-images-dataset' is the live mirror -- and the
        # one documented in docs/SVRN_MODEL_RETRAINING_GUIDE.md all along.
        ['kaggle', 'datasets', 'download', '-d', 'shyambhu/hands-and-palm-images-dataset', '--unzip', '-p', str(HANDS_DIR)],
        capture_output=True, text=True,
    )
    print(f"  kaggle download exit code: {dl.returncode}")
    if dl.stdout.strip():
        print(f"  kaggle stdout: {dl.stdout.strip()[:3000]}")
    if dl.stderr.strip():
        print(f"  kaggle stderr: {dl.stderr.strip()[:3000]}")
    # Show what was downloaded so we can debug if empty
    ls_out = subprocess.run(['find', str(HANDS_DIR), '-maxdepth', '4', '-type', 'f', '-name', '*.jpg', '-o', '-name', '*.csv'],
                            capture_output=True, text=True)
    sample_files = ls_out.stdout.strip().split('\n')[:10]
    print(f"  Files found in {HANDS_DIR} (sample): {sample_files}")
    top = [str(p) for p in HANDS_DIR.iterdir()] if HANDS_DIR.exists() else []
    print(f"  Top-level contents of {HANDS_DIR}: {top}")
else:
    print(f"  Already downloaded, skipping ({existing_jpg_count} jpgs found).")

found_csvs = list(HANDS_DIR.rglob('HandInfo.csv'))
if not found_csvs:
    all_csvs = list(HANDS_DIR.rglob('*.csv'))
    sys.exit(f"STOP: HandInfo.csv not found. Kaggle download likely failed (exit code above). CSVs found: {all_csvs}")
info_csv = found_csvs[0]
print(f"  HandInfo.csv found at: {info_csv}")

df = pd.read_csv(info_csv)
print(f"  Total rows in HandInfo.csv: {len(df)}")
print(df['aspectOfHand'].value_counts())

# -- 5. Build palm lists (palmar left / palmar right only) ---------------------
MAX_PER_CLASS = 2500

# Index every jpg found anywhere under HANDS_DIR by filename, regardless of
# which subfolder the Kaggle mirror actually extracted them into. If a
# filename appears more than once, first match wins (mirrors don't dupe names).
print("  Indexing downloaded images (this may take a moment) ...")
all_jpgs = list(HANDS_DIR.rglob('*.jpg'))
name_to_path = {}
for f in all_jpgs:
    name_to_path.setdefault(f.name, f)
print(f"  Indexed {len(all_jpgs)} jpg files ({len(name_to_path)} unique names).")

left_names  = set(df[df['aspectOfHand'] == 'palmar left' ]['imageName'].values)
right_names = set(df[df['aspectOfHand'] == 'palmar right']['imageName'].values)

left_files  = sorted([name_to_path[n] for n in left_names  if n in name_to_path])
right_files = sorted([name_to_path[n] for n in right_names if n in name_to_path])

random.seed(42)
random.shuffle(left_files)
random.shuffle(right_files)
left_files  = left_files[:MAX_PER_CLASS]
right_files = right_files[:MAX_PER_CLASS]

print(f"\n  Left palmar images selected : {len(left_files)}")
print(f"  Right palmar images selected: {len(right_files)}")

if len(left_files) < 500 or len(right_files) < 500:
    all_aspects = df['aspectOfHand'].value_counts().to_dict() if 'aspectOfHand' in df.columns else {}
    sample_csv_names = list(df['imageName'].values[:5]) if 'imageName' in df.columns else []
    sample_found_names = list(name_to_path.keys())[:5]
    sys.exit(
        f"STOP: Too few palm images found.\n"
        f"  Left palmar files found  : {len(left_files)}\n"
        f"  Right palmar files found : {len(right_files)}\n"
        f"  Total JPGs indexed under {HANDS_DIR}: {len(all_jpgs)}\n"
        f"  HandInfo.csv aspectOfHand counts: {all_aspects}\n"
        f"  Sample imageName values from CSV : {sample_csv_names}\n"
        f"  Sample filenames actually found  : {sample_found_names}\n"
        f"  (mismatch between these two rows usually means the Kaggle mirror's filenames\n"
        f"   don't match HandInfo.csv)\n"
        f"  (Need >= 500 per class to continue)"
    )

# -- 6. MediaPipe-based bounding box generation --------------------------------
# Uses hand landmarks to produce a tight bounding box instead of the
# hardcoded "0.5 0.5 0.9 0.9" used in V27.
print("\n-- Step 4: Generating bounding boxes via MediaPipe landmarks --")

# MediaPipe removed the legacy 'solutions' API in its 2025+ releases
# (AttributeError: module 'mediapipe' has no attribute 'solutions').
# Use it if present, otherwise fall back to the modern Tasks API
# (HandLandmarker) with Google's published hand_landmarker.task model.
USE_LEGACY_MP = hasattr(mp, 'solutions')
if USE_LEGACY_MP:
    mp_hands = mp.solutions.hands.Hands(
        static_image_mode=True,
        max_num_hands=1,
        min_detection_confidence=0.3,
    )
    def get_landmarks(rgb):
        res = mp_hands.process(rgb)
        if not res.multi_hand_landmarks:
            return None
        return res.multi_hand_landmarks[0].landmark
else:
    from mediapipe.tasks import python as mp_tasks
    from mediapipe.tasks.python import vision as mp_vision
    task_path = Path('/content/hand_landmarker.task')
    if not task_path.exists():
        os.system('wget -q https://storage.googleapis.com/mediapipe-models/hand_landmarker/'
                  f'hand_landmarker/float16/1/hand_landmarker.task -O {task_path}')
    _landmarker = mp_vision.HandLandmarker.create_from_options(
        mp_vision.HandLandmarkerOptions(
            base_options=mp_tasks.BaseOptions(model_asset_path=str(task_path)),
            num_hands=1,
            min_hand_detection_confidence=0.3,
            running_mode=mp_vision.RunningMode.IMAGE,
        ))
    def get_landmarks(rgb):
        mp_img = mp.Image(image_format=mp.ImageFormat.SRGB, data=np.ascontiguousarray(rgb))
        res = _landmarker.detect(mp_img)
        if not res.hand_landmarks:
            return None
        return res.hand_landmarks[0]
print(f"  MediaPipe path: {'legacy solutions' if USE_LEGACY_MP else 'Tasks API (hand_landmarker)'}")

FALLBACK_BOX = (0.5, 0.5, 0.88, 0.88)   # centre-crop fallback (V27-style but tighter)
PADDING      = 0.08                        # fraction of image to pad around palm box

def get_palm_box(img_path):
    """Run MediaPipe on one image. Return YOLO bbox (cx,cy,w,h) normalised, or fallback."""
    img = cv2.imread(str(img_path))
    if img is None:
        return FALLBACK_BOX, False
    h, w = img.shape[:2]
    rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    lm = get_landmarks(rgb)
    if lm is None:
        return FALLBACK_BOX, False
    xs = [l.x for l in lm]
    ys = [l.y for l in lm]
    x_min = max(0.0, min(xs) - PADDING)
    x_max = min(1.0, max(xs) + PADDING)
    y_min = max(0.0, min(ys) - PADDING)
    y_max = min(1.0, max(ys) + PADDING)
    cx = (x_min + x_max) / 2
    cy = (y_min + y_max) / 2
    bw = x_max - x_min
    bh = y_max - y_min
    return (cx, cy, bw, bh), True

def write_sample(src_path, cls_id, split_images, split_labels, tag):
    """Copy image + write YOLO label. Returns True on success."""
    box, found = get_palm_box(src_path)
    cx, cy, bw, bh = box
    # Skip images where the box is degenerate
    if bw < 0.05 or bh < 0.05:
        return False
    dst_img = split_images / src_path.name
    dst_lbl = split_labels / (src_path.stem + '.txt')
    shutil.copy2(src_path, dst_img)
    dst_lbl.write_text(f"{cls_id} {cx:.6f} {cy:.6f} {bw:.6f} {bh:.6f}\n")
    return True

# Train/val split: 85% train, 15% val
def split_idx(n, train_frac=0.85):
    cutoff = int(n * train_frac)
    return cutoff

total_written = {'train': 0, 'val': 0, 'skipped': 0}
label_map = {0: (left_files, 'LEFT'), 1: (right_files, 'RIGHT')}

for cls_id, (files, name) in label_map.items():
    cutoff = split_idx(len(files))
    splits = [('train', files[:cutoff], IMAGES_TR, LABELS_TR),
              ('val',   files[cutoff:], IMAGES_VAL, LABELS_VAL)]
    for split_name, split_files, img_dir, lbl_dir in splits:
        ok = skip = 0
        for i, f in enumerate(split_files):
            if write_sample(f, cls_id, img_dir, lbl_dir, split_name):
                ok += 1
            else:
                skip += 1
            if (i + 1) % 200 == 0:
                print(f"    {name} {split_name}: {i+1}/{len(split_files)} processed ...")
        total_written[split_name] += ok
        total_written['skipped'] += skip
        print(f"  {name} ({cls_id}) {split_name}: {ok} written, {skip} skipped")

if USE_LEGACY_MP:
    mp_hands.close()

# -- 7. COCO 2017 hard negatives -----------------------------------------------
print("\n-- Step 5: COCO hard negatives --")
COCO_ANN_URL = 'http://images.cocodataset.org/annotations/annotations_trainval2017.zip'
COCO_IMG_URL = 'http://images.cocodataset.org/zips/train2017.zip'
COCO_MAX     = 3000

# Categories to INCLUDE (objects commonly confused with hands)
TARGET_CATS = {
    'cup', 'bowl', 'bottle', 'vase', 'clock', 'chair', 'couch',
    'laptop', 'keyboard', 'cell phone', 'potted plant', 'book',
    'scissors', 'toothbrush', 'remote', 'spoon', 'fork', 'knife',
    'mouse', 'tv', 'backpack', 'handbag', 'umbrella',
}
# Categories to EXCLUDE (images that contain humans)
EXCLUDE_CATS = {'person', 'hand'}

coco_ann_zip = WORK_DIR / 'coco_ann.zip'
coco_img_zip = WORK_DIR / 'coco_images.zip'

if not (COCO_DIR / 'coco_annotations.json').exists():
    print("  Downloading COCO annotations (~240MB) ...")
    os.system(f'wget -q "{COCO_ANN_URL}" -O {coco_ann_zip}')
    os.system(f'unzip -q {coco_ann_zip} annotations/instances_train2017.json -d {COCO_DIR}')
    shutil.copy(COCO_DIR / 'annotations' / 'instances_train2017.json',
                COCO_DIR / 'coco_annotations.json')
    coco_ann_zip.unlink(missing_ok=True)

print("  Parsing COCO annotations ...")
with open(COCO_DIR / 'coco_annotations.json') as f:
    coco = json.load(f)

cat_id_to_name = {c['id']: c['name'] for c in coco['categories']}
exclude_ids    = {cid for cid, n in cat_id_to_name.items() if n in EXCLUDE_CATS}
target_ids     = {cid for cid, n in cat_id_to_name.items() if n in TARGET_CATS}

# Find images that contain a target category AND no person/hand
ann_by_img = {}
for ann in coco['annotations']:
    ann_by_img.setdefault(ann['image_id'], set()).add(ann['category_id'])

valid_img_ids = []
for img_id, cat_ids in ann_by_img.items():
    if cat_ids & target_ids and not (cat_ids & exclude_ids):
        valid_img_ids.append(img_id)

random.seed(99)
random.shuffle(valid_img_ids)
valid_img_ids = valid_img_ids[:COCO_MAX]

img_id_to_info = {img['id']: img for img in coco['images']}
coco_selected  = [img_id_to_info[i] for i in valid_img_ids if i in img_id_to_info]
print(f"  Selected {len(coco_selected)} COCO hard-negative images")

# Download COCO images individually (much faster than the full 18GB zip)
coco_raw = COCO_DIR / 'raw_images'
coco_raw.mkdir(exist_ok=True)

COCO_BASE = 'http://images.cocodataset.org/train2017/'
downloaded_coco = 0
for info in coco_selected:
    fn  = info['file_name']
    dst = coco_raw / fn
    if not dst.exists():
        os.system(f'wget -q "{COCO_BASE}{fn}" -O {dst}')
    if dst.exists():
        downloaded_coco += 1

print(f"  Downloaded {downloaded_coco}/{len(coco_selected)} COCO images")

# Copy into dataset -- 85% train, 15% val, empty label files (background)
coco_files   = sorted(coco_raw.glob('*.jpg'))[:downloaded_coco]
coco_cutoff  = int(len(coco_files) * 0.85)
coco_splits  = [('train', coco_files[:coco_cutoff], IMAGES_TR, LABELS_TR),
                ('val',   coco_files[coco_cutoff:], IMAGES_VAL, LABELS_VAL)]

for split_name, files, img_dir, lbl_dir in coco_splits:
    for f in files:
        shutil.copy2(f, img_dir / f.name)
        (lbl_dir / (f.stem + '.txt')).write_text('')   # empty = background
    print(f"  COCO {split_name}: {len(files)} background images")

# -- 8. Dataset YAML -----------------------------------------------------------
YAML_PATH = DATASET / 'svrn_v28.yaml'
yaml_content = f"""
path: {DATASET}
train: images/train
val: images/val
nc: 2
names:
  0: LEFT
  1: RIGHT
"""
YAML_PATH.write_text(yaml_content.strip())

n_train = len(list(IMAGES_TR.glob('*.jpg')))
n_val   = len(list(IMAGES_VAL.glob('*.jpg')))
print(f"\n-- Dataset ready --")
print(f"  Train: {n_train} images")
print(f"  Val  : {n_val} images")
print(f"  YAML : {YAML_PATH}")

# -- 9. Training ---------------------------------------------------------------
print("\n-- Step 6: Training YOLOv8n --")
from ultralytics import YOLO

model = YOLO('yolov8n.pt')

results = model.train(
    data     = str(YAML_PATH),
    epochs   = 150,
    imgsz    = 320,
    device   = 0,               # GPU; use 'cpu' if no GPU available (slow)
    batch    = 32,
    patience = 25,              # early stop if no improvement for 25 epochs
    # Augmentation -- critical: NO horizontal flip (fliplr=0.0) because
    # flipping LEFT palm makes it look like RIGHT palm -> corrupts class labels
    fliplr   = 0.0,
    mosaic   = 1.0,
    mixup    = 0.1,
    hsv_h    = 0.015,
    hsv_s    = 0.4,
    hsv_v    = 0.3,
    degrees  = 5.0,
    translate= 0.1,
    scale    = 0.4,
    shear    = 2.0,
    # Reproducibility
    seed     = 42,
    # Output
    project  = str(DRIVE_OUT),
    name     = 'train',
    exist_ok = True,
)

best_pt = DRIVE_OUT / 'train' / 'weights' / 'best.pt'
print(f"\n  Training complete. Best weights: {best_pt}")
if not best_pt.exists():
    print("  WARNING: best.pt not found -- check training logs above for errors")

# -- 10. Export to TFLite INT8 -------------------------------------------------
print("\n-- Step 7: Exporting to TFLite INT8 --")
if best_pt.exists():
    best_model = YOLO(str(best_pt))
    # INT8 quantisation requires a calibration dataset -- pass the val split
    best_model.export(
        format = 'tflite',
        int8   = True,
        imgsz  = 320,
        data   = str(YAML_PATH),
    )
    # The exported file lands beside best.pt
    tflite_src = best_pt.parent / 'best_saved_model' / 'best_float32.tflite'
    tflite_dst = DRIVE_OUT / 'svrn_v28_export.tflite'
    if tflite_src.exists():
        shutil.copy2(tflite_src, tflite_dst)
        print(f"\n  TFLite export: {tflite_dst}")
        print(f"  File size    : {tflite_dst.stat().st_size / 1024:.0f} KB")
    else:
        # Try alternative export path
        for f in (best_pt.parent / 'best_saved_model').rglob('*.tflite'):
            shutil.copy2(f, DRIVE_OUT / f.name)
            print(f"  TFLite export: {DRIVE_OUT / f.name}")
else:
    print("  SKIPPED: best.pt not found")

# -- 11. Validation metrics ----------------------------------------------------
print("\n-- Step 8: Running validation --")
if best_pt.exists():
    val_results = best_model.val(data=str(YAML_PATH), imgsz=320, device=0)
    print(f"\n  mAP50     : {val_results.box.map50:.4f}")
    print(f"  mAP50-95  : {val_results.box.map:.4f}")
    try:
        print(f"  LEFT  mAP50: {val_results.box.ap50[0]:.4f}  (target >= 0.85)")
        print(f"  RIGHT mAP50: {val_results.box.ap50[1]:.4f}  (target >= 0.85)")
    except Exception:
        pass

# -- 12. Summary ---------------------------------------------------------------
print("""
==========================================================
  SVRN V28 -- Training Complete
==========================================================
  Output location (Google Drive):
    /MyDrive/svrn_training/svrn_v28_left_right/

  Key files:
    svrn_v28_export.tflite  <- copy this to app
    train/weights/best.pt   <- PyTorch backup
    train/results.csv       <- training curves
----------------------------------------------------------
  Next steps:
  1. Verify mAP50 >= 0.85 for BOTH classes
  2. Download svrn_v28_export.tflite to PC
  3. Replace assets/models/svrn_model.tflite with new file
  4. flutter build apk --release
  5. Test on Itel S23 -- both palms > 70% confidence
==========================================================
""")
