# Subnetra documentation site

A comprehensive, **bilingual (English + 简体中文)** documentation site for
Subnetra, built with [mdBook](https://github.com/rust-lang/mdBook) and deployed to
GitHub Pages at <https://jamiesun.github.io/subnetra/>.

This directory is self-contained; it does not replace the design docs under
[`../docs/`](../docs) (which the README files link to directly).

## Layout

```
docs-site/
  index.html            root redirect — auto-detects browser language → en/ or zh/
  en/                   English book
    book.toml
    src/                Markdown chapters (SUMMARY.md + content)
    theme/              custom.css + language-switcher.js
  zh/                   Chinese book — identical file layout, Chinese content
    book.toml
    src/
    theme/
```

Both books use the **same chapter filenames** (English paths, translated content).
This is what lets the in-page **EN / 中文** switcher swap `/en/` ↔ `/zh/` on the
current path and keep the reader on the same page.

> **Keep the two `theme/` directories in sync.** `en/theme/custom.css` /
> `en/theme/language-switcher.js` must stay byte-identical to their `zh/theme/`
> counterparts. mdBook does not copy assets from outside a book's own root, so they
> are intentionally duplicated rather than shared. After editing one, copy it to the
> other:
>
> ```bash
> cp en/theme/custom.css            zh/theme/custom.css
> cp en/theme/language-switcher.js  zh/theme/language-switcher.js
> ```

## Prerequisites

[mdBook](https://rust-lang.github.io/mdBook/guide/installation.html) **0.5.3+**
and the [mdbook-mermaid](https://github.com/badboy/mdbook-mermaid) preprocessor
**0.17.0+** (the architecture diagrams are mermaid flowcharts):

```bash
# macOS
brew install mdbook
# or, any platform with Rust
cargo install mdbook --version 0.5.3

# mermaid preprocessor (not in brew — install via cargo or a release binary)
cargo install mdbook-mermaid --version 0.17.0
```

`mdbook-mermaid` must be on your `PATH`; each book's `book.toml` references it as
`command = "mdbook-mermaid"`. The `mermaid.min.js` / `mermaid-init.js` assets are
already committed next to each `book.toml`, so you only need the binary to build.

## Preview locally

`mdbook serve` watches one book and live-reloads. Serve each language on its own
port:

```bash
mdbook serve docs-site/en -p 3000 --open      # http://localhost:3000
mdbook serve docs-site/zh -p 3001 --open      # http://localhost:3001
```

When serving a single book the language switcher falls back to
`../<other>/index.html` (a best-effort link). To preview the **real** side-by-side
switching, build both and serve the assembled site:

```bash
mdbook build docs-site/en
mdbook build docs-site/zh
mkdir -p /tmp/subnetra-site
cp docs-site/index.html /tmp/subnetra-site/index.html
cp -r docs-site/en/book /tmp/subnetra-site/en
cp -r docs-site/zh/book /tmp/subnetra-site/zh
python3 -m http.server 8080 -d /tmp/subnetra-site   # http://localhost:8080
```

## Build

```bash
mdbook build docs-site/en      # → docs-site/en/book/
mdbook build docs-site/zh      # → docs-site/zh/book/
```

The `book/` output directories are git-ignored (see [`.gitignore`](.gitignore)).

## Authoring notes

- **Add a page:** create the same file in `en/src/` **and** `zh/src/`, then add a
  matching `- [Title](path.md)` line to **both** `SUMMARY.md` files. Keep the
  filenames identical across languages.
- **Internal links:** use relative `.md` links (e.g. `../concepts/architecture.md`);
  mdBook rewrites them to `.html`. Cross-page `#anchor` fragments use the slug mdBook
  derives from the heading text — for Chinese headings the CJK characters are kept,
  punctuation is dropped, and spaces become `-`.
- **External links** in `SUMMARY.md` list items break the build ("Unable to create
  missing chapters") — keep them in page bodies, not the table of contents.
- Don't hand-edit anything under `*/book/` — it is generated.

## Deployment

[`.github/workflows/docs.yml`](../.github/workflows/docs.yml) builds both books on
every push to `main` that touches `docs-site/`, assembles them into a single `site/`
tree (`site/index.html`, `site/en/`, `site/zh/`), and deploys to GitHub Pages.
Pull requests build the site (as a check) but do not deploy.

The `site-url` in each `book.toml` is set to the project-pages base
(`/subnetra/en/` and `/subnetra/zh/`); navigation is relative, so the books also
work when previewed under any other base path.
