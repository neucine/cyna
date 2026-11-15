from __future__ import annotations

from collections import deque
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
BRANDING = ROOT / "docs" / "branding"
VSCODE_ICONS = ROOT / "tools" / "cyna-vscode" / "icons"
MASTER = BRANDING / "cyna-logo-master.png"

BG = (244, 235, 221, 255)
DARK_BG = (12, 22, 36, 255)
INK = (18, 43, 80, 255)
INK_DARK = (235, 240, 246, 255)
SIGNAL = (255, 106, 42, 255)


def bg_distance(pixel: tuple[int, int, int, int], bg: tuple[int, int, int, int]) -> int:
    return abs(pixel[0] - bg[0]) + abs(pixel[1] - bg[1]) + abs(pixel[2] - bg[2])


def knock_out_background(image: Image.Image, bg: tuple[int, int, int, int]) -> Image.Image:
    out = image.convert("RGBA")
    px = out.load()
    for y in range(out.height):
        for x in range(out.width):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            dist = bg_distance((r, g, b, a), bg)
            if dist <= 18:
                px[x, y] = (0, 0, 0, 0)
            elif dist <= 42:
                px[x, y] = (r, g, b, int(255 * (dist - 18) / (42 - 18)))
    return out


def find_components(image: Image.Image, min_pixels: int = 1000) -> list[tuple[int, int, int, int, int]]:
    px = image.load()
    seen = [[False] * image.width for _ in range(image.height)]
    components: list[tuple[int, int, int, int, int]] = []

    for y in range(image.height):
        for x in range(image.width):
            if seen[y][x] or px[x, y][3] == 0:
                continue
            queue = deque([(x, y)])
            seen[y][x] = True
            area = 0
            min_x = max_x = x
            min_y = max_y = y
            while queue:
                cx, cy = queue.popleft()
                area += 1
                min_x = min(min_x, cx)
                max_x = max(max_x, cx)
                min_y = min(min_y, cy)
                max_y = max(max_y, cy)
                for nx, ny in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
                    if (
                        0 <= nx < image.width
                        and 0 <= ny < image.height
                        and not seen[ny][nx]
                        and px[nx, ny][3] > 0
                    ):
                        seen[ny][nx] = True
                        queue.append((nx, ny))
            if area >= min_pixels:
                components.append((min_x, min_y, max_x + 1, max_y + 1, area))
    components.sort(key=lambda item: item[0])
    return components


def union_box(parts: list[tuple[int, int, int, int, int]]) -> tuple[int, int, int, int]:
    return (
        min(part[0] for part in parts),
        min(part[1] for part in parts),
        max(part[2] for part in parts),
        max(part[3] for part in parts),
    )


def crop(image: Image.Image, box: tuple[int, int, int, int]) -> Image.Image:
    return image.crop(box).copy()


def bbox_alpha(image: Image.Image) -> tuple[int, int, int, int]:
    px = image.load()
    min_x = min_y = 10**9
    max_x = max_y = -1
    for y in range(image.height):
        for x in range(image.width):
            if px[x, y][3] > 0:
                min_x = min(min_x, x)
                min_y = min(min_y, y)
                max_x = max(max_x, x)
                max_y = max(max_y, y)
    return (min_x, min_y, max_x + 1, max_y + 1)


def recolor_mark(image: Image.Image, fg: tuple[int, int, int, int]) -> Image.Image:
    out = Image.new("RGBA", image.size, (0, 0, 0, 0))
    src = image.load()
    dst = out.load()
    for y in range(image.height):
        for x in range(image.width):
            r, g, b, a = src[x, y]
            if a == 0:
                continue
            if abs(r - SIGNAL[0]) + abs(g - SIGNAL[1]) + abs(b - SIGNAL[2]) < 120:
                dst[x, y] = (SIGNAL[0], SIGNAL[1], SIGNAL[2], a)
            else:
                dst[x, y] = (fg[0], fg[1], fg[2], a)
    return out


def center_on_canvas(
    content: Image.Image,
    canvas_size: tuple[int, int],
    bg: tuple[int, int, int, int],
) -> Image.Image:
    out = Image.new("RGBA", canvas_size, bg)
    x = (canvas_size[0] - content.width) // 2
    y = (canvas_size[1] - content.height) // 2
    out.alpha_composite(content, (x, y))
    return out


