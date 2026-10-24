"""Generate every TokenBar app icon from one procedural design.

Run from the repository root (needs Pillow + numpy):

    python tool/gen_icons.py            # write all icons
    python tool/gen_icons.py --preview  # only write build/icon_preview.png

The artwork is drawn at 4x and downsampled with Lanczos, so edges are smooth
at every size. Small sizes (<= 48 px) use a simplified, bolder layout.
"""

from __future__ import annotations

import argparse
import io
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SS = 4  # supersampling factor

# Brand palette.
BG_TOP = (30, 41, 70)
BG_BOTTOM = (10, 14, 28)
TOP_BAR = ((52, 211, 153), (34, 211, 238))  # emerald -> cyan
BOTTOM_BAR = ((129, 140, 248), (192, 132, 252))  # indigo -> violet


def _lerp(a, b, t):
    return a + (b - a) * t


def _gradient(size: int, c0, c1, vertical=True, t_offset=0.0, t_scale=1.0) -> np.ndarray:
    """RGB float image of shape (size, size, 3)."""
    t = np.linspace(0, 1, size, dtype=np.float32)
    t = np.clip(t * t_scale + t_offset, 0, 1)
    c0 = np.array(c0, dtype=np.float32)
    c1 = np.array(c1, dtype=np.float32)
    line = c0[None, :] + (c1 - c0)[None, :] * t[:, None]  # (size, 3)
    if vertical:
        return np.repeat(line[:, None, :], size, axis=1)
    return np.repeat(line[None, :, :], size, axis=0)


def _squircle_mask(size: int, margin: float, n: float = 5.0) -> Image.Image:
    """Superellipse (Apple-style continuous corner) alpha mask, mode L."""
    half = size / 2
    r = half - margin
    ax = (np.arange(size, dtype=np.float32) + 0.5 - half) / r
    x = np.abs(ax)[None, :]
    y = np.abs(ax)[:, None]
    d = (x**n + y**n) ** (1.0 / n)
    # Smooth edge ~1px wide at the working resolution.
    edge = 1.5 / r
    alpha = np.clip((1.0 - d) / edge, 0, 1)
    return Image.fromarray((alpha * 255).astype(np.uint8), "L")


def _capsule(draw: ImageDraw.ImageDraw, box, fill):
    x0, y0, x1, y1 = box
    draw.rounded_rectangle(box, radius=(y1 - y0) / 2, fill=fill)


def _bar_layer(size, box, c0, c1, ratio, small):
    """Track + gradient fill + soft glow for one horizontal bar."""
    x0, y0, x1, y1 = box
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    track = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    _capsule(ImageDraw.Draw(track), box, (255, 255, 255, 34))
    layer = Image.alpha_composite(layer, track)

    fx1 = x0 + (x1 - x0) * ratio
    fill_mask = Image.new("L", (size, size), 0)
    _capsule(ImageDraw.Draw(fill_mask), (x0, y0, fx1, y1), 255)

    grad = np.zeros((size, size, 3), dtype=np.float32)
    gx0, gx1 = int(x0), int(max(fx1, x0 + 1))
    span = max(gx1 - gx0, 1)
    t = np.clip((np.arange(size, dtype=np.float32) - gx0) / span, 0, 1)
    c0a, c1a = np.array(c0, np.float32), np.array(c1, np.float32)
    row = c0a[None, :] + (c1a - c0a)[None, :] * t[:, None]
    grad[:] = row[None, :, :]
    # Subtle vertical shading: lighter at top of the bar.
    bar_h = max(y1 - y0, 1)
    vy = np.clip((np.arange(size, dtype=np.float32) - y0) / bar_h, 0, 1)
    shade = 1.12 - 0.22 * vy
    grad = np.clip(grad * shade[:, None, None], 0, 255)
    fill_img = Image.fromarray(grad.astype(np.uint8), "RGB").convert("RGBA")
    fill_img.putalpha(fill_mask)

    if not small:
        glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        gm = fill_mask.filter(ImageFilter.GaussianBlur(size * 0.012))
        mid = tuple(int(_lerp(a, b, 0.5)) for a, b in zip(c0, c1))
        glow_solid = Image.new("RGBA", (size, size), mid + (0,))
        glow_solid.putalpha(gm.point(lambda v: int(v * 0.55)))
        glow = Image.alpha_composite(glow, glow_solid)
        layer = Image.alpha_composite(layer, glow)

    layer = Image.alpha_composite(layer, fill_img)

    if not small:
        # Specular line on the upper half of the fill.
        hl = Image.new("L", (size, size), 0)
        inset = bar_h * 0.16
        ImageDraw.Draw(hl).rounded_rectangle(
            (x0 + bar_h * 0.35, y0 + inset, fx1 - bar_h * 0.35, y0 + inset + bar_h * 0.22),
            radius=bar_h * 0.11,
            fill=70,
        )
        hl = Image.composite(hl, Image.new("L", (size, size), 0), fill_mask)
        white = Image.new("RGBA", (size, size), (255, 255, 255, 0))
        white.putalpha(hl)
        layer = Image.alpha_composite(layer, white)
    return layer


