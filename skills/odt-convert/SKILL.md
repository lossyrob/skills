---
name: odt-convert
description: Convert ODT (OpenDocument Text) files to Markdown, with a separate threaded comments file. Extracts document body via pandoc and comment threads (with anchor text and reply grouping) via Python XML parsing. Also extracts embedded images and Visio diagrams (with PNG export). Triggers include 'convert odt', 'extract odt comments', 'odt to markdown', or when working with .odt files.
compatibility: "Requires pandoc, Python 3 with standard library. Optional: olefile (pip install olefile) for Visio extraction, libreoffice (headless) for EMF-to-PNG conversion."
---

# ODT to Markdown + Comments Skill

Convert an `.odt` file into companion output files:

1. **`<name>.md`** — The document body, converted via `pandoc`, with image refs updated to point at exported artifacts.
2. **`<name>-comments.md`** — All document comments, grouped into threads with anchor text and chronological reply ordering.
3. **`<name>-embedded/`** — Subdirectory for all extracted media (images, Visio diagrams with PNG previews).

## When to Use

- User asks to convert an `.odt` file to Markdown
- User asks to extract or review comments from an `.odt` file
- User provides an `.odt` file path and wants readable output

## Workflow

Throughout this workflow, let `<dir>` be the directory containing the ODT file, `<name>` be its base name (without extension), and `<path>` be the full path without extension.

### Step 1: Validate Input

Confirm the `.odt` file exists and is a valid OpenDocument file:

```bash
file <path>.odt
```

### Step 2: Convert Document Body

```bash
pandoc <path>.odt -t markdown -o <path>.md --wrap=none --extract-media=<dir>/<name>-embedded
```

`--wrap=none` prevents hard line breaks. `--extract-media` extracts images pandoc recognizes into `<name>-embedded/` and rewrites image references. If no images are extracted and no OLE objects exist, remove the empty directory.

### Step 3: Extract Embedded Images and Visio Diagrams

ODT files are ZIP archives that can contain:
- **`Pictures/`** or **`media/`** — Inline images. Pandoc handles `Pictures/` but may fail on `media/` paths, emitting `[]{.image}` placeholders.
- **`Object N`** — OLE-embedded objects (Visio, Excel, etc.). NOT handled by pandoc.
- **`ObjectReplacements/Object N`** — EMF/WMF preview renderings of embedded objects.

Run these scripts in sequence:

**Extract inline images** (fixes `[]{.image}` placeholders if pandoc missed them):
```bash
python scripts/extract_images.py <path>.odt <path>.md <dir>/<name>-embedded <name>
```

**Extract OLE objects** (Visio diagrams with PNG previews):
```bash
python scripts/extract_ole_objects.py <path>.odt <dir>/<name>-embedded
```

**Fix Visio references** in the markdown (replaces `ObjectReplacements/` refs with extracted files):
```bash
python scripts/fix_visio_refs.py <path>.md <name>-embedded
```

| Object Type | Output Files (in `<name>-embedded/`) |
|---|---|
| Visio .vsdx diagram | `object-<N>.vsdx` + `object-<N>.png` |
| Legacy Visio .vsd | `object-<N>.vsd` (no PNG — would need full Visio) |
| Other OLE objects | Skipped with a log message |

### Step 4: Extract Threaded Comments

```bash
python scripts/extract_comments.py <path>.odt <path>-comments.md
```

Comments are grouped into threads by anchor text. Within each thread, comments are sorted chronologically — the first is the opener (💬), subsequent ones are replies (↩️).

### Step 5: Report Results

After all files are created, report:
- Path to the body Markdown file and its size
- Path to the comments Markdown file, total comment count, and thread count
- Any extracted images (count and directory)
- Any extracted Visio diagrams (.vsdx paths and PNG preview paths)
- Any issues encountered (e.g., no comments found, pandoc warnings, olefile not installed)

## Output Format

### Body Markdown (`<name>.md`)
Standard pandoc Markdown output with `--wrap=none`.

### Comments Markdown (`<name>-comments.md`)

```markdown
# Comments from <filename>.odt

**Total:** N comments in M threads

---

## Thread 1 (K replies)

> **Anchor:** <highlighted text in document>

💬 **Author Name** — 2026-02-06T15:16:00

Opening comment text here.

↩️ **Reply Author** — 2026-02-06T15:46:00

> Reply text is blockquoted for visual distinction.

---
```

## Edge Cases

- **No comments:** Still generate the body `.md`. For comments file, write a note saying "No comments found."
- **Comments without anchor text:** Show `_(no anchor text)_` in place of the anchor quote.
- **Single-comment threads:** Display without reply count or reply formatting.
- **Nested annotations:** The comment extraction script strips nested `<office:annotation>` elements from anchor text to avoid duplication.
- **No embedded objects:** Skip Step 3 silently — only report images/Visio if they exist.
- **olefile not installed:** Print a warning and skip Visio extraction. The body and comments conversion still works.
- **LibreOffice not available:** Extract the `.vsdx` file but skip PNG conversion. Print a warning.
- **Multiple embedded objects:** Each gets a sequential number (`object-1`, `object-2`, etc.) matching the ODT's internal naming.
- **Non-Visio OLE objects:** Log the CLSID and skip. Don't attempt extraction of unknown object types.
