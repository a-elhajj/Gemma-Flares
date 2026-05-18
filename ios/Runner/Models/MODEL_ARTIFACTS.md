# Gemma Flares Local Model Artifact Policy

This document records the expected LiteRT-LM artifact identity used by local
model install scripts and iOS artifact verification.

## Approved Artifact

| Runtime | Artifact repo | Artifact file | Expected SHA-256 |
| --- | --- | --- | --- |
| LiteRT-LM Gemma 4 E2B | `litert-community/gemma-4-E2B-it-litert-lm` | `gemma-4-E2B-it.litertlm` | `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c` |

## Release Modes

- **`no-model` (normal public release verification):** app bundle contains no
  bundled model directory.
- **`e2b` (seeded internal build):** app bundle includes
  `Models/litert-lm/gemma-4-E2B-it/model.litertlm`.

Use:

```bash
scripts/validation/verify_ios_release_artifact.sh <Runner.app|Runner.xcarchive> --mode=no-model
```

## Local Installation

```bash
scripts/install_litert_lm_models.sh e2b
```

The install script downloads, checksum-verifies, and places the model under
`ios/Runner/Models/litert-lm/gemma-4-E2B-it/model.litertlm` for local seeded
build workflows.

## Source Control Policy

Model binaries are not committed to git.
