# Gemma Flares Technical README

Engineering proof map for the current public repository.

Use this document for implementation boundaries, validation commands, and
code-level evidence references.

## Architecture Boundary

Gemma Flares is a Flutter + iOS app for IBD tracking.

- Deterministic app code owns scoring, routing, persistence, validation, and
  save/delete truth.
- Gemma is used for grounded explanation, extraction drafts, and readable
  summaries within safety constraints.

## Implemented Areas And Evidence

| Area | Current behavior | Evidence |
| --- | --- | --- |
| Home copilot | Single-screen chat/risk workflow with setup gating and pending-action handling | [../lib/features/home/home_screen.dart](../lib/features/home/home_screen.dart), [../lib/features/home/widgets/chat_surface_widget.dart](../lib/features/home/widgets/chat_surface_widget.dart), [../test/features/home_screen_checkin_flow_test.dart](../test/features/home_screen_checkin_flow_test.dart) |
| Disease-aware check-in | CD/UC/IC/IBS-aware check-in paths | [../lib/features/checkin/checkin_screen.dart](../lib/features/checkin/checkin_screen.dart), [../lib/core/services/ibd_checkin_service.dart](../lib/core/services/ibd_checkin_service.dart), [../test/core/services/ibd_equity_test.dart](../test/core/services/ibd_equity_test.dart) |
| Risk engine | Deterministic 7d/14d/21d risk computation with stability layers | [../lib/core/services/risk_engine_service.dart](../lib/core/services/risk_engine_service.dart), [../lib/core/services/production_risk_adjustment_service.dart](../lib/core/services/production_risk_adjustment_service.dart), [../lib/core/services/score_stability_gate.dart](../lib/core/services/score_stability_gate.dart) |
| Lab risk | Deterministic normalization and lab-to-risk contribution | [../lib/core/services/lab_normalization_service.dart](../lib/core/services/lab_normalization_service.dart), [../lib/core/services/lab_risk_contribution_service.dart](../lib/core/services/lab_risk_contribution_service.dart), [../test/core/services/risk_engine_lab_integration_test.dart](../test/core/services/risk_engine_lab_integration_test.dart) |
| Apple Health bridge | HealthKit ingestion + deterministic wearable aggregation | [../ios/Runner/HealthKitBridge.swift](../ios/Runner/HealthKitBridge.swift), [../lib/core/services/health_sync_service.dart](../lib/core/services/health_sync_service.dart), [../lib/core/services/wearable_aggregation_service.dart](../lib/core/services/wearable_aggregation_service.dart) |
| Lab/photo intake | OCR bridge + review-before-save extraction flow | [../ios/Runner/LabTextRecognitionBridge.swift](../ios/Runner/LabTextRecognitionBridge.swift), [../lib/features/health_records/lab_report_import_screen.dart](../lib/features/health_records/lab_report_import_screen.dart), [../lib/core/services/photo_intake_service.dart](../lib/core/services/photo_intake_service.dart) |
| Local agent | Intent routing, task contracts, tool dispatch, safety boundaries | [../lib/core/services/local_agent_service.dart](../lib/core/services/local_agent_service.dart), [../lib/core/services/gemma_task_service.dart](../lib/core/services/gemma_task_service.dart), [../lib/core/services/gemma_tool_dispatch_service.dart](../lib/core/services/gemma_tool_dispatch_service.dart) |
| Local model runtime | LiteRT-LM runtime contracts + first-run model download/verification | [../lib/core/services/local_model_runtime.dart](../lib/core/services/local_model_runtime.dart), [../lib/core/services/litert_lm_download_service.dart](../lib/core/services/litert_lm_download_service.dart), [../scripts/validation/verify_ios_release_artifact.sh](../scripts/validation/verify_ios_release_artifact.sh) |
| GI summary / PDF | Doctor summary generation with PDF/share flow | [../lib/features/health_records/doctor_summary_screen.dart](../lib/features/health_records/doctor_summary_screen.dart), [../lib/core/services/doctor_summary_pdf_service.dart](../lib/core/services/doctor_summary_pdf_service.dart), [../test/features/gi_summary_share_flow_test.dart](../test/features/gi_summary_share_flow_test.dart) |
| Local data controls | Export, wipe, memory controls, diagnostics | [../lib/core/services/local_data_controls_service.dart](../lib/core/services/local_data_controls_service.dart), [../lib/core/services/memory_controls_service.dart](../lib/core/services/memory_controls_service.dart), [../lib/features/settings/settings_screen.dart](../lib/features/settings/settings_screen.dart) |

## Deterministic vs Gemma Boundary

| Deterministic code owns | Gemma may help with |
| --- | --- |
| Risk math, validation, routing, persistence, confirmation truth | Plain-language explanation of grounded evidence |
| Save/delete control and safety gates | Structured extraction drafts before review |
| Local storage and export/wipe behavior | Readability improvements in summaries |

## Validation Commands

```bash
flutter pub get
flutter analyze --no-pub
flutter test
bash scripts/validation/validate_gold_rap.sh
flutter build ios --release --no-codesign
scripts/validation/verify_ios_release_artifact.sh build/ios/iphoneos/Runner.app --mode=no-model
```

Physical iPhone validation, signing, TestFlight upload, and App Store Connect
processing require external infrastructure beyond repo-local automation.

## Repository Map

| Path | Purpose |
| --- | --- |
| [../lib/](../lib/) | Flutter app features and core services |
| [../ios/](../ios/) | Native iOS bridges and runtime packaging |
| [../db/](../db/) | Ordered SQLite migrations |
| [../assets/](../assets/) | Clinical catalogs and model configuration assets |
| [../test/](../test/) | Unit/widget/feature/adversarial/integration tests |
| [../scripts/](../scripts/) | Validation, artifact, and workflow scripts |
| [./](./) | Public technical and product claim docs |

## Contribution Rules

1. Read owning code and nearby tests before changing behavior.
2. Add targeted tests for behavior changes.
3. Run smallest relevant validation first, then broader gates.
4. Keep external claims mapped to code, tests, or scripts.
5. Preserve local-first and review-before-save behavior.
