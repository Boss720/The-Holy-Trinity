# PLAN.md

Per-module checklist. Owner = claude | codex | antigravity.

## Module 0: Setup
- [x] Shared rules (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`) - claude
- [x] Codex wrappers (`scripts\codex-review.cmd`, `scripts\codex-ask.cmd`) - claude
- [x] Worktree + board script (`scripts\agent-task.ps1`) - claude
- [x] Fill "Project commands" in `AGENTS.md` once code exists - claude

## Module 1: MetaStrip Electron app (metadata stripper)
- [x] Strip engine `src/strip/` (JPEG, PNG, WebP, PDF, DOCX/XLSX/PPTX) - claude
- [x] Electron main + preload + renderer UI (`src/`) - claude
- [x] Unit tests `test/strip.test.js` (9 pass) - claude
- [x] Smoke run through real UI with Pillow-made samples - claude
- [ ] Installer / packaged exe (electron-builder or similar) - unassigned
- [ ] More formats: TIFF, GIF, HEIC, MP4/MOV, ODF - unassigned
