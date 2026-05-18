# Gemma Flares / iOS model artifacts

Part of [Gemma Flares](../../../README.md). This folder is the optional local
model-artifact mount point for seeded internal iOS builds.

Normal public release verification uses a no-model app bundle. First-run setup
can download and verify approved LiteRT-LM artifacts into the app sandbox rather
than committing model binaries or forcing multi-GB assets through every Xcode
build.

## Expected layout

```text
ios/Runner/Models/
└── litert-lm/
    └── gemma-4-E2B-it/
        └── model.litertlm
```

Model binaries are intentionally ignored by git. If this folder is populated,
Xcode includes it through folder references in local builds.

## Install the approved local artifact

From the repository root:

```bash
scripts/install_litert_lm_models.sh e2b
```

The script downloads `gemma-4-E2B-it.litertlm` from the approved LiteRT-LM
artifact source, verifies its SHA-256, and installs it at:

```text
ios/Runner/Models/litert-lm/gemma-4-E2B-it/model.litertlm
```

## Verify release mode

Verify a normal public no-model app bundle:

```bash
scripts/validation/verify_ios_release_artifact.sh build/ios/iphoneos/Runner.app --mode=no-model
```

Verify a seeded E2B app bundle:

```bash
scripts/validation/verify_ios_release_artifact.sh build/ios/iphoneos/Runner.app --mode=e2b
```

Artifact policy and checksum metadata live in
[MODEL_ARTIFACTS.md](MODEL_ARTIFACTS.md). License and contribution guidance live
in the root [README](../../../README.md).
