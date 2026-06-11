#!/usr/bin/env python3
"""
Upscale TGML extracted images 4x using Real-ESRGAN AI upscaling.

Also supports an optional --scale argument for custom upscale factors.

Usage:
    # Single image
    python tgml-upscale.py image.png

    # Batch process a folder
    python tgml-upscale.py path/to/images/

    # Custom scale factor (default 4)
    python tgml-upscale.py image.png --scale 3
"""
import sys, os, argparse
from pathlib import Path

# ---- Compat shim: torchvision 0.27.0 renamed functional_tensor to _functional_tensor ----
import torchvision.transforms._functional_tensor as _ft
import sys as _sys
_sys.modules.setdefault('torchvision.transforms.functional_tensor', _ft)

import cv2
import numpy as np
from PIL import Image
from realesrgan import RealESRGANer
from basicsr.archs.rrdbnet_arch import RRDBNet

def upscale_image(input_path, output_path, scale=4):
    """Upscale a single image using Real-ESRGAN."""
    print(f"  Loading: {input_path}")

    # Build the model
    model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=scale)
    model_url = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth"
    upsampler = RealESRGANer(
        scale=scale,
        model_path=model_url,
        model=model,
        tile=0,
        tile_pad=10,
        pre_pad=0,
        half=False,
    )

    # Read image
    img = cv2.imread(str(input_path), cv2.IMREAD_UNCHANGED)
    if img is None:
        raise ValueError(f"Could not read image: {input_path}")

    # Handle alpha channel if present
    alpha = None
    if img.shape[2] == 4:
        alpha = img[:, :, 3]
        img = img[:, :, :3]

    # Upscale
    print(f"  Upscaling {scale}x...")
    output, _ = upsampler.enhance(img, outscale=scale)

    # Re-attach alpha if present
    if alpha is not None:
        alpha_upscaled = cv2.resize(alpha, (output.shape[1], output.shape[0]), interpolation=cv2.INTER_LANCZOS4)
        output = cv2.cvtColor(output, cv2.COLOR_BGR2BGRA)
        output[:, :, 3] = alpha_upscaled

    # Save
    out_p = Path(output_path)
    cv2.imwrite(str(out_p), output, [cv2.IMWRITE_PNG_COMPRESSION, 6])
    orig_size = Path(input_path).stat().st_size
    new_size = out_p.stat().st_size
    print(f"  ✓ Saved: {output_path}")
    print(f"    Size: {img.shape[1]}x{img.shape[0]} → {output.shape[1]}x{output.shape[0]}")
    print(f"    File: {orig_size/1024:.0f}KB → {new_size/1024:.0f}KB")
    return True

def main():
    parser = argparse.ArgumentParser(description="Upscale TGML images with Real-ESRGAN")
    parser.add_argument("input", help="Image file or directory of images")
    parser.add_argument("--scale", type=int, default=4, help="Upscale factor (default: 4)")
    parser.add_argument("--output", "-o", help="Output file or directory (default: input_upscaled/)")
    args = parser.parse_args()

    input_path = Path(args.input)

    if input_path.is_dir():
        # Batch mode
        out_dir = Path(args.output) if args.output else input_path.parent / f"{input_path.name}_upscaled"
        out_dir.mkdir(parents=True, exist_ok=True)
        images = sorted(input_path.glob("*.png")) + sorted(input_path.glob("*.jpg")) + sorted(input_path.glob("*.jpeg"))
        if not images:
            print(f"No PNG/JPG images found in {input_path}")
            return 1
        print(f"Upscaling {len(images)} images in {input_path}")
        print(f"Output: {out_dir}")
        for img in images:
            try:
                upscale_image(img, out_dir / img.name, args.scale)
            except Exception as e:
                print(f"  ✗ Failed: {img.name} — {e}")
    else:
        # Single file mode
        if not input_path.exists():
            print(f"File not found: {input_path}")
            return 1
        if args.output:
            out_path = args.output
        else:
            stem = input_path.stem
            out_path = input_path.parent / f"{stem}_upscaled{input_path.suffix}"
        upscale_image(input_path, out_path, args.scale)

    return 0

if __name__ == "__main__":
    sys.exit(main())