def resize_fill_square(image: Image.Image, size: int, padding_ratio: float = 0.0) -> Image.Image:
    side = max(image.width, image.height)
    side = int(round(side * (1 + padding_ratio * 2)))
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    x = (side - image.width) // 2
    y = (side - image.height) // 2
    canvas.alpha_composite(image, (x, y))
    return canvas.resize((size, size), Image.Resampling.LANCZOS)


def average_ink(image: Image.Image) -> tuple[int, int, int, int]:
    src = image.convert("RGBA")
    px = src.load()
    total_r = total_g = total_b = total_a = count = 0
    for y in range(src.height):
        for x in range(src.width):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            total_r += r
            total_g += g
            total_b += b
            total_a += a
            count += 1
    if count == 0:
        return INK
    return (
        total_r // count,
        total_g // count,
        total_b // count,
        total_a // count,
    )


def build_cyna_n(p_letter: Image.Image, a_letter: Image.Image, fg: tuple[int, int, int, int]) -> Image.Image:
    p = recolor_mark(p_letter, fg)
    a = recolor_mark(a_letter, fg)
    n = p.crop((0, 0, p.width, a.height)).copy()

    # Reuse the original right stem edge from `a` so the new `n` keeps
    # the same antialiasing profile as the source wordmark.
    right_stem_width = 34
    right_stem = a.crop((a.width - right_stem_width, 0, a.width, a.height))
    n.alpha_composite(right_stem, (n.width - right_stem_width, 0))
    return n


def build_cyna_word(letters: dict[str, Image.Image]) -> Image.Image:
    fg = average_ink(letters["a"])
    c = recolor_mark(letters["c"], fg)
    y_raw = recolor_mark(letters["y"], fg)
    y = y_raw.resize(
        (
            int(round(y_raw.width * 0.9)),
            int(round(y_raw.height * 0.9)),
        ),
        Image.Resampling.LANCZOS,
    )
    a = recolor_mark(letters["a"], fg)
    n = build_cyna_n(letters["p"], letters["a"], fg)
    spacing_cy = 16
    spacing_yn = 5
    spacing_na = 6
    top_offsets = {
        "c": 0,
        "y": 33,
        "n": 7,
        "a": 7,
    }
    width = c.width + spacing_cy + y.width + spacing_yn + n.width + spacing_na + a.width
    height = 249
    out = Image.new("RGBA", (width, height), (0, 0, 0, 0))

    x = 0
    out.alpha_composite(c, (x, top_offsets["c"]))
    x += c.width + spacing_cy
    out.alpha_composite(y, (x, top_offsets["y"]))
    x += y.width + spacing_yn
    out.alpha_composite(n, (x, top_offsets["n"]))
    x += n.width + spacing_na
    out.alpha_composite(a, (x, top_offsets["a"]))
    return out


