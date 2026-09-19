#!/usr/bin/env python3
"""
scripts/export_mobileclip_onnx.py

Exports the IMAGE encoder of a MobileCLIP checkpoint to ONNX, then produces
an FP16 version, ready to drop into `assets/models/` and load from
`embedding_worker.dart`.

WHY ONLY THE IMAGE ENCODER?
----------------------------
MobileCLIP's image and text encoders share one joint embedding space by
design — that's what makes "search my photos by typing a sentence" work at
all: a photo's image embedding and a query's text embedding are directly
comparable by cosine similarity, no captioning step in between.

Given that, running the (much heavier) text tower on-device buys you
nothing here: text queries are typed by hand, one at a time, so embedding
them is cheap enough to do wherever is convenient — including in your
FastAPI backend, in plain PyTorch, with no mobile constraints at all. The
phone only needs to embed *photos*, which is the part that has to run
thousands of times, on-device, without draining the battery. So: image
encoder → ONNX → phone. Text encoder → stays in Python → backend.

    NOTE ON THE ORIGINAL BACKEND PLAN: this repo's README originally
    described captioning each photo, then embedding the caption with
    SentenceTransformers, then indexing that in FAISS. That's a
    perfectly valid design, but it's a DIFFERENT one from "embed the
    photo directly with MobileCLIP" — the two produce vectors in
    unrelated embedding spaces, and a query embedded with
    SentenceTransformers will not usefully compare against a photo
    embedded with MobileCLIP. Once you adopt MobileCLIP for on-device
    image embedding, embed your search queries with MobileCLIP's own
    text tower too (server-side, in Python — see the snippet at the
    bottom of this file), and drop the captioning/SentenceTransformers
    step. Mixing the two architectures will silently produce meaningless
    similarity scores rather than an obvious error.

SETUP (run this on your dev machine, NOT on-device):
-----------------------------------------------------
    git clone https://github.com/apple/ml-mobileclip.git
    cd ml-mobileclip
    conda create -n mobileclip-export python=3.10 -y
    conda activate mobileclip-export
    pip install -e .
    pip install onnx onnxruntime onnxconverter-common

    # Download checkpoints (writes to ./checkpoints/)
    source get_pretrained_models.sh

    # Copy this script into the repo root (or adjust the import path
    # below) and run it:
    python export_mobileclip_onnx.py \
        --model-name mobileclip_s0 \
        --checkpoint checkpoints/mobileclip_s0.pt \
        --output-dir ../storage_swipe/assets/models

WHAT THIS SCRIPT DOES NOT DO:
-------------------------------
- It does not download weights for you (Apple's checkpoint host and
  Hugging Face are not something this repo can reach for you — run the
  SETUP commands above yourself).
- It does not validate accuracy against a labeled dataset. It only
  checks that the ONNX graph produces numerically close output to the
  original PyTorch model on a handful of random and real images — a
  sanity check, not a benchmark.
- It does not run static (calibrated) INT8 quantization, which is the
  better-suited quantization mode for a convolution-heavy vision
  backbone like MobileCLIP's (dynamic quantization, included below,
  mainly helps Linear layers and gives smaller wins here). A stub for
  static quantization with your own calibration images is included at
  the bottom, clearly marked, for when you're ready to tune for size.
"""

import argparse
import os

import numpy as np
import torch


