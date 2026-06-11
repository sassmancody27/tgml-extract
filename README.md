# TGML Image Toolkit

Extract and AI-upscale embedded PNG images from TGML (XML-based) graphic files used in building automation graphics editors (e.g. Schneider Electric).

## Quick Start — No Python Required

### 1. Extract images from TGML files

Run `TGML-Extractor.exe` — point it at a `.tgml` file or a folder of them. Each file's images go into their own subfolder.

### 2. AI-upscale the extracted images

Run `TGML-Upscaler.exe` — point it at the extracted image folder, choose your scale (2×, 3×, 4×), and go. Uses GPU-accelerated Real-ESRGAN for crisp results.

---

## Python Scripts (for more control)

### `tgml-extract-images.py` — Extract images from TGML

```bash
# Single file
python tgml-extract-images.py drawing.tgml

# Recursive folder — finds all .tgml files
python tgml-extract-images.py path/to/tgmls/

# Custom output parent
python tgml-extract-images.py path/to/tgmls/ --out-dir ./extracted
```

### `tgml-upscale.py` — AI upscale extracted images (Python)

```bash
# Single image
python tgml-upscale.py image.png

# Batch upscale an entire folder
python tgml-upscale.py path/to/extracted_images/

# Custom scale factor
python tgml-upscale.py image.png --scale 3
```

On first run it auto-downloads the AI model (~64MB).

> **Note:** requires Python with `torch`, `torchvision`, `opencv-python`, `realesrgan` installed. See `requirements.txt`.

## How it works

TGML files store graphic assets (valves, dampers, fans, pipes, etc.) as Base64-encoded PNG data embedded inline in `<Image>` elements. The extractor scans for these, decodes them, and writes out individual `.png` files.

The upscaler uses Real-ESRGAN (via the lightweight ncnn-vulkan backend) to intelligently reconstruct detail at higher resolutions — much better than blurry bilinear/bicubic resizing.

## Workflow

```
TGML files  →  TGML-Extractor.exe  →  extracted PNGs  →  TGML-Upscaler.exe  →  crisp upscaled PNGs
```

## License

MIT