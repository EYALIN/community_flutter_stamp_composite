#!/usr/bin/env python3
"""Generates the example app's integration-test JPEGs (example/assets/).

Every image is flat grey with a coloured block in each STORED corner (10% x 10%):
top-left red, top-right green, bottom-left blue, bottom-right yellow. The test maps each output corner
back to a stored corner, so orientation, extraRotation and mirror are all checked by colour.

  src_12mp_o6.jpg   4000x3000 stored, EXIF Orientation 6 (upright 3000x4000)
  src_48mp_o1.jpg   8000x6000 stored, Orientation 1 (low detail: small file)
  src_12mp_o3.jpg   3000x4000 stored, Orientation 3, with a GPS block (must NOT survive exif == null)
  src_12mp_o1_square.jpg  4000x3000, Orientation 1, centred black 400x400 square (cover-crop test)

Usage: python3 tool/make_test_assets.py [out_dir]
"""
import os
import sys

from PIL import Image, ImageDraw

RED, GREEN, BLUE, YELLOW, GREY = (230, 20, 20), (20, 200, 20), (20, 20, 230), (240, 230, 20), (128, 128, 128)


def make(path, w, h, orientation, gps=False, square=False):
    img = Image.new("RGB", (w, h), GREY)
    d = ImageDraw.Draw(img)
    bw, bh = w // 10, h // 10
    d.rectangle([0, 0, bw - 1, bh - 1], fill=RED)
    d.rectangle([w - bw, 0, w - 1, bh - 1], fill=GREEN)
    d.rectangle([0, h - bh, bw - 1, h - 1], fill=BLUE)
    d.rectangle([w - bw, h - bh, w - 1, h - 1], fill=YELLOW)
    if square:  # a centred 400 x 400 black square: must stay square through a cover crop
        d.rectangle([w // 2 - 200, h // 2 - 200, w // 2 + 199, h // 2 + 199], fill=(0, 0, 0))
    exif = Image.Exif()
    exif[0x0112] = orientation
    if gps:
        exif[0x8825] = {1: "N", 2: (51.0, 30.0, 0.0), 3: "W", 4: (0.0, 7.0, 0.0)}
    img.save(path, "JPEG", quality=90, exif=exif.tobytes())
    print(f"{path}: {w}x{h} o={orientation} {os.path.getsize(path) / 1e6:.2f} MB")


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "example", "assets")
    os.makedirs(out, exist_ok=True)
    make(os.path.join(out, "src_12mp_o6.jpg"), 4000, 3000, 6)
    make(os.path.join(out, "src_48mp_o1.jpg"), 8000, 6000, 1)
    make(os.path.join(out, "src_12mp_o3.jpg"), 3000, 4000, 3, gps=True)
    make(os.path.join(out, "src_12mp_o1_square.jpg"), 4000, 3000, 1, square=True)
