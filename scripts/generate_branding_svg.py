from __future__ import annotations

import base64
from dataclasses import dataclass
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
BRANDING = ROOT / "docs" / "branding"
FONT_FAMILY = "Black Ops One"
FONT_FILE = BRANDING / "BlackOpsOne-Regular.ttf"
SVG_NS = "http://www.w3.org/2000/svg"
WORDMARK = "cyna"


@dataclass(frozen=True)
class WrappedPngSpec:
    svg_name: str
    png_name: str


@dataclass(frozen=True)
class Theme:
    name: str
    mark_png_name: str
    text_fill: str


@dataclass(frozen=True)
class TextStyle:
    font_family: str
    font_file: Path
    font_size: int
    font_weight: int
    text_fill: str


@dataclass(frozen=True)
class WordmarkLayout:
    text: str
    start_x: int
    baseline_y: int
    letter_positions: tuple[int, ...]


@dataclass(frozen=True)
class ImagePlacement:
    x: int
    y: int
    width: int
    height: int


@dataclass(frozen=True)
class LogoLayout:
    width: int
    height: int
    mark: ImagePlacement
    wordmark: WordmarkLayout
    text_style: TextStyle


WRAPPED_PNGS = (
    WrappedPngSpec("cyna-mark.svg", "cyna-mark.png"),
    WrappedPngSpec("cyna-mark-dark.svg", "cyna-mark-dark.png"),
)

THEMES = (
    Theme("final", "cyna-mark.png", "#122b50"),
    Theme("dark", "cyna-mark-dark.png", "#ebf0f6"),
)

HORIZONTAL_LAYOUT = LogoLayout(
    width=1610,
    height=719,
    mark=ImagePlacement(
        x=151,
        y=141,
        width=398,
        height=437,
    ),
    wordmark=WordmarkLayout(
        text=WORDMARK,
        start_x=700,
        baseline_y=445,
        letter_positions=(0, 192, 372, 574),
    ),
    text_style=TextStyle(
        font_family=FONT_FAMILY,
        font_file=FONT_FILE,
        font_size=292,
        font_weight=400,
        text_fill="#122b50",
    ),
)

VERTICAL_LAYOUT = LogoLayout(
    width=1059,
    height=1248,
    mark=ImagePlacement(
        x=330,
        y=180,
        width=398,
        height=437,
    ),
    wordmark=WordmarkLayout(
        text=WORDMARK,
        start_x=188,
        baseline_y=892,
        letter_positions=(0, 150, 312, 482),
    ),
    text_style=TextStyle(
        font_family=FONT_FAMILY,
        font_file=FONT_FILE,
        font_size=224,
        font_weight=400,
        text_fill="#122b50",
    ),
)


def file_to_data_uri(path: Path, mime_type: str) -> str:
    data = base64.b64encode(path.read_bytes()).decode("ascii")
    return f"data:{mime_type};base64,{data}"


def png_to_data_uri(path: Path) -> str:
    return file_to_data_uri(path, "image/png")


def font_to_data_uri(path: Path) -> str:
    return file_to_data_uri(path, "font/ttf")


def image_size(path: Path) -> tuple[int, int]:
    width, height = Image.open(path).size
    return width, height


def build_wrapped_png_svg(png_path: Path) -> str:
    width, height = image_size(png_path)
    href = png_to_data_uri(png_path)
    return (
        f'<svg xmlns="{SVG_NS}" viewBox="0 0 {width} {height}" '
        f'width="{width}" height="{height}">\n'
        f'  <image href="{href}" width="{width}" height="{height}" />\n'
        "</svg>\n"
    )


def build_style_block(text_style: TextStyle) -> str:
    font_href = font_to_data_uri(text_style.font_file)
    return f"""  <style>
    @font-face {{
      font-family: '{text_style.font_family}';
      font-style: normal;
      font-weight: {text_style.font_weight};
      src: url('{font_href}') format('truetype');
    }}
    .wordmark {{
      fill: {text_style.text_fill};
      font-family: '{text_style.font_family}';
      font-size: {text_style.font_size}px;
      font-weight: {text_style.font_weight};
      text-transform: lowercase;
      text-rendering: geometricPrecision;
      font-kerning: normal;
    }}
  </style>"""


def build_wordmark_text(wordmark: WordmarkLayout) -> str:
    if len(wordmark.text) != len(wordmark.letter_positions):
        raise ValueError("wordmark text and letter positions must have the same length")

    lines: list[str] = []
    for letter, offset in zip(wordmark.text, wordmark.letter_positions):
        x = wordmark.start_x + offset
        lines.append(f'  <text class="wordmark" x="{x}" y="{wordmark.baseline_y}">{letter}</text>')
    return "\n".join(lines)


def build_logo_svg(layout: LogoLayout, theme: Theme) -> str:
    mark_href = png_to_data_uri(BRANDING / theme.mark_png_name)
    text_style = TextStyle(
        font_family=layout.text_style.font_family,
        font_file=layout.text_style.font_file,
        font_size=layout.text_style.font_size,
        font_weight=layout.text_style.font_weight,
        text_fill=theme.text_fill,
    )
    mark = layout.mark
    style_block = build_style_block(text_style)
    wordmark_text = build_wordmark_text(layout.wordmark)

    return f"""<svg xmlns="{SVG_NS}" viewBox="0 0 {layout.width} {layout.height}" width="{layout.width}" height="{layout.height}">
{style_block}
  <image href="{mark_href}" x="{mark.x}" y="{mark.y}" width="{mark.width}" height="{mark.height}" />
{wordmark_text}
</svg>
"""


def write_file(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    print(f"wrote {path.relative_to(ROOT)}")


def main() -> None:
    for spec in WRAPPED_PNGS:
        write_file(BRANDING / spec.svg_name, build_wrapped_png_svg(BRANDING / spec.png_name))

    for theme in THEMES:
        horizontal_name = "cyna-logo-final.svg" if theme.name == "final" else f"cyna-logo-{theme.name}.svg"
        vertical_name = "cyna-logo-vertical.svg" if theme.name == "final" else f"cyna-logo-vertical-{theme.name}.svg"
        write_file(BRANDING / horizontal_name, build_logo_svg(HORIZONTAL_LAYOUT, theme))
        write_file(BRANDING / vertical_name, build_logo_svg(VERTICAL_LAYOUT, theme))


if __name__ == "__main__":
    main()