def render(px: int, *, shape: str = "squircle", top: float = 0.72, bottom: float = 0.45) -> Image.Image:
    """Render the icon at `px` x `px`.

    shape: 'squircle' (transparent corners), 'square' (full bleed, opaque),
           'maskable' (full bleed, content inside the 80% safe zone).
    """
    small = px <= 48
    size = px * SS
    full_bleed = shape in ("square", "maskable")
    margin = 0 if full_bleed else size * (0.02 if small else 0.045)

    bg = _gradient(size, BG_TOP, BG_BOTTOM)
    # Soft radial glow in the upper-left for depth.
    ys, xs = np.mgrid[0:size, 0:size].astype(np.float32)
    cx, cy = size * 0.30, size * 0.18
    dist = np.sqrt((xs - cx) ** 2 + (ys - cy) ** 2) / (size * 0.85)
    glow = np.clip(1.0 - dist, 0, 1) ** 2 * 38
    bg = np.clip(bg + glow[:, :, None] * np.array([0.55, 0.75, 1.0], np.float32), 0, 255)
    canvas = Image.fromarray(bg.astype(np.uint8), "RGB").convert("RGBA")

    # Content geometry (fraction of the *visible* tile).
    tile = size - 2 * margin
    safe = 0.80 if shape == "maskable" else 1.0
    inner = tile * safe
    ox = (size - inner) / 2
    oy = (size - inner) / 2

    bar_x0 = ox + inner * (0.16 if small else 0.17)
    bar_x1 = ox + inner * (0.84 if small else 0.83)
    bar_h = inner * (0.19 if small else 0.15)
    gap = inner * (0.12 if small else 0.10)
    total_h = bar_h * 2 + gap
    y_start = oy + (inner - total_h) / 2
    boxes = [
        (bar_x0, y_start, bar_x1, y_start + bar_h),
        (bar_x0, y_start + bar_h + gap, bar_x1, y_start + 2 * bar_h + gap),
    ]

    # Drop shadow under the bars.
    if not small:
        sh = Image.new("L", (size, size), 0)
        d = ImageDraw.Draw(sh)
        for b in boxes:
            _capsule(d, (b[0], b[1] + bar_h * 0.35, b[2], b[3] + bar_h * 0.35), 120)
        sh = sh.filter(ImageFilter.GaussianBlur(size * 0.018))
        shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        shadow.putalpha(sh)
        canvas = Image.alpha_composite(canvas, shadow)

    canvas = Image.alpha_composite(canvas, _bar_layer(size, boxes[0], *TOP_BAR, top, small))
    canvas = Image.alpha_composite(canvas, _bar_layer(size, boxes[1], *BOTTOM_BAR, bottom, small))

    if not small and not full_bleed:
        # Top gloss: a faint white wash fading downward, clipped to the tile.
        gloss = np.zeros((size, size, 4), dtype=np.uint8)
        gl = np.clip(1.0 - np.linspace(0, 1, size, dtype=np.float32) / 0.55, 0, 1) ** 1.6 * 34
        gloss[:, :, :3] = 255
        gloss[:, :, 3] = gl[:, None].astype(np.uint8)
        canvas = Image.alpha_composite(canvas, Image.fromarray(gloss, "RGBA"))

    if shape == "squircle":
        mask = _squircle_mask(size, margin)
        if not small:
            # 1px inner highlight rim.
            inner_mask = _squircle_mask(size, margin + size * 0.004)
            rim = Image.fromarray(
                np.clip(np.asarray(mask, np.int16) - np.asarray(inner_mask, np.int16), 0, 255).astype(np.uint8),
                "L",
            )
            rim_layer = Image.new("RGBA", (size, size), (255, 255, 255, 0))
            rim_layer.putalpha(rim.point(lambda v: int(v * 0.22)))
            canvas = Image.alpha_composite(canvas, rim_layer)
        canvas.putalpha(mask)
    else:
        canvas = canvas.convert("RGB").convert("RGBA")

    out = canvas.resize((px, px), Image.LANCZOS)
    if shape != "squircle":
        out = out.convert("RGB")
    return out


