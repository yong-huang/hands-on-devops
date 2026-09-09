#!/usr/bin/env bash
# =============================================================================
# diagram.sh — 系列图三件套生成管线（validate → deliver → visual-check → SVG）
#
# 用法：scripts/diagram.sh <type> <images/xxx.architecture.json> <images/xxx>
#   type: architecture | workflow | sequence | dataflow | lifecycle
# 产出：xxx.html（交互版）+ xxx.svg（双主题矢量，README 内嵌，已做像素居中）
# 依赖：archify skill（node）+ puppeteer-core + Chrome（hands-on-series/scripts）
# =============================================================================
set -euo pipefail

TYPE="${1:?用法: diagram.sh <type> <src.json> <out_prefix>}"
SRC="$(cd "$(dirname "${2:?缺图源 JSON}")" && pwd)/$(basename "${2}")"
OUT="$(cd "$(dirname "${3:?缺输出前缀}")" && pwd)/$(basename "${3}")"

ARCHIFY="$HOME/.agents/skills/archify/bin/archify.mjs"
[ -x "$ARCHIFY" ] || ARCHIFY="$HOME/.zcode/skills/archify/bin/archify.mjs"
HS_SCRIPTS="$HOME/.agents/skills/hands-on-series/scripts"
[ -d "$HS_SCRIPTS" ] || HS_SCRIPTS="$HOME/.zcode/skills/hands-on-series/scripts"

echo "=====> [1/4] validate ($TYPE, showcase)"
node "$ARCHIFY" validate "$TYPE" "$SRC" --quality showcase --json

echo "=====> [2/4] deliver → $OUT.html"
node "$ARCHIFY" deliver "$TYPE" "$SRC" "$OUT.html" --quality showcase --json

echo "=====> [3/4] visual-check（四视口）"
node "$ARCHIFY" visual-check "$OUT.html" --json

echo "=====> [4/4] export SVG + pixel-center → $OUT.svg"
node "$HS_SCRIPTS/export-svg.mjs" "$OUT.html" "$OUT.svg"
node "$HS_SCRIPTS/pixel-center.mjs" "$OUT.svg"

echo "=====> 完成：$OUT.{json,html,svg}"
