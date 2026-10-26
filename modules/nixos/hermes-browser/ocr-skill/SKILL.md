---
name: ocr
description: Read text from scanned PDFs, photos and screenshots of documents (English and Thai) with the `ocr` CLI on this fleet's own GPU. Use when read_file reports NEEDS OCR or a PDF coverage note says pages have no text layer, or when a document arrives as an image.
---

# OCR on this host

Documents stay on our own machines: `ocr` sends them to the OCR model on
vit (Typhoon OCR, trained for Thai and English documents), never to a
third-party service. Use it for private papers (medical, financial, IDs)
instead of uploading them anywhere or describing them with vision.

- `read_file` on a PDF that is entirely scanned already runs this OCR
  and returns Markdown. Nothing to do.
- A PDF where only some pages are scans: `read_file` names those pages
  in its note. OCR just them: `ocr --pages 3-5 file.pdf`.
- An image of a document (PNG, JPEG, TIFF, WebP, HEIC; photos are
  turned upright): `ocr photo.jpg`.
- Long output: `ocr file.pdf -o file.md`, then `read_file file.md`.

Output is Markdown; tables come as HTML `<table>`, figures as a
`<figure>` description, page numbers as `<page_number>`. A multi-page
result marks each page with `<!-- page N of M -->`.

## Timing and limits

- The first call after ~5 idle minutes loads the model (about 5-20 s).
- About 3-10 s per page, two pages at a time. One call stops after
  ~270 s; pages not done by then are marked in the output and `ocr`
  exits 2 naming them: rerun with `--pages <those>`. For a document of
  more than ~50 pages, OCR it in ranges.
- If `ocr` says the endpoint is unreachable, retry once; then report it.

## Checking the result

OCR can misread digits, names and Thai tone marks. For values that
matter (doses, lab results, dates, ID numbers), say they come from OCR
and quote them as read; do not silently "correct" them.