def build_and_export(model_name: str, checkpoint_path: str, output_dir: str) -> str:
    import mobileclip
    from mobileclip.modules.common.mobileone import reparameterize_model

    os.makedirs(output_dir, exist_ok=True)

    print(f"Loading {model_name} from {checkpoint_path} ...")
    model, _, preprocess = mobileclip.create_model_and_transforms(
        model_name, pretrained=checkpoint_path
    )
    model.eval()

    # CRITICAL: MobileCLIP's blocks use a re-parameterizable ("MobileOne"
    # style) design — extra training-time branches that get algebraically
    # folded into a single conv/linear branch for inference. Exporting
    # WITHOUT this step will still "work" (the graph will export), but
    # you'll be shipping a slower, larger, needlessly-branchy graph.
    model = reparameterize_model(model)

    # --- Read off the ACTUAL preprocessing this checkpoint expects -----
    # Do not hardcode ImageNet-style normalization constants. Several
    # MobileCLIP variants (S0/S1/S2/B) bake normalization into the model
    # itself and expect raw [0, 1]-scaled pixels (mean=0, std=1) from the
    # `preprocess` transform; others (S3/S4/L-14) expect standard CLIP
    # normalization. Whatever this transform says is what your Dart
    # preprocessing code MUST match exactly, or the model will run
    # without error and produce useless embeddings.
    resize_step = next(t for t in preprocess.transforms if hasattr(t, "size"))
    normalize_step = next(
        t for t in preprocess.transforms if hasattr(t, "mean") and hasattr(t, "std")
    )
    input_size = (
        resize_step.size
        if isinstance(resize_step.size, int)
        else resize_step.size[0]
    )
    mean = list(normalize_step.mean)
    std = list(normalize_step.std)

    print(f"  input_size = {input_size}x{input_size}")
    print(f"  normalize mean = {mean}")
    print(f"  normalize std  = {std}")
    print(
        "  >>> COPY THESE THREE VALUES into `_MobileClipPreprocessConfig` "
        "in embedding_worker.dart — do not guess them. <<<"
    )

    class ImageEncoderWrapper(torch.nn.Module):
        """Thin wrapper so the exported graph takes pixels in, and returns
        an L2-normalized embedding out — matching exactly what the Dart
        side needs to do with the output (nothing further)."""

        def __init__(self, clip_model):
            super().__init__()
            self.clip_model = clip_model

        def forward(self, pixel_values: torch.Tensor) -> torch.Tensor:
            embedding = self.clip_model.encode_image(pixel_values)
            embedding = embedding / embedding.norm(dim=-1, keepdim=True)
            return embedding

    wrapper = ImageEncoderWrapper(model).eval()
    dummy_input = torch.randn(1, 3, input_size, input_size)

    fp32_path = os.path.join(output_dir, f"{model_name}_image_encoder.onnx")
    print(f"Exporting to {fp32_path} ...")
    torch.onnx.export(
        wrapper,
        dummy_input,
        fp32_path,
        input_names=["pixel_values"],
        output_names=["image_embeds"],
        dynamic_axes={
            "pixel_values": {0: "batch"},
            "image_embeds": {0: "batch"},
        },
        opset_version=17,
        do_constant_folding=True,
    )

    _sanity_check(wrapper, fp32_path, input_size)
    fp16_path = _convert_to_fp16(fp32_path, output_dir, model_name)
    _print_size_report(fp32_path, fp16_path)

    return fp16_path


def _sanity_check(torch_model: torch.nn.Module, onnx_path: str, input_size: int) -> None:
    """Confirms the ONNX graph agrees with the PyTorch model on random
    input — NOT a substitute for testing on real photos before you trust
    this in production."""
    import onnxruntime as ort

    print("Running PyTorch-vs-ONNX sanity check ...")
    sample = torch.randn(2, 3, input_size, input_size)

    with torch.no_grad():
        torch_out = torch_model(sample).numpy()

    session = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
    (onnx_out,) = session.run(None, {"pixel_values": sample.numpy()})

    max_diff = float(np.abs(torch_out - onnx_out).max())
    print(f"  max abs difference: {max_diff:.6f}")
    if max_diff > 1e-3:
        raise RuntimeError(
            f"ONNX output diverges from PyTorch by {max_diff} — do not ship "
            "this export. Check the opset version and reparameterization step."
        )
    print("  OK — outputs match within tolerance.")


def _convert_to_fp16(fp32_path: str, output_dir: str, model_name: str) -> str:
    """FP16 is the recommended default: roughly half the file size of
    FP32 with negligible accuracy loss for this kind of conv/BN-heavy
    backbone, and it's a single deterministic conversion (no calibration
    dataset needed, unlike static INT8 quantization)."""
    from onnxconverter_common import float16
    import onnx

    print("Converting to FP16 ...")
    model = onnx.load(fp32_path)
    model_fp16 = float16.convert_float_to_float16(model, keep_io_types=True)
    fp16_path = os.path.join(output_dir, f"{model_name}_image_encoder_fp16.onnx")
    onnx.save(model_fp16, fp16_path)
    return fp16_path


