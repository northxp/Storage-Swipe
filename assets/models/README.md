Put the exported `.onnx` file here (see `scripts/export_mobileclip_onnx.py`).

Expected filename (matches `kMobileClipAssetPath` in
`lib/data/services/embedding_worker.dart` and the commented `assets:`
entry in `pubspec.yaml`):

    mobileclip_s0_image_encoder_fp16.onnx

This directory is intentionally empty in the repo — the model file is a
multi-megabyte binary derived from Apple's released MobileCLIP weights,
distributed under Apple's own model license, and isn't something to
check into a boilerplate/portfolio repo.
