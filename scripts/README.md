# Gemma Flares / scripts

Part of [Gemma Flares](../README.md). This directory contains repo-local
automation for validation, model artifact handling, iOS profile runs, release
artifact checks, and workspace maintenance.

Scripts are expected to fail loudly on invalid release states. Do not weaken
these checks to bypass failures.

## Requirements

| Requirement | Used by |
| --- | --- |
| Flutter and Dart | Gold RAP, iOS builds, QA tooling |
| Xcode command-line tools | iOS build and device workflows |
| `hf` CLI | `install_litert_lm_models.sh e2b` |
| `shasum` | LiteRT-LM checksum verification |

## Script reference

| Script | Purpose |
| --- | --- |
| [validation/validate_gold_rap.sh](validation/validate_gold_rap.sh) | Runs dependency, formatting, analysis, selected test, schema, and safety-copy checks. |
| [validation/verify_ios_release_artifact.sh](validation/verify_ios_release_artifact.sh) | Verifies iOS artifact model-bundling mode: `no-model`, `e2b`, or `any`. |
| [validation/verify_entitlements.sh](validation/verify_entitlements.sh) | Checks iOS entitlements used by the runtime path. |
| [install_litert_lm_models.sh](install_litert_lm_models.sh) | Downloads, checksum-verifies, and installs the approved LiteRT-LM Gemma 4 E2B artifact. |
| [ios/prepare_ios_native_assets.sh](ios/prepare_ios_native_assets.sh) | Prepares iOS native assets for local packaging workflows. |
| [ios/run_ios_profile.sh](ios/run_ios_profile.sh) | Runs a profile build on a device with model-bundling controls and disk-space checks. |
| [ios/run_ios_device_agent.sh](ios/run_ios_device_agent.sh) | Runs the device-agent app surface. |
| [maintenance/clean_flutter_workspace.sh](maintenance/clean_flutter_workspace.sh) | Cleans local Flutter workspace artifacts. |

## Common commands

Run the local development quality gate:

```bash
GOLD_RAP_LOCAL_DEV=1 bash scripts/validation/validate_gold_rap.sh
```

Run schema and safety checks only, matching the CI invariant job:

```bash
GOLD_RAP_SCHEMA_SAFETY_ONLY=1 bash scripts/validation/validate_gold_rap.sh
```

Build and verify a public no-model iOS artifact:

```bash
flutter build ios --release --no-codesign
scripts/validation/verify_ios_release_artifact.sh build/ios/iphoneos/Runner.app --mode=no-model
```

Install the approved E2B model for seeded local builds:

```bash
scripts/install_litert_lm_models.sh e2b
```

Run a fast profile build on a physical device:

```bash
scripts/ios/run_ios_profile.sh --fast-ui --reset-setup -d <device-id>
```

## Configuration

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `GEMMA_FLARES_CLEAN_DERIVED_DATA` | No | `0` | Removes Xcode DerivedData during profile helper runs when set to `1`. |
| `GEMMA_FLARES_IOS_PROFILE_MODEL_MODE` | No | `none` | Selects profile model mode: `none`, `e2b`, or `keep`. |
| `GEMMA_FLARES_MAX_ACTIVE_MODEL_GB` | No | `8` | Maximum active model folder size accepted by the profile helper. |
| `GEMMA_FLARES_MIN_NO_MODEL_IOS_PROFILE_FREE_GB` | No | `8` | Free-space floor for no-model profile runs. |
| `GEMMA_FLARES_MODEL_CACHE` | No | `~/Library/Application Support/Gemma Flares/ModelArtifacts/litert-lm` | Cache used when moving bundled models out of the iOS project. |
| `GEMMA_FLARES_RETRY_DEVICECTL` | No | `1` | Enables retry behavior for device-control operations. |
| `GOLD_RAP_LOCAL_DEV` | No | `1` outside CI, `0` in CI | Uses faster local Gold RAP defaults. |
| `GOLD_RAP_SCHEMA_SAFETY_ONLY` | No | `0` | Runs only schema and safety checks. |
| `GOLD_RAP_SKIP_GEMMA_EVAL` | No | follows `GOLD_RAP_LOCAL_DEV` | Controls the disabled Gemma 4 eval block in Gold RAP. |
| `GOLD_RAP_SKIP_TESTS` | No | `0` | Skips Gold RAP tests. |
| `GOLD_RAP_SKIP_UI_WIDGET` | No | follows `GOLD_RAP_LOCAL_DEV` | Skips app, feature, and widget test targets. |
| `GOLD_RAP_TEST_EXCLUDE_TAGS` | No | `extended,slow` in local dev | Tags excluded from Gold RAP test runs. |
| `LITERT_LM_E2B_SHA` | No | approved SHA-256 | Overrides the expected E2B model checksum. |
| `LITERT_LM_MODEL_DOWNLOADS_DIR` | No | `/private/tmp/litert-lm-model-downloads` | Download staging directory for model artifacts. |

## Editing rules

- Preserve strict shell behavior with `set -euo pipefail`.
- Keep release checks deterministic and auditable.
- Document external blockers such as signing, physical device access,
  TestFlight, network access, and model downloads.
- Prefer adding checks over weakening existing gates.

License and contribution guidance live in the root [README](../README.md).
