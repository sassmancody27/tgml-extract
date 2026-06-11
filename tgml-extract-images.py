#!/usr/bin/env python3
"""
Extract all embedded PNG images from TGML (XML-based) graphic files.

Usage:
    python tgml-extract-images.py path/to/file.tgml [output_dir]

If output_dir is omitted, images go into ./<filename>_images/
"""
import sys, os, re, base64
from pathlib import Path
from xml.etree import ElementTree as ET

NS = {"": "http://www.w3.org/2000/svg"}  # common SVG namespace; adjust if needed

def extract_tgml_images(tgml_path, out_dir):
    tgml_path = Path(tgml_path)
    if not tgml_path.exists():
        print(f"❌ File not found: {tgml_path}")
        return 1

    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    raw = tgml_path.read_text(encoding="utf-8")

    # Strategy 1: regex all <![CDATA[iVBOR...]]> blocks (fast, no namespace trouble)
    cdata_pattern = re.compile(r'<!\[CDATA\[(iVBORw0KGgo[A-Za-z0-9+/=]+)\]\]>')

    count = 0
    for match in cdata_pattern.finditer(raw):
        b64 = match.group(1)
        try:
            data = base64.b64decode(b64)
        except Exception as e:
            print(f"  ⚠ Skipping invalid base64 block: {e}")
            continue
        # PNG signature check — should start with \x89PNG
        if data[:4] != b'\x89PNG':
            print(f"  ⚠ Skipping non-PNG base64 block (header: {data[:8].hex()})")
            continue
        out_name = f"image_{count:03d}.png"
        (out_dir / out_name).write_bytes(data)
        print(f"  ✓ {out_name} ({len(data):,} bytes)")
        count += 1

    if count == 0:
        print("⚠ No embedded PNG images found via CDATA regex.")
        print("  Trying XML parse approach...")
        # Strategy 2: parse as XML and find <Image> elements
        try:
            root = ET.fromstring(raw)
            # Search recursively for any element with Image or img in local name
            for elem in root.iter():
                tag = elem.tag.split("}")[-1] if "}" in elem.tag else elem.tag
                if tag.lower() in ("image", "img") and elem.text and elem.text.strip():
                    b64 = elem.text.strip()
                    try:
                        data = base64.b64decode(b64)
                    except Exception:
                        continue
                    if data[:4] == b'\x89PNG':
                        out_name = f"image_xml_{count:03d}.png"
                        (out_dir / out_name).write_bytes(data)
                        print(f"  ✓ {out_name} ({len(data):,} bytes)")
                        count += 1
        except ET.ParseError as e:
            print(f"  ⚠ XML parse failed: {e}")

    print(f"\n✅ Extracted {count} image(s) to: {out_dir}")
    return 0

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    tgml = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else Path(tgml).stem + "_images"
    sys.exit(extract_tgml_images(tgml, out))
