#!/usr/bin/env python3
"""
TGML Image Extractor GUI — extract embedded PNGs from TGML graphic files.

Supports single file or recursive folder scanning. Each TGML file's images
go into a subfolder named after the source file.
"""
import tkinter as tk
from tkinter import filedialog, ttk, messagebox
import re, base64, threading, os, sys
from pathlib import Path
from xml.etree import ElementTree as ET


def extract_tgml_images(tgml_path, out_dir, log_cb):
    """Extract all embedded PNGs from one TGML file into out_dir."""
    tgml_path = Path(tgml_path)
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    raw = tgml_path.read_text(encoding="utf-8")
    count = 0

    # Strategy 1: regex CDATA blocks
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


class ExtractorGUI:
    def __init__(self, root):
        self.root = root
        root.title("TGML Image Extractor")
        root.geometry("600x480")
        root.configure(bg="#1a1a2e")

        # Input
        tk.Label(root, text="TGML File or Folder:", bg="#1a1a2e", fg="#ccc",
                 font=("Segoe UI", 10)).pack(anchor="w", padx=15, pady=(15, 2))
        f_in = tk.Frame(root, bg="#1a1a2e")
        f_in.pack(fill="x", padx=15, pady=(0, 10))
        self.in_path = tk.StringVar()
        tk.Entry(f_in, textvariable=self.in_path, bg="#0f3460", fg="#eee",
                 insertbackground="#22c55e", relief="flat", font=("Segoe UI", 9)).pack(side="left", fill="x", expand=True, ipady=3)
        browse_btn = tk.Button(f_in, text="Browse File", command=self.browse_file,
                               bg="#0f3460", fg="#22c55e", activebackground="#1a5276",
                               relief="flat", cursor="hand2", font=("Segoe UI", 9, "bold"))
        browse_btn.pack(side="right", padx=(4, 0))
        browse_dir_btn = tk.Button(f_in, text="Browse Folder", command=self.browse_folder,
                                   bg="#0f3460", fg="#22c55e", activebackground="#1a5276",
                                   relief="flat", cursor="hand2", font=("Segoe UI", 9, "bold"))
        browse_dir_btn.pack(side="right", padx=(4, 0))

        # Output
        tk.Label(root, text="Output Folder:", bg="#1a1a2e", fg="#ccc",
                 font=("Segoe UI", 10)).pack(anchor="w", padx=15, pady=(10, 2))
        f_out = tk.Frame(root, bg="#1a1a2e")
        f_out.pack(fill="x", padx=15, pady=(0, 10))
        self.out_path = tk.StringVar()
        tk.Entry(f_out, textvariable=self.out_path, bg="#0f3460", fg="#eee",
                 insertbackground="#22c55e", relief="flat", font=("Segoe UI", 9)).pack(side="left", fill="x", expand=True, ipady=3)
        tk.Button(f_out, text="Browse", command=self.browse_out, bg="#0f3460", fg="#22c55e",
                  activebackground="#1a5276", relief="flat", cursor="hand2",
                  font=("Segoe UI", 9, "bold")).pack(side="right", padx=(8, 0))

        # Run button
        self.run_btn = tk.Button(root, text="▶  Extract Images", command=self.start_extract,
                                 bg="#22c55e", fg="#0a0a1a", activebackground="#16a34a",
                                 relief="flat", cursor="hand2", padx=20, pady=6,
                                 font=("Segoe UI", 10, "bold"))
        self.run_btn.pack(pady=8)

        # Progress
        self.progress = ttk.Progressbar(root, mode="determinate", value=0, length=560)
        self.progress.pack(padx=15, pady=5, fill="x")

        # Log
        tk.Label(root, text="Log:", bg="#1a1a2e", fg="#ccc",
                 font=("Segoe UI", 9)).pack(anchor="w", padx=15, pady=(5, 2))
        log_frame = tk.Frame(root, bg="#0a0a1a")
        log_frame.pack(fill="both", expand=True, padx=15, pady=(0, 15))
        self.log_text = tk.Text(log_frame, bg="#0a0a1a", fg="#a0d2db", insertbackground="#22c55e",
                                relief="flat", font=("Consolas", 9), state="disabled")
        scroll = tk.Scrollbar(log_frame, command=self.log_text.yview)
        self.log_text.configure(yscrollcommand=scroll.set)
        scroll.pack(side="right", fill="y")
        self.log_text.pack(fill="both", expand=True)

        self.running = False

    def log(self, msg):
        self.log_text.configure(state="normal")
        self.log_text.insert("end", msg + "\n")
        self.log_text.see("end")
        self.log_text.configure(state="disabled")
        self.root.update_idletasks()

    def browse_file(self):
        f = filedialog.askopenfilename(title="Select TGML file",
                                        filetypes=[("TGML files", "*.tgml"), ("All files", "*.*")])
        if f:
            self.in_path.set(f)
            # Auto-set output
            p = Path(f)
            self.out_path.set(str(p.parent / p.stem))

    def browse_folder(self):
        d = filedialog.askdirectory(title="Select folder with TGML files")
        if d:
            self.in_path.set(d)
            self.out_path.set(str(Path(d).parent / f"{Path(d).name}_extracted"))

    def browse_out(self):
        d = filedialog.askdirectory(title="Select output folder")
        if d:
            self.out_path.set(d)

    def start_extract(self):
        if self.running:
            return
        in_path = Path(self.in_path.get())
        out_root = Path(self.out_path.get())
        if not in_path.exists():
            messagebox.showerror("Error", "Input path does not exist")
            return

        if in_path.is_file():
            tgmls = [in_path]
            out_base = out_root if out_root.name else in_path.parent
        else:
            tgmls = sorted(in_path.rglob("*.tgml"))
            out_base = out_root if out_root.name else in_path.parent / f"{in_path.name}_extracted"
            if not tgmls:
                messagebox.showerror("Error", "No .tgml files found in that folder")
                return

        out_base = Path(out_base)
        self.running = True
        self.run_btn.configure(state="disabled")
        self.progress["maximum"] = len(tgmls)
        self.log(f"Extracting images from {len(tgmls)} file(s)...")
        self.log(f"Output: {out_base}")
        threading.Thread(target=self._run_extract, args=(tgmls, out_base), daemon=True).start()

    def _run_extract(self, tgmls, out_base):
        total = 0
        try:
            for i, tgml in enumerate(tgmls):
                sub = out_base / tgml.stem
                self.log(f"  [{i+1}/{len(tgmls)}] {tgml.name}...")
                self.progress["value"] = i
                self.root.update_idletasks()
                n = extract_tgml_images(tgml, sub, self.log)
                if n:
                    self.log(f"    ✓ {n} image(s) → {sub}")
                else:
                    self.log(f"    - no images found")
                    # Clean up empty folder
                    if sub.exists():
                        try:
                            sub.rmdir()
                        except OSError:
                            pass
                total += n

            self.progress["value"] = len(tgmls)
            self.log(f"\n✅ Done! {total} total image(s) extracted to {out_base}")
        except Exception as e:
            self.log(f"\n❌ Error: {e}")
        finally:
            self.running = False
            self.run_btn.configure(state="normal")


if __name__ == "__main__":
    root = tk.Tk()
    app = ExtractorGUI(root)
    root.mainloop()