def build_assets() -> None:
    master = Image.open(MASTER).convert("RGBA")
    flat = knock_out_background(master, BG)
    components = find_components(flat)
    if len(components) < 8:
        raise RuntimeError("Expected at least 8 major components in the master branding image.")

    mark_box = union_box(components[:4])
    word_box = union_box(components[4:8])
    full_box = (mark_box[0], mark_box[1], word_box[2], max(mark_box[3], word_box[3]))

    mark = crop(flat, mark_box)
    word = crop(flat, word_box)
    full = crop(flat, full_box)
    cyna_word = build_cyna_word(
        {
            "c": crop(flat, components[4][:4]),
            "y": crop(flat, components[5][:4]),
            "p": crop(flat, components[6][:4]),
            "a": crop(flat, components[7][:4]),
        }
    )
    full_cyna = Image.new("RGBA", (mark.width + 171 + cyna_word.width, max(mark.height, cyna_word.height)), (0, 0, 0, 0))
    full_cyna.alpha_composite(mark, (0, (full_cyna.height - mark.height) // 2))
    full_cyna.alpha_composite(cyna_word, (mark.width + 171, (full_cyna.height - cyna_word.height) // 2))

    mark_dark = recolor_mark(mark, INK_DARK)
    word_dark = recolor_mark(word, INK_DARK)
    full_dark = recolor_mark(full, INK_DARK)
    cyna_word_dark = recolor_mark(cyna_word, INK_DARK)
    full_cyna_dark = recolor_mark(full_cyna, INK_DARK)

    preview = master.copy()
    preview.save(BRANDING / "cyna-logo-preview.png")

    center_on_canvas(full, (1610, 719), BG).save(BRANDING / "cyna-logo-final.png")
    center_on_canvas(full_dark, (1610, 719), DARK_BG).save(BRANDING / "cyna-logo-dark.png")
    center_on_canvas(full_cyna, (1610, 719), BG).save(BRANDING / "cyna-logo-final.png")
    center_on_canvas(full_cyna_dark, (1610, 719), DARK_BG).save(BRANDING / "cyna-logo-dark.png")

    vertical_canvas = Image.new("RGBA", (1059, 1248), BG)
    x_mark = (vertical_canvas.width - mark.width) // 2
    vertical_canvas.alpha_composite(mark, (x_mark, 180))
    word_scaled = word.resize((int(round(word.width * 0.92)), int(round(word.height * 0.92))), Image.Resampling.LANCZOS)
    x_word = (vertical_canvas.width - word_scaled.width) // 2
    vertical_canvas.alpha_composite(word_scaled, (x_word, 700))
    vertical_canvas.save(BRANDING / "cyna-logo-vertical.png")

    vertical_dark = Image.new("RGBA", (1059, 1248), DARK_BG)
    vertical_dark.alpha_composite(mark_dark, (x_mark, 180))
    word_dark_scaled = word_dark.resize(word_scaled.size, Image.Resampling.LANCZOS)
    vertical_dark.alpha_composite(word_dark_scaled, (x_word, 700))
    vertical_dark.save(BRANDING / "cyna-logo-vertical-dark.png")

    vertical_cyna = Image.new("RGBA", (1059, 1248), BG)
    vertical_cyna.alpha_composite(mark, (x_mark, 180))
    cyna_word_scaled = cyna_word.resize((int(round(cyna_word.width * 0.92)), int(round(cyna_word.height * 0.92))), Image.Resampling.LANCZOS)
    x_cyna_word = (vertical_cyna.width - cyna_word_scaled.width) // 2
    vertical_cyna.alpha_composite(cyna_word_scaled, (x_cyna_word, 700))
    vertical_cyna.save(BRANDING / "cyna-logo-vertical.png")

    vertical_cyna_dark = Image.new("RGBA", (1059, 1248), DARK_BG)
    vertical_cyna_dark.alpha_composite(mark_dark, (x_mark, 180))
    cyna_word_dark_scaled = cyna_word_dark.resize(cyna_word_scaled.size, Image.Resampling.LANCZOS)
    vertical_cyna_dark.alpha_composite(cyna_word_dark_scaled, (x_cyna_word, 700))
    vertical_cyna_dark.save(BRANDING / "cyna-logo-vertical-dark.png")

    mark.save(BRANDING / "cyna-mark.png")
    mark_dark.save(BRANDING / "cyna-mark-dark.png")
    mark.save(BRANDING / "cyna-mark.png")
    mark_dark.save(BRANDING / "cyna-mark-dark.png")
    mark_512 = resize_fill_square(mark, 512)
    mark_dark_512 = resize_fill_square(mark_dark, 512)
    vscode_256 = resize_fill_square(mark, 256, padding_ratio=0.24)
    vscode_dark_256 = resize_fill_square(mark_dark, 256, padding_ratio=0.24)

    mark_512.save(BRANDING / "cyna-mark-512.png")
    mark_dark_512.save(BRANDING / "cyna-mark-dark-512.png")
    vscode_256.save(BRANDING / "cyna-vscode-icon.png")
    mark_512.save(BRANDING / "cyna-mark-512.png")
    mark_dark_512.save(BRANDING / "cyna-mark-dark-512.png")

    VSCODE_ICONS.mkdir(parents=True, exist_ok=True)
    vscode_256.save(VSCODE_ICONS / "cyna-file-icon-light.png")
    vscode_dark_256.save(VSCODE_ICONS / "cyna-file-icon-dark.png")
    mark_512.save(VSCODE_ICONS / "cyna-extension-icon.png")


def main() -> None:
    build_assets()
    print("wrote branding PNG assets")


if __name__ == "__main__":
    main()
