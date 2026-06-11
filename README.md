# TGML Image Extractor

Extracts embedded PNG images from TGML (XML-based) graphic files used in building automation graphics editors (e.g. Schneider Electric).

## Usage

```bash
python tgml-extract-images.py path/to/file.tgml [output_dir]
```

If `output_dir` is omitted, images are saved to `./<filename>_images/`.

## How it works

TGML files store graphic assets (valves, dampers, fans, pipes, etc.) as Base64-encoded PNG data embedded inline in `<Image>` elements. This script scans the file, decodes the base64, validates the PNG header, and writes out individual `.png` files.

Uses two strategies:
1. **Regex** — fast scan for `iVBORw0...` CDATA blocks
2. **XML parse fallback** — if regex finds nothing, parses the XML and searches for `<Image>` elements

## License

MIT
