# TGML Image Toolkit

Extract and AI-upscale embedded PNG images from TGML (XML-based) graphic files used in building automation graphics editors (e.g. Schneider Electric).

## Quick Start

**New machine?** Grab the standalone `.exe` and go:

1. Download [TGML-Upscaler.exe](TGML-Upscaler.exe) (54 MB, no dependencies)
2. Configure your extracted images folder
3. Run and export upscaled PNGs

Or use the Python scripts for more control:

```bash
pip install -r requirements.txt
python tgml-extract-images.py path/to/tgmls/
python tgml-upscale.py path/to/extracted_images/
```

## Scripts

### `tgml-extract-images.py` — Extract images from TGML

Scans one or more `.tgml` files and extracts all embedded PNG images. Each file's images go into their own subfolder.

```bash
# Single file
python tgml-extract-images.py drawing.tgml

# Recursive folder — finds all .tgml files
python tgml-extract-images.py path/to/tgmls/

# Custom output parent (subfolders created per file)
python tgml-extract-images.py path/to/tgmls/ --out-dir ./extracted
```

### `tgml-upscale.py` — AI upscale extracted images (Python)

Uses **Real-ESRGAN** to upscale extracted PNGs 4× with intelligent detail reconstruction — way better than blurry bilinear/bicubic resizing.

```bash
# Single image
python tgml-upscale.py image.png

# Batch upscale an entire folder
python tgml-upscale.py path/to/extracted_images/

# Custom scale factor
python tgml-upscale.py image.png --scale 3
```

On first run it auto-downloads the AI model (~64MB). Only needs to download once.

> **Note:** requires Python with `torch`, `torchvision`, `opencv-python`, `realesrgan` installed. See `requirements.txt`.

### `TGML-Upscaler.exe` — Standalone GUI (no dependencies)

A tkinter GUI that wraps the **realesrgan-ncnn-vulkan** binary — no Python, no PyTorch needed. Just run the exe.

- Select input/output folders
- Choose scale factor (2×, 3×, 4×)
- Batch processes all PNG/JPG images
- Progress bar + log output

On first launch it auto-downloads the ncnn-vulkan binary (~44 MB) if missing.

## How the extractor works

TGML files store graphic assets (valves, dampers, fans, pipes, etc.) as Base64-encoded PNG data embedded inline in `<Image>` elements. The script:

1. **Fast regex scan** for `iVBORw0...` CDATA blocks
2. **XML parse fallback** if no CDATA blocks are found
3. Each valid PNG is written as `image_000.png`, `image_001.png`, etc.

## License

MIT