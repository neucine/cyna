# cyna.dev site content

`site.json` is the cyna.dev manifest and this directory's `docs/` is the release snapshot that
the `neucine/sites` workspace syncs and publishes.

## Generated files

`scripts/prepare_site_content.py` generates these from the repository's public
`docs/` pages:

- `docs/spec.md`, `cheatsheet.md`, `guide.md`, `concurrency.md`,
  `semantics.md`, `runtime.md`, `philosophy.md`, `status.md`, `build.md`,
  `toolchain.md`, `glossary.md`
- `docs/std-runtime-api.md` and one `std-*.md` page per standard-library
  module, generated from `docs/std/`
- `docs/release-<version>.md` for the current release
- the homepage version label in `docs/index.md`

Do not edit generated files by hand. Change the source document in the
repository's `docs/` directory and
run:

```sh
python3 scripts/prepare_site_content.py --version <version>
```

## Site-owned files

- `docs/index.md` (apart from its generated version label)
- `docs/language_gaps.md`, a short pointer for older release notes; current limitations live in
  `docs/STATUS.md`
- the manifest `site.json`
- older `docs/release-*.md` archives

The release flow (`scripts/release_distribution.py`) regenerates this directory
before publishing. `python3 scripts/prepare_site_content.py --check` verifies a
snapshot without writing it.
