# Scripts

Repo-local automation for validation, model artifact handling, and iOS release
verification.

Scripts are expected to fail loudly on invalid release states. Do not weaken
these checks to bypass failures.

## Script Map

| Script | Purpose |
| --- | --- |
| [validation/validate_gold_rap.sh](validation/validate_gold_rap.sh) | Main quality gate: dependency checks, formatting, static analysis, selected tests, schema/safety checks |
| [validation/verify_ios_release_artifact.sh](validation/verify_ios_release_artifact.sh) | Verifies iOS artifact model-bundling mode (`no-model`, `e2b`, `any`) |
| [validation/verify_entitlements.sh](validation/verify_entitlements.sh) | Verifies iOS entitlements used by the runtime path |
| [install_litert_lm_models.sh](install_litert_lm_models.sh) | Downloads and verifies approved LiteRT-LM model artifact for local builds |
| [ios/prepare_ios_native_assets.sh](ios/prepare_ios_native_assets.sh) | Prepares iOS native assets for local packaging workflows |
| [ios/run_ios_profile.sh](ios/run_ios_profile.sh) | Profile-device launch helper |
| [ios/run_ios_device_agent.sh](ios/run_ios_device_agent.sh) | Device-agent runner helper |
| [maintenance/clean_flutter_workspace.sh](maintenance/clean_flutter_workspace.sh) | Local workspace cleanup helper |

## Common Commands

```bash
bash scripts/validation/validate_gold_rap.sh
flutter build ios --release --no-codesign
scripts/validation/verify_ios_release_artifact.sh build/ios/iphoneos/Runner.app --mode=no-model
scripts/install_litert_lm_models.sh e2b
```

## Gold RAP Notes

`validate_gold_rap.sh` supports local-fast and CI/full modes using environment
flags (for example `GOLD_RAP_LOCAL_DEV`, `GOLD_RAP_SKIP_TESTS`, and
`GOLD_RAP_TEST_EXCLUDE_TAGS`).

## Editing Rules

- Preserve strict shell behavior (`set -euo pipefail`) in validation scripts.
- Keep release checks deterministic and auditable.
- Document external blockers (signing, physical iPhone, TestFlight, network)
  explicitly instead of pretending local automation covered them.
