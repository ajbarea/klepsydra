# IMPL

Current slice: plain-text previews, branch fix/plain-said. A card's prompt and
reply (and their title tooltips) showed raw markdown; `plainText()` in
`src/fleet/model.js` now strips it. The wall still uses textContent.

## Done
- ✅ `plainText(md)`: emphasis, code, links, headings, quotes, list markers,
  rules and fences removed; lines joined; intraword `_`/`*`, paths and `2 * 3`
  kept; null stays null. A "- " after "label: " mid-line is dropped as a
  flattened list item.
- ✅ `card().prompt`/`reply` use it; wall.js title reads the same field.
- ✅ Tests in `src/fleet-model.test.js`; `?demo` reply carries markdown.

## Next
- Open PR; merge the colours slice (#34) separately.

