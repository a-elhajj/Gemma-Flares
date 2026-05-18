# Gemma Flares Product Truth README

Public claim guardrails for submissions, reviewer walkthroughs, and
external-facing copy.

## Public Product Claim

Gemma Flares is a local-first iPhone copilot for IBD tracking and GI visit
preparation. It combines deterministic risk-pattern scoring with grounded
Gemma-assisted explanation, symptom/lab capture, and doctor-ready summaries.

## What We Can Claim

- Local-first IBD tracking and visit-prep workflow.
- Disease-aware check-ins for Crohn's disease, ulcerative colitis,
  indeterminate colitis, and IBS-style tracking.
- Apple Health / Apple Watch context with explicit user permission.
- Deterministic 7-day, 14-day, and 21-day risk-pattern scoring.
- Symptom/lab/procedure logging with review-before-save gates.
- Lab photo or pasted-text intake with extraction review before save.
- Doctor-ready GI summary with PDF/share flow.
- Local export and local delete/wipe controls.
- No-model iOS release path where first-run setup can download and verify
  approved LiteRT-LM artifacts before local inference.

## What We Must Not Claim

- Do not claim diagnosis of flares or any medical condition.
- Do not claim medication start/stop/dose recommendations.
- Do not claim first setup is fully cloud-free.
- Do not claim Gemma computes the risk score.
- Do not claim silent saving of health records without confirmation.
- Do not claim universal test pass status unless re-verified in the current
  environment.

## Validation Commands

Use these commands to verify release-ready technical claims:

```bash
flutter analyze --no-pub
flutter test
bash scripts/validation/validate_gold_rap.sh
flutter build ios --release --no-codesign
scripts/validation/verify_ios_release_artifact.sh build/ios/iphoneos/Runner.app --mode=no-model
```

## Source Of Truth

- Engineering evidence map: [technical-readme.md](technical-readme.md)
- Public project overview: [../README.md](../README.md)
