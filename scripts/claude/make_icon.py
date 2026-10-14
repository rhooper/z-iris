"""Build the z-iris icons: the Zulip logo plus a quarter note.

Zulip's Icon.png (Apache 2.0, from zulip-desktop) is only 48 px, so the
colours are sampled from it and the circle and Z are redrawn as vectors.
Writes src/z_iris/static/: z-iris.png (1024), z-iris.icns, and the menubar
template images z-iris-menubarTemplate.png and @2x (black Z with a note).

Usage: uv run python scripts/claude/make_icon.py [Icon.png]
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

RES = Path.home() / "Devel/zulip-desktop/public/resources"
OUT = Path(__file__).resolve().parents[2] / "src/z_iris/static"
SIZE = 1024


def shape(draw_fn, size: int) -> Image.Image:
    """Antialiased mask: draw 4x, round the corners by blur + threshold, shrink."""
    big = size * 4
    mask = Image.new("L", (big, big), 0)
    draw_fn(ImageDraw.Draw(mask), big)
    mask = mask.filter(ImageFilter.GaussianBlur(big * 0.012)).point(lambda v: 255 if v > 128 else 0)
    return mask.resize((size, size), Image.LANCZOS)


# The Zulip Z, in unit coordinates, traced from Icon.png.
Z = [(.27, .24), (.73, .24), (.73, .33), (.45, .61), (.73, .61), (.73, .76),
     (.27, .76), (.27, .67), (.55, .39), (.27, .39)]


def z_mask(size: int) -> Image.Image:
    return shape(lambda d, n: d.polygon([(x * n, y * n) for x, y in Z], fill=255), size)


def disc(size: int, cx: float, cy: float, r: float) -> Image.Image:
    return shape(
        lambda d, n: d.ellipse(((cx - r) * n, (cy - r) * n, (cx + r) * n, (cy + r) * n), fill=255),
        size,
    )


def note(size: int, ink: tuple, scale: float = 1.0) -> Image.Image:
    """A quarter note filling a size x size RGBA tile (drawn 4x, then shrunk)."""
    big = size * 4
    tile = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(tile)
    head_w, head_h = 0.34 * big * scale, 0.25 * big * scale
    cx, cy = 0.40 * big, 0.74 * big
    head = Image.new("L", (big, big), 0)
    ImageDraw.Draw(head).ellipse(
        (cx - head_w / 2, cy - head_h / 2, cx + head_w / 2, cy + head_h / 2), fill=255
    )
    head = head.rotate(22, center=(cx, cy), resample=Image.BICUBIC)
    stem_x = cx + head_w / 2 - 0.035 * big * scale
    d.rectangle(
        (stem_x - 0.035 * big * scale, 0.14 * big, stem_x + 0.035 * big * scale, cy), fill=ink
    )
    tile.paste(Image.new("RGBA", (big, big), ink), mask=head)
    return tile.resize((size, size), Image.LANCZOS)


def app_icon(source: Path) -> Image.Image:
    src = Image.open(source).convert("RGBA")
    top, bottom = src.getpixel((24, 4))[:3], src.getpixel((24, 44))[:3]
    column = Image.new("RGB", (1, SIZE))
    for y in range(SIZE):
        t = y / (SIZE - 1)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    icon = column.resize((SIZE, SIZE)).convert("RGBA")
    white = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 255))
    icon.paste(white, mask=z_mask(SIZE))
    icon.putalpha(disc(SIZE, .5, .5, .5))
    # Badge at the lower right: dark disc, white rim, white note.
    icon.paste(white, mask=disc(SIZE, .70, .70, .205))
    icon.paste(Image.new("RGBA", (SIZE, SIZE), (30, 36, 70, 255)), mask=disc(SIZE, .70, .70, .18))
    glyph = note(int(SIZE * .30), (255, 255, 255, 255))
    icon.alpha_composite(glyph, (int(SIZE * .70 - SIZE * .15), int(SIZE * .70 - SIZE * .15)))
    return icon


def menubar(px: int) -> Image.Image:
    """Black Z template at px x px with a small note knocked into the corner."""
    n = px * 8
    zmask = z_mask(n)
    gl = note(int(n * .5), (0, 0, 0, 255))
    layer = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    layer.paste(gl, (int(n * .50), int(n * .50)))
    alpha = layer.split()[3]
    halo = alpha.filter(ImageFilter.MaxFilter(2 * (n // 16) + 1))
    out = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    out.putalpha(ImageChops.lighter(ImageChops.subtract(zmask, halo), alpha))
    return out.resize((px, px), Image.LANCZOS)


def write_icns(png: Image.Image, dest: Path) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "z-iris.iconset"
        iconset.mkdir()
        for base in (16, 32, 128, 256, 512):
            png.resize((base, base), Image.LANCZOS).save(iconset / f"icon_{base}x{base}.png")
            png.resize((base * 2, base * 2), Image.LANCZOS).save(iconset / f"icon_{base}x{base}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(dest)], check=True)


def main() -> None:
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else RES / "Icon.png"
    OUT.mkdir(parents=True, exist_ok=True)
    icon = app_icon(source)
    icon.save(OUT / "z-iris.png")
    write_icns(icon, OUT / "z-iris.icns")
    menubar(18).save(OUT / "z-iris-menubarTemplate.png")
    menubar(36).save(OUT / "z-iris-menubarTemplate@2x.png")


if __name__ == "__main__":
    main()
