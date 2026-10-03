# Third-party models shipped in this application

The SOV app carries three TensorFlow Lite models as assets. They are binary files, so a
licence scanner cannot read them and a reader cannot tell where they came from. This file
says, so that nobody has to guess.

All three run **entirely on the citizen's device**. None of them sends anything anywhere.

| File | Size | MD5 | What it does |
|---|---|---|---|
| `assets/models/svrn_model.tflite` | 12,181,341 B | `d7623258ad30e4cc73f3a02f0e3052c8` | Palm detection in the viewfinder (2 classes: LEFT / RIGHT palm), 320×320 |
| `assets/models/blazeface_short.tflite` | 229,032 B | `fc0e8679f646a62f51cad3edd143bcc2` | Face detection for the liveness challenge, 128×128 |
| `assets/models/mobilefacenet.tflite` | 5,233,552 B | `7945c78f4484c99560df461df85baa2f` | Face embedding (192-d) for one-human-one-account deduplication, 112×112 |

---

## 1. `svrn_model.tflite` — SOV's own palm detector, with an inherited licence question

**What it is.** Trained by the SOV project on public data: the *11k Hands* dataset (palmar
left and palmar right images) with bounding boxes generated from MediaPipe hand landmarks,
plus COCO 2017 images as hard negatives. Two classes, 320×320 input, INT8 quantised. The
training script is published in this repository at `tools/training/svrn_v28_retrain.py` —
the data, the class definitions, the augmentation and the seed are all in it.

**The inherited question, stated plainly.** That script fine-tunes from `yolov8n.pt`, the
pretrained weights published by Ultralytics, using the Ultralytics library
(`svrn_v28_retrain.py:434-436`). **Ultralytics YOLOv8 is licensed AGPL-3.0**, and
Ultralytics' own position is:

> "All Ultralytics YOLO trained models fall under the AGPL-3.0 License by default. The
> AGPL-3.0 License covers the training code and the models produced by that training code."

They extend that to models trained from scratch with no pretrained weights at all.

**Why this repository is nevertheless published under Apache-2.0, and where the argument is
weak.** Two things are true at once and both are recorded here rather than one of them:

- *The case that nothing is owed.* The weights in this file were produced by training on
  SOV's own data, for SOV's own classes. The GNU project's own position is that the output
  of a program is not covered by that program's licence, and the US Copyright Office has
  questioned whether model weights attract copyright at all. On that reading
  `svrn_model.tflite` is SOV's work.
- *The case against.* The model was **initialised from Ultralytics' pretrained weights**,
  not from scratch. "Trained with their code" is the weak half of their claim; "derived from
  their weights" is the strong half, and it applies here.

The question is unsettled in law, and this project is not going to pretend otherwise in
either direction.

**What SOV does about it.** The one thing AGPL-3.0 actually demands is that the
corresponding source be published. It is: the whole application, the node, and the training
script that produced this model are all in public repositories, and the node source hashes
byte-for-byte to the `source_root` the live network runs. Anyone may reproduce this model
from the published script and check it.

**Anyone redistributing this application should read the above and reach their own
conclusion**, particularly if they intend to distribute it under terms that GPL-family
copyleft would not permit.

## 2. `blazeface_short.tflite` — MediaPipe, Apache-2.0

Google's BlazeFace short-range face detector, taken unmodified from the official
`mediapipe-assets` distribution. MediaPipe is licensed **Apache-2.0**, the same licence as
this project, so there is no tension here. The MD5 above is the upstream file's.

Used only to locate a face in the frame during the liveness challenge, and to decode the six
facial keypoints the turn challenge is measured from. It does not identify anyone.

## 3. `mobilefacenet.tflite` — pretrained, exact upstream NOT RECORDED

A pretrained MobileFaceNet face-embedding model (112×112 → 192-d). It was adopted on
2026-07-15 (`docs/V28_DUAL_PALM_LAUNCH_REPORT_20260715.md`) as a deliberate choice not to
train a face model, which would need millions of identities.

🔴 **The exact upstream source and licence of this file are not recorded anywhere in this
project.** That is a real gap, and inventing an answer here would be worse than admitting
it. MobileFaceNet is an architecture published in an academic paper, and TFLite conversions
of it circulate under several different licences; which one this file came from is not
documented. Establishing it — or replacing the file with one of known provenance — is
outstanding work.

What *is* established about it: it runs on-device only, it outputs a vector and never an
image, and the vector is transformed by a secret network-derived rotation before any node
stores it.

---

## Why this file exists

Until 2026-09-30 this repository declared Apache-2.0 and said nothing about any of the
above. Shipping a model with an inherited licence question, and a second model of unrecorded
provenance, while claiming a single clean licence, is the kind of thing that makes "you can
check everything yourself" untrue in a small way — and a project whose whole argument is
verifiability cannot afford small untruths.

Nothing here changes the licence of SOV's own source, which remains Apache-2.0 for the
reasons recorded in `docs/LICENSING_DECISION_20260801.md`.
