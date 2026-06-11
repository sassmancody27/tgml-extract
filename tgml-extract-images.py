#!/usr/bin/env python3
"""
Extract all embedded PNG images from TGML (XML-based) graphic files.

Supports single file or recursive folder scanning. Each TGML file's images
are saved to a subfolder named after the file.

Usage:
    # Single file
    python tgml-extract-images.py path/to/file.tgml

    # Recursive folder — finds all *.tgml files
    python tgml-extract-images.py path/to/folder/

    # Explicit output parent (subfolders created per file)
    python tgml-extract-images.py path/to/folder/ --out-dir ./extracted
"""
import sys, os, re, base64
from pathlib import Path
from xml.etree import ElementTree as ET


def extract_tgml_images(tgml_path, out_dir):
    """Extract all embedded PNGs from one TGML file into out_dir."""
    tgml_path = Path(tgml_path)
    if not tgml_path.exists():
        print(f"  ❌ File not found: {tgml_path}")
        return 0

    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    raw = tgml_path.read_text(encoding="utf-8")
    count = 0

    # Strategy 1: regex CDATA blocks (fast, no namespace trouble)
    cdata_pattern = re.compile(r'<!\[CDATA\[(iVBORw0KGgo[A-Za-z0-9+/=]+)\]\]>')
    for match in cdata_pattern.finditer(raw):
        b64 = match.group(1)
        try:
            data = base64.b64decode(b64)
        except Exception:
            continue
        if data[:4] != b'\x89PNG':
            continue
        out_name = f"image_{count:03d}.png"
        (out_dir / out_name).write_bytes(data)
        count += 1

    if count == 0:
        # Strategy 2: parse XML and find <Image> elements
        try:
            root = ET.fromstring(raw)
            for elem in root.iter():
                tag = elem.tag.split("}")[-1] if "}" in elem.tag else elem.tag
                if tag.lower() in ("image", "img") and elem.text and elem.text.strip():
                    b64 = elem.text.strip()
                    try:
                        data = base64.b64decode(b64)
                    except Exception:
                        continue
                    if data[:4] == b'\x89PNG':
                        out_name = f"image_{count:03d}.png"
                        (out_dir / out_name).write_bytes(data)
                        count += 1
        except ET.ParseError:
            pass

    return count


def process_path(input_path, output_root=None):
    """Process a single file or recurse into a folder of TGML files."""
    input_path = Path(input_path)

    if input_path.is_file():
        paths = [input_path]
        out_base = Path(output_root) if output_root else input_path.parent
    elif input_path.is_dir():
        paths = sorted(input_path.rglob("*.tgml"))
        if not paths:
            print(f"No .tgml files found under: {input_path}")
            return 1
        out_base = Path(output_root) if output_root else input_path
    else:
        print(f"Path not found: {input_path}")
        return 1

    total = 0
    files_ok = 0
    files_skip = 0

    for tgml in paths:
        # Subfolder named after the TGML file
        sub = out_base / tgml.stem
        n = extract_tgml_images(tgml, sub)
        if n:
            print(f"  ✓ {tgml.name} → {n} image(s) in {sub}/")
            files_ok += 1
        else:
            print(f"  - {tgml.name} → no images found")
            files_skip += 1
            # Clean up empty folder
            if sub.exists():
                try:
                    sub.rmdir()
                except OSError:
                    pass
        total += n

    print(f"\n✅ Done: {total} image(s) from {files_ok} file(s)")
    if files_skip:
        print(f"   ({files_skip} file(s) had no embedded images)")
    return 0


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(
        description="Extract embedded PNG images from TGML files")
    parser.add_argument("input", help="TGML file or folder to scan")
    parser.add_argument("--out-dir", "-o",
                        help="Output parent directory (subfolders created per file)")
    args = parser.parse_args()
    sys.exit(process_path(args.input, args.out_dir))