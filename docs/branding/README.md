# Cyna Branding

This directory contains the current branding assets for Cyna.

## Primary Asset

- `cyna-logo-master.png`
  Legacy raster source that still provides the approved mark geometry used to
  regenerate the current PNG branding set.
- `cyna-logo-final.png`
  Primary horizontal logo lockup on the light brand background with the
  lowercase `cyna` wordmark.
- `cyna-logo-final.svg`
  Vector version of the primary horizontal lockup.
- `cyna-logo-preview.png`
  Raster preview of the primary lockup.
- `cyna-logo-dark.png`
  Horizontal lockup for dark surfaces.
- `cyna-logo-dark.svg`
  Vector dark-surface horizontal lockup.
- `cyna-logo-vertical.png`
  Vertical lockup for narrow or stacked layouts.
- `cyna-logo-vertical.svg`
  Vector vertical lockup for stacked layouts.
- `cyna-logo-vertical-dark.png`
  Dark-surface vertical lockup using the same approved mark and lowercase
  wordmark.
- `cyna-logo-vertical-dark.svg`
  Vector dark-surface vertical lockup.
- `cyna-mark.png`
  Primary symbol-only mark based on the approved lockup geometry.
- `cyna-mark-512.png`
  Square 512px symbol asset for app surfaces and general icon use.
- `cyna-mark-dark.png`
  Dark-surface mark derived from the approved symbol only.
- `cyna-mark-dark-512.png`
  512px dark-surface mark asset.
- `cyna-vscode-icon.png`
  Square 256px symbol asset sized for VS Code extension and editor surfaces.

## Palette

- background: `#F4EBDD`
- ink: `#10233F`
- signal: `#FF6A2A`

## Practical Rule

Use `cyna-logo-final.png` by default. Use `cyna-logo-dark.png` on dark
surfaces. Use `cyna-logo-vertical.png` or `cyna-logo-vertical-dark.png` when a
stacked lockup fits better. Switch to `cyna-mark.png`, `cyna-mark-dark.png`,
or `cyna-vscode-icon.png` when the layout is too constrained for the full
lockup. Use the matching `.svg` lockups when a vector format is preferred.

## Regeneration

- `scripts/generate_branding_png.py`
  Rebuilds the PNG branding assets from the legacy raster master.
- `scripts/generate_branding_svg.py`
  Rebuilds the SVG lockups from the generated PNG lockups with configurable
  theme, font, sizing, and letter spacing.
- `requirements.txt`
  Minimal Python dependencies for the branding generators.
- `make branding-setup`
  Creates `docs/branding/.venv-branding` and installs the branding dependencies.
- `make branding`
  Rebuilds the PNG and SVG branding assets in one command.

Run those commands from `docs/branding`.
