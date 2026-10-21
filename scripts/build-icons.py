#!/usr/bin/env python3
"""Render the editable SVG into native macOS and Windows icon bundles (ImageMagick)."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
assets = root / 'Assets'
with tempfile.TemporaryDirectory(prefix='display-input-switch-icons-') as temp:
    iconset = Path(temp) / 'AppIcon.iconset'
    iconset.mkdir()
    master = Path(temp) / 'AppIcon.png'
    subprocess.run(['sips', '-s', 'format', 'png', str(assets / 'AppIcon.svg'), '--out', str(master)], check=True)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = size * scale
            name = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
            subprocess.run(['magick', str(master),
                            '-resize', f'{pixels}x{pixels}', str(iconset / name)], check=True)
    subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(assets / 'AppIcon.icns')], check=True)
    subprocess.run(['magick', str(iconset / 'icon_512x512@2x.png'), '-define',
                    'icon:auto-resize=256,128,64,48,32,24,16', str(assets / 'AppIcon.ico')], check=True)
    subprocess.run(['magick', str(iconset / 'icon_512x512@2x.png'), '-resize', '256x256',
                    str(assets / 'AppIcon.png')], check=True)
print('Generated Assets/AppIcon.icns, AppIcon.ico, AppIcon.png')
