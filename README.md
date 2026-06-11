# TGML Image Toolkit

Extract and AI-upscale embedded PNG images from TGML (XML-based) graphic files used in building automation graphics editors (e.g. Schneider Electric).

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

### `tgml-upscale.py` — AI upscale extracted images

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

> **Note:** the upscale script requires the Hermes or equivalent venv with `realesrgan` installed, or you can run it with the full python path:
> ```
> /path/to/venv/Scripts/python.exe tgml-upscale.py ...
> ```

## Typical workflow

```bash
# 1. Extract all images from your TGML files
python tgml-extract-images.py ./my_graphics/ --out-dir ./extracted/

# 2. AI-upscale the extracted images 4×
python tgml-upscale.py ./extracted/

# 3. Replace the originals in your TGML or graphic editor
```

## How the extractor works

TGML files store graphic assets (valves, dampers, fans, pipes, etc.) as Base64-encoded PNG data embedded inline in `<Image>` elements. The script:

1. **Fast regex scan** for `iVBORw0...` CDATA blocks
2. **XML parse fallback** if no CDATA blocks are found
3. Each valid PNG is written as `image_000.png`, `image_001.png`, etc.

## License

MIT