# --------------------------------------------------------------------- output


def _png_bytes(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def write_all() -> None:
    cache: dict[tuple[int, str], Image.Image] = {}

    def icon(px: int, shape: str = "squircle") -> Image.Image:
        key = (px, shape)
        if key not in cache:
            cache[key] = render(px, shape=shape)
        return cache[key]

    def save_png(rel: str, img: Image.Image) -> None:
        path = ROOT / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        img.save(path, format="PNG", optimize=True)
        print("wrote", rel)

    save_png("assets/icon/tokenbar.png", icon(1024))

    # Windows .ico with every size Explorer / the taskbar asks for.
    ico_sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    ico_path = ROOT / "windows/runner/resources/app_icon.ico"
    ico_path.parent.mkdir(parents=True, exist_ok=True)
    frames = [icon(s) for s in ico_sizes]
    frames[-1].save(
        ico_path,
        format="ICO",
        sizes=[(s, s) for s in ico_sizes],
        append_images=frames[:-1],
    )
    print("wrote windows/runner/resources/app_icon.ico")

    # Web.
    save_png("web/favicon.png", icon(64))
    save_png("web/icons/Icon-192.png", icon(192))
    save_png("web/icons/Icon-512.png", icon(512))
    save_png("web/icons/Icon-maskable-192.png", icon(192, "maskable"))
    save_png("web/icons/Icon-maskable-512.png", icon(512, "maskable"))

    # macOS (squircle with transparent corners).
    for s in (1024, 512, 256, 128, 64, 32, 16):
        save_png(f"macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{s}.png", icon(s))

    # iOS requires an opaque, full-bleed square: the system rounds it.
    # Every size in the appiconset's Contents.json (points x scale).
    ios_dir = "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    ios_sizes = {
        "20x20@1x": 20, "20x20@2x": 40, "20x20@3x": 60,
        "29x29@1x": 29, "29x29@2x": 58, "29x29@3x": 87,
        "40x40@1x": 40, "40x40@2x": 80, "40x40@3x": 120,
        "60x60@2x": 120, "60x60@3x": 180,
        "76x76@1x": 76, "76x76@2x": 152,
        "83.5x83.5@2x": 167,
        "1024x1024@1x": 1024,
    }
    for name, px in ios_sizes.items():
        save_png(f"{ios_dir}/Icon-App-{name}.png", icon(px, "square"))

    # Android legacy launcher icons.
    for density, s in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        save_png(f"android/app/src/main/res/mipmap-{density}/ic_launcher.png", icon(s))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", action="store_true", help="only write build/icon_preview.png")
    args = ap.parse_args()
    if args.preview:
        sheet = Image.new("RGBA", (1024 + 40 + 256 + 20 + 128 + 20 + 64 + 20 + 32 + 20 + 16, 1024), (236, 238, 242, 255))
        x = 0
        for s in (1024, 256, 128, 64, 32, 16):
            sheet.alpha_composite(render(s), (x, 0))
            x += s + 20
        out = ROOT / "build/icon_preview.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        sheet.save(out)
        print("wrote", out)
        return
    write_all()


if __name__ == "__main__":
    main()
