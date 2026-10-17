# Documentation site

The [documentation site](https://bryceforsm.github.io/Windows-ISO-Updater/) is built from the repo's own
markdown with [MkDocs](https://www.mkdocs.org/) and the
[Material for MkDocs](https://squidfunk.github.io/mkdocs-material/) theme, then published to GitHub
Pages. Nothing in this folder is published itself, apart from `assets/`.

## Files

| File | Purpose |
| --- | --- |
| `mkdocs.yml` | Site configuration: navigation, theme, plugins, and which files are excluded |
| `requirements-docs.txt` | Pinned versions of MkDocs, the theme, and the plugins |
| `hooks.py` | Build hook that removes GitHub-only content from each page and publishes `LICENSE` as a page |
| `assets/windows.css` | Windows-style colors and fonts (Segoe UI and Cascadia, so no web fonts are fetched) |
| `assets/logo.svg` | Logo and favicon |
| `assets/mermaid-maximize.js` | Adds a **Maximize** button to each Mermaid diagram, which opens it full-window at natural size |
| `assets/nav-releases.js` | Separates the **Releases** link from the docs pages in the sidebar and gives it the GitHub icon |

## How the pages are sourced

The site is rooted at the repo (`docs_dir: ..`), so `README.md` becomes the home page and the files in
`docs/` become the other pages, with no copies to keep in sync. Links written for GitHub, such as
`docs/usage.md` from the README or `../README.md` from a doc, work on the site unchanged.

- `mkdocs-same-dir` allows the config to live in a subfolder of the folder it builds.
- `mkdocs-github-admonitions-plugin` renders GitHub's `> [!NOTE]` style callouts as Material admonitions.
- `exclude_docs` keeps `mkdocs/`, `tools/` and the build output out of the site, while re-including
  `mkdocs/assets/`.

## GitHub-only content

`hooks.py` strips two things that only make sense on GitHub:

- Anything between `<!-- github-only -->` and `<!-- /github-only -->`, such as the README's pointer to
  this site.
- Any line that is exactly `[← Back to README](../README.md)`, since the site navigation already leads
  home.

It also publishes the repo's `LICENSE` as a `license/` page that is left out of the sidebar, and points
the README's license link at it. Without that, a file with no `.md` extension is only copied as a raw
download.

## Building locally

From the repo root:

```powershell
pip install -r mkdocs/requirements-docs.txt
mkdocs serve -f mkdocs/mkdocs.yml --strict
```

The site is served at `http://127.0.0.1:8000` and rebuilds on every save. `--strict` fails on broken
links and bad navigation entries, the same as CI.

## Publishing

`.github/workflows/docs.yml` builds the site with `--strict` on every push and pull request that touches
the docs, the examples, or this folder.

- On `main`, or a manual run with **deploy** checked, the site is published to GitHub Pages.
- On any other branch, the build is uploaded as the `docs-site` artifact instead. Download it from the
  run summary and serve the folder with `python -m http.server` to preview it.
