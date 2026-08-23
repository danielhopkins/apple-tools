# /// script
# requires-python = "==3.12.*"
# dependencies = ["torch==2.7.0", "transformers==4.48.3", "coremltools>=8.3", "numpy<2.4"]
# ///
"""Convert intfloat/e5-small-v2 to Core ML, pooling and normalising inside the graph.

🛑 The Core ML model must produce the SAME vector as sentence-transformers, not
just a similar one. sentence-transformers does three things after the encoder:
mean-pool over the attention mask, then L2-normalise. Both are traced into the
graph here, so the Swift side only has to tokenize.

  uv run convert.py --seq 128 --precision fp16 -o build/

Writes <name>.mlpackage plus a vocab.txt copy for the eventual Swift tokenizer.
"""
import argparse, json, os, shutil, sys, time

import numpy as np
import torch
import coremltools as ct
from transformers import AutoModel, AutoTokenizer

REPO = "intfloat/e5-small-v2"


def clamped_mask(attention_mask, input_shape, device=None, dtype=None):
    """An additive attention mask of -1e4 rather than `torch.finfo.min`.

    🛑 The default is -3.4e38, which overflows to -inf in fp16. coremltools
    warns about it during conversion. -1e4 is what the fp16-safe BERT
    implementations use, and it is far below any real logit.
    """
    extended = attention_mask[:, None, None, :].to(dtype or torch.float32)
    return (1.0 - extended) * -1e4


class Embedder(torch.nn.Module):
    """The encoder plus the two steps sentence-transformers does afterwards."""

    def __init__(self, encoder):
        super().__init__()
        self.encoder = encoder

    def forward(self, input_ids, attention_mask):
        hidden = self.encoder(input_ids=input_ids,
                              attention_mask=attention_mask).last_hidden_state
        mask = attention_mask.unsqueeze(-1).to(hidden.dtype)
        summed = (hidden * mask).sum(dim=1)
        counts = mask.sum(dim=1).clamp(min=1e-9)
        pooled = summed / counts
        return pooled / pooled.norm(dim=1, keepdim=True).clamp(min=1e-12)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--seq", type=int, default=128, help="fixed sequence length")
    p.add_argument("--enumerated", default=None,
                   help="comma-separated sequence lengths in ONE model, e.g. 64,128,256")
    p.add_argument("--batch", type=int, default=1, help="fixed batch size")
    p.add_argument("--precision", default="fp16", choices=["fp32", "fp16", "int8"])
    p.add_argument("-o", "--out", default="build")
    p.add_argument("--mask-clamp", action="store_true",
                   help="use a -1e4 additive mask instead of finfo.min")
    opts = p.parse_args()

    os.makedirs(opts.out, exist_ok=True)
    lengths = ([int(x) for x in opts.enumerated.split(",")]
               if opts.enumerated else [opts.seq])
    opts.seq = max(lengths)
    name = ("e5-small-v2-e%s-b%d-%s"
            % ("_".join(str(x) for x in lengths), opts.batch, opts.precision)
            if opts.enumerated else
            "e5-small-v2-s%d-b%d-%s" % (opts.seq, opts.batch, opts.precision))
    target = os.path.join(opts.out, name + ".mlpackage")

    sys.stderr.write("loading %s ...\n" % REPO)
    tokenizer = AutoTokenizer.from_pretrained(REPO)
    # ⚠️ With the sdpa attention path BertModel never calls
    # get_extended_attention_mask, so overriding it does nothing. Forcing
    # eager attention is what puts the clamped mask in the graph.
    encoder = AutoModel.from_pretrained(
        REPO, attn_implementation="eager" if opts.mask_clamp else "sdpa")
    if opts.mask_clamp:
        encoder.get_extended_attention_mask = clamped_mask
    model = Embedder(encoder).eval()

    ids = torch.randint(1000, 2000, (opts.batch, opts.seq), dtype=torch.int32)
    mask = torch.ones((opts.batch, opts.seq), dtype=torch.int32)
    with torch.no_grad():
        traced = torch.jit.trace(model, (ids, mask))

    shape = (ct.EnumeratedShapes(shapes=[(opts.batch, n) for n in lengths])
             if len(lengths) > 1 else (opts.batch, opts.seq))
    sys.stderr.write("converting (%s) ...\n" % opts.precision)
    started = time.time()
    # int8 quantises weights AFTER converting at fp16, so build fp16 either way.
    precision = ct.precision.FLOAT32 if opts.precision == "fp32" else ct.precision.FLOAT16
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        compute_precision=precision,
        inputs=[
            ct.TensorType(name="input_ids", shape=shape, dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=shape, dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS15,
    )

    if opts.precision == "int8":
        from coremltools.optimize.coreml import (
            OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights)
        config = OptimizationConfig(
            global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8"))
        mlmodel = linear_quantize_weights(mlmodel, config=config)

    mlmodel.short_description = "e5-small-v2, mean-pooled and L2-normalised"
    mlmodel.author = "apple-tools lab"
    if os.path.exists(target):
        shutil.rmtree(target)
    mlmodel.save(target)

    vocab = os.path.join(opts.out, "vocab.txt")
    if not os.path.exists(vocab):
        tokenizer.save_pretrained(os.path.join(opts.out, "tokenizer"))

    size = sum(os.path.getsize(os.path.join(root, f))
               for root, _, files in os.walk(target) for f in files)
    print(json.dumps({"model": target, "seconds": round(time.time() - started, 1),
                      "megabytes": round(size / 1e6, 1),
                      "seq": opts.seq, "batch": opts.batch,
                      "precision": opts.precision}))


if __name__ == "__main__":
    main()