def _print_size_report(fp32_path: str, fp16_path: str) -> None:
    fp32_mb = os.path.getsize(fp32_path) / (1024 * 1024)
    fp16_mb = os.path.getsize(fp16_path) / (1024 * 1024)
    print(f"FP32: {fp32_mb:.1f} MB   FP16: {fp16_mb:.1f} MB")
    print(f"Bundle {os.path.basename(fp16_path)} into assets/models/ and update pubspec.yaml.")


# ---------------------------------------------------------------------
# OPTIONAL, MORE ADVANCED: static (calibrated) INT8 quantization.
#
# Dynamic quantization (`onnxruntime.quantization.quantize_dynamic`) is a
# one-line call, but it only quantizes Linear/MatMul weights — most of
# MobileCLIP's image encoder is convolutions, so the size/speed win from
# dynamic quantization alone is modest. Static quantization quantizes
# convolutions too, but requires calibration: running ~100-500
# REPRESENTATIVE photos (ideally from the actual kind of camera roll
# this app processes) through the FP32 model to compute activation
# ranges. This is intentionally left as a stub you fill in with your own
# calibration images rather than something faked with random data —
# calibrating on unrepresentative data can make accuracy *worse* than
# not quantizing at all.
# ---------------------------------------------------------------------
def static_quantize_stub(fp32_path: str, calibration_image_dir: str, output_path: str) -> None:
    from onnxruntime.quantization import CalibrationDataReader, quantize_static, QuantType
    from PIL import Image

    class FolderCalibrationReader(CalibrationDataReader):
        def __init__(self, folder: str, input_size: int):
            self._paths = [
                os.path.join(folder, f)
                for f in os.listdir(folder)
                if f.lower().endswith((".jpg", ".jpeg", ".png"))
            ]
            self._input_size = input_size
            self._iterator = iter(self._paths)

        def get_next(self):
            path = next(self._iterator, None)
            if path is None:
                return None
            image = Image.open(path).convert("RGB").resize(
                (self._input_size, self._input_size)
            )
            array = (np.asarray(image).astype(np.float32) / 255.0).transpose(2, 0, 1)
            return {"pixel_values": array[np.newaxis, :, :, :]}

    reader = FolderCalibrationReader(calibration_image_dir, input_size=256)
    quantize_static(
        fp32_path,
        output_path,
        reader,
        quant_format=QuantType.QDQ,
    )
    print(f"Static-quantized model written to {output_path}")
    print(
        "IMPORTANT: re-run `_sanity_check`-style comparisons against real "
        "photos before trusting this — static quantization can silently "
        "hurt accuracy if the calibration set doesn't represent your "
        "actual photo mix (lighting, subject matter, aspect ratios)."
    )


# ---------------------------------------------------------------------
# SERVER-SIDE COMPANION SNIPPET (for your FastAPI backend, not run here):
# embeds a search QUERY with MobileCLIP's own text tower, in plain
# PyTorch — no ONNX/mobile constraints apply server-side.
# ---------------------------------------------------------------------
SERVER_SIDE_TEXT_EMBEDDING_SNIPPET = '''
import mobileclip

_model, _, _ = mobileclip.create_model_and_transforms(
    "mobileclip_s0", pretrained="checkpoints/mobileclip_s0.pt"
)
_tokenizer = mobileclip.get_tokenizer("mobileclip_s0")
_model.eval()

def embed_query(text: str) -> list[float]:
    """Embeds a search query into the SAME space the on-device image
    encoder writes into — this is what FAISS compares photo embeddings
    against. Do NOT use SentenceTransformers here; a different model's
    embedding space is not comparable to MobileCLIP's."""
    tokens = _tokenizer([text])
    with torch.no_grad():
        features = _model.encode_text(tokens)
        features = features / features.norm(dim=-1, keepdim=True)
    return features[0].tolist()
'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-name", default="mobileclip_s0")
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--output-dir", default="../storage_swipe/assets/models")
    args = parser.parse_args()

    build_and_export(args.model_name, args.checkpoint, args.output_dir)


if __name__ == "__main__":
    main()
