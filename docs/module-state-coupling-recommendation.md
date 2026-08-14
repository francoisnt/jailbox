# Recommendation: contain cross-module global state

## Concern

`jailbox` declares many globals that `host/*.sh` modules populate by side
effect. Launch behavior depends on step order; for example, proxy configuration
sets values later consumed by editor, SSH, and downloader-proxy code. This makes
individual modules harder to reason about and test.

## Recommendation

Do not undertake a broad refactor solely for this issue. For new work, keep
state ownership and ordering dependencies explicit, avoid adding unnecessary
globals, and add focused tests around any newly introduced coupling.
