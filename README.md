# Gemma Flares

Gemma Flares is a local-first iPhone copilot for people tracking IBD patterns.
It combines daily check-ins, Apple Health context, symptom/lab logging, and
Gemma-assisted summaries to support safer, clearer GI visit preparation.

Gemma Flares is not a diagnostic system and does not recommend medication
changes.

## What The App Does

- Tracks deterministic 7-day, 14-day, and 21-day flare-risk pattern scores.
- Supports disease-aware check-ins for Crohn's disease, ulcerative colitis,
  indeterminate colitis, and IBS-style tracking.
- Ingests Apple Health / Apple Watch context with explicit user permission.
- Captures symptoms and labs with review-before-save gates.
- Generates doctor-ready GI summaries with PDF/share flows.
- Supports local export and local data wipe controls.

## Safety Model

- Deterministic app code owns scoring, persistence, routing, and save truth.
- Gemma is used for grounded explanation and structured drafting.
- Red-flag symptom handling routes to urgent-care guidance pathways.

## Repository Scope

This public repository is focused on product code, tests, and high-trust
technical documentation. Internal planning and private workflow artifacts are
intentionally excluded from the tracked public surface.

## Documentation

- Product claim guardrails: [docs/product-truth-readme.md](docs/product-truth-readme.md)
- Technical implementation evidence: [docs/technical-readme.md](docs/technical-readme.md)
- Documentation index: [docs/README.md](docs/README.md)
- Automation scripts: [scripts/README.md](scripts/README.md)

## Developer Quick Start

```bash
flutter pub get
flutter analyze --no-pub
flutter test
```

For release artifact verification and production gate commands, use
[scripts/README.md](scripts/README.md).
