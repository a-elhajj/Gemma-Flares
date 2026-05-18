# Gemma Flares / docs

Part of [Gemma Flares](../README.md). This directory contains the public
documentation that backs product claims, technical boundaries, and reviewer
walkthroughs.

## Documents

| Document | Use it for |
| --- | --- |
| [product-truth-readme.md](product-truth-readme.md) | Public claim guardrails: what Gemma Flares can and cannot claim. |
| [technical-readme.md](technical-readme.md) | Engineering evidence map, validation commands, and implementation boundaries. |
| [archived/](archived/) | Historical documents that are no longer the current public source of truth. |

## How to update docs

1. Start with the behavior change in `lib/`, `ios/`, `db/`, `scripts/`, or
  `tooling/`.
2. Update the document that owns the public claim or technical evidence.
3. Keep wording stable and evidence-backed; avoid sprint notes and private
  workflow details.
4. Run the smallest relevant validation command before widening to the full
  quality gate.

```bash
flutter analyze --no-pub
flutter test --exclude-tags=slow
```

Use the root [README](../README.md) for setup, testing, deployment, security,
and contribution guidance.
