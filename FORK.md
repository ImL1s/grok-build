# ImL1s fork of xai-org/grok-build

This repository is **[ImL1s/grok-build](https://github.com/ImL1s/grok-build)**, a friendly fork of **[xai-org/grok-build](https://github.com/xai-org/grok-build)** with a long-lived multi-provider / local LLM product line.

Remotes:

| Remote     | URL                                         | Role                          |
|------------|---------------------------------------------|-------------------------------|
| `upstream` | `https://github.com/xai-org/grok-build.git` | Read-only upstream mirror     |
| `origin`   | `https://github.com/ImL1s/grok-build.git`   | Fork: PRs, releases, default  |

## Branch model

| Branch       | Role                                                                 |
|--------------|----------------------------------------------------------------------|
| `main`       | **Pristine upstream mirror.** Only fast-forward from `upstream/main`. Never land provider/custom commits here. |
| `providers`  | **Product line.** Multi-provider credentials, keyless local LLMs, fork docs/UX. Default branch for users and releases. |

Feature topic branches (e.g. `feat/…`) merge into `providers`, not into `main`.

## Weekly upstream sync

Do **not** force-push `main`. Prefer merge (not rebase) when integrating upstream into the published `providers` line.

1. Ensure a clean tracked working tree (untracked files such as local notes are OK).
2. Run:

   ```bash
   ./scripts/sync-upstream.sh
   ```

   The script:

   - Fetches `upstream` and `origin`
   - Fast-forward updates local `main` from `upstream/main` and pushes `origin main`
   - Creates `sync/upstream-YYYYMMDD` from `providers` (or creates `providers` from the current tip if missing)
   - Merges `main` into the sync branch
   - Prints next steps for opening a PR into `providers` (uses `gh` when available; does not require it)

3. Review the sync PR, resolve conflicts carefully on the watchlist, run auth/config smoke tests, then merge into `providers`.

Optional hygiene (local git config, not enforced by the script):

```bash
git config rerere.enabled true
git config merge.conflictstyle zdiff3
```

## Watchlist (auth / config / picker)

On every sync PR, review upstream diffs that touch:

- `crates/codegen/xai-grok-sampler/` — especially `AuthScheme`, `client.rs`, credential headers
- `crates/codegen/xai-grok-shell/src/agent/` — `ConfigModelOverride`, `resolve_credentials`, `auth_method.rs`
- `crates/codegen/xai-grok-shell/src/session/` — ACP session reconstruct / model switch
- `crates/codegen/xai-grok-pager/` — `/model` slash command, model picker (`Ctrl+M`), `available_models` rendering
- Custom models docs: `crates/codegen/xai-grok-pager/docs/user-guide/11-custom-models.md`

Prefer keeping fork intent on auth hotspots (`AuthScheme::None`, `local.none`, no ambient xAI credential leak) rather than blindly taking upstream.

## Tagging

Release tags track upstream plus a fork counter:

```text
v{upstream}+providers.N
```

Examples: `v0.0.0+providers.1`, or `v1.2.3+providers.1` when upstream publishes a real SemVer. Put the upstream `main` SHA in the release notes. Prefer SemVer **build metadata** (`+providers.N`) over a prerelease suffix (`-providers`), which sorts older than the base version.

## Docs

- Implementation plan: [docs/plans/2026-07-23-multi-provider-local-llm.md](docs/plans/2026-07-23-multi-provider-local-llm.md)
- Custom models / providers guide: [crates/codegen/xai-grok-pager/docs/user-guide/11-custom-models.md](crates/codegen/xai-grok-pager/docs/user-guide/11-custom-models.md)

## TUI and config

- **Source of truth for providers:** `~/.grok/config.toml` — `[model.*]` entries (`auth_scheme`, `env_key`, `api_backend`, `base_url`, …) and optional `[models].default`.
- **Day-to-day switching:** TUI `/model` (or `/m`) and **Ctrl+M** (model picker from scrollback). The picker selects from the catalog; it does not replace editing `config.toml` for adding providers.

Do not commit secrets, local agent scratch (`.omc/`), or scratch notes into this fork’s product branch.
