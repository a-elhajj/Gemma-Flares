# iOS Runtime Model Folder

Optional local model artifacts can be placed here for seeded internal iOS
builds.

Expected artifact path:

- `litert-lm/gemma-4-E2B-it/model.litertlm`

## Important Notes

- Model binaries are intentionally ignored by git.
- Normal public release verification uses a `no-model` app bundle and installs
  approved artifacts at first run via the app's download/verification flow.
- If this folder is populated, Xcode includes it through folder references in
  local builds.
- For local seeded setup, run:

```bash
scripts/install_litert_lm_models.sh e2b
```

For artifact policy and checksum metadata, see
[MODEL_ARTIFACTS.md](MODEL_ARTIFACTS.md).
