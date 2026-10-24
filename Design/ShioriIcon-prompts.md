# 单假名图标视觉探索

使用内置 imagegen。生成图用于字形气质与配色探索；生产资源由 `Sources/ShioriIcon.swift` 的原生日文字形轮廓重绘，导出 SVG、PNG 与 ICNS，避免透明边缘杂点。

## 初稿提示词

```text
Use case: logo-brand.
Asset type: a single finished macOS application icon, square 1:1, 1024x1024, not a mockup.
Primary request: redesign the identity of Shiori, a Japanese manga translation app. The user wants ONLY a Japanese kana character, with much better taste and visual refinement.
Text (verbatim): "あ". This must be the ONLY glyph. Render the correct, clearly recognizable Japanese hiragana あ.
Design: a beautiful contemporary Japanese typographic logo. One generously sized deep ink-jade あ, custom drawn with confident smooth strokes, elegant open counters, and carefully balanced Japanese letterform proportions. Quiet, refined and memorable. Moderately heavy strokes, subtle natural stroke modulation and beautifully resolved terminals; the mark should feel designed, not a generic font sample. Keep the actual anatomy of あ accurate.
Composition: one warm porcelain/ivory rounded-square macOS tile with very faint cool mint ambient shading. The single dark jade kana is optically centered and takes about 60 percent of the tile, with generous balanced breathing room. Tile fills about 87 percent of the canvas; actual transparent alpha outside the tile. Front-facing, completely contained, no perspective. Crisp edges and restrained matte finish. A faint, tasteful edge highlight is sufficient; keep the face clean and calm. The mark must stay identifiable when the icon is reduced to 32px.
Constraints: one tile and one kana only. No Roman or Latin letters, no English title, no extra Japanese text, no overlapping cards, no second panel, no book, no bookmark, no fold, no speech bubble, no fish, no arrow, no flag, no sparkle, no mascot, no border around the glyph, no glass blob, no plastic gloss, no inflated bevels, no busy texture, no frame or icon grid, no surrounding interface, no watermark, no baked checkerboard. Output only the one completed icon with real outside transparency.
```

## 第二稿提示词

```text
Refine this Japanese macOS icon into a clean production asset. Keep its correct, elegant single hiragana あ, ink-jade color and warm ivory / very pale mint tile. Keep the character's existing anatomy and expressive stroke shapes.
Make the あ about 15 percent smaller, then optically center it with more balanced breathing room. Keep the front face almost flat and matte, with a smooth clean surface and only a very subtle edge highlight.
CRITICAL CLEANUP: Rebuild the outside silhouette as one mathematically smooth rounded square. Remove ALL the ragged white flecks, distressed edges, detached pixels, halo, paper texture and grain around the tile. The exterior is perfectly empty genuine transparent alpha; the tile interior is fully opaque. No fuzz or scattered fragments on any side. Produce a sharp, clean, anti-aliased icon edge. Maintain a clear transparent margin on all four sides.
The single character あ is the only content. No Latin letter, card, bookmark, book, fold, secondary shapes, extra text, border, grid, surrounding UI or watermark. Output only the finished single square app icon.
```
