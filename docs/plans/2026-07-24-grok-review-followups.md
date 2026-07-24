# Grok Review Follow-ups Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Close the Important gaps from the Grok adversarial review of `providers` (subagent None hardening, chat_state credential clear, TUI readiness defense-in-depth, docs/PR hygiene) without changing the fork branch model.

**Architecture:** Keep sampler/reconstruct as the wire last line of defense. Align every credential *read* path (subagent inherit, chat_state after switch) with the same `AuthScheme::None ⇒ api_key = None` rule used in `reconstruct_full_config`. Push readiness hard-block into the dispatch layer so slash/picker are not the only gate. Close PR #1 so `main` cannot be polluted.

**Tech Stack:** Rust workspace (`xai-grok-shell`, `xai-grok-pager`), existing ACP/session tests, GitHub `gh` for PR hygiene, CI on `providers` only.

**Branch:** Work on `providers` (default product line). Do **not** commit to `main`.

**Review source:** Grok read-only review of `origin/main`…`providers` @ `3705974` (session finalize).

---

### Task 0: Close PR #1 (fork hygiene)

**Files:**
- None (GitHub only)
- Docs touch optional: `FORK.md` one-line note under CI/PR if missing

**Step 1: Confirm PR state**

Run:
```bash
gh pr view 1 --repo ImL1s/grok-build --json number,state,baseRefName,headRefName,title,url
```
Expected: `state=OPEN`, `baseRefName=main`, `headRefName=feat/multi-provider-local-llm`.

**Step 2: Close with explicit reason**

Run:
```bash
gh api repos/ImL1s/grok-build/issues/1/comments -f body="$(cat <<'EOF'
Closing: product line lives on default branch `providers`. Merging this PR into `main` would violate the fork contract (`main` = pristine upstream mirror). See FORK.md.
EOF
)"

gh api repos/ImL1s/grok-build/pulls/1 -X PATCH -f state=closed
```

**Step 3: Verify**

Run:
```bash
gh pr view 1 --repo ImL1s/grok-build --json state,closedAt
```
Expected: `state=CLOSED`.

**Step 4: Commit (only if FORK.md edited)**

```bash
# skip commit if no file changes
git status -sb
```

---

### Task 1: Harden subagent `read_parent_sampling_config` for `AuthScheme::None`

**Files:**
- Modify: `crates/codegen/xai-grok-shell/src/agent/subagent/mod.rs` (~953–980, `read_parent_sampling_config`)
- Test: `crates/codegen/xai-grok-shell/src/agent/subagent/tests/rest.rs` (near existing `read_parent_sampling_config_*` tests ~2694+)

**Context — current bug shape:**

```rust
let auth_scheme = crate::agent::config::try_resolve_model_credentials(&cfg.model, None)
    .map(|r| r.auth_scheme)
    .unwrap_or_default(); // ← silent Bearer on lookup miss
let inherited = xai_grok_sampler::SamplerConfig {
    api_key: creds.api_key, // ← not stripped when scheme is None
    // ...
    auth_scheme,
};
```

**Step 1: Write the failing test**

In `rest.rs`, add a test that:
1. Builds a `SubagentSpawnContext` whose `parent_chat_state` sampling model is a catalog entry with `AuthScheme::None` (or inject credentials resolution via the same helpers other subagent tests use).
2. Leaves a **stale** JWT-looking `api_key` in chat_state credentials (e.g. `"stale-session-jwt"`).
3. Calls `read_parent_sampling_config(&ctx).await`.
4. Asserts `config.auth_scheme == AuthScheme::None` and `config.api_key.is_none()`.

Also add a second test (or same test with a second case): when the model id is **missing from catalog**, do **not** silently inherit Bearer + stale key — either fail-closed to `AuthScheme::None` when parent baseline/`ctx.sampling_config` already says None, or strip key when parent config scheme is None. Prefer: if resolved scheme is None **OR** parent `ctx.sampling_config.auth_scheme == None`, force `api_key = None` and `auth_scheme = None`.

Sketch (adapt to existing test helpers in this file):

```rust
#[tokio::test]
async fn read_parent_sampling_config_strips_api_key_for_auth_scheme_none() {
    // Arrange: parent chat_state model = local none; credentials.api_key = Some("stale-jwt")
    let (config, _model_id) = read_parent_sampling_config(&ctx).await;
    assert_eq!(config.auth_scheme, xai_grok_sampler::AuthScheme::None);
    assert!(
        config.api_key.is_none(),
        "stale chat_state JWT must not inherit onto AuthScheme::None subagent"
    );
}
```

**Step 2: Run test to verify it fails**

Run:
```bash
cargo test --manifest-path crates/codegen/xai-grok-shell/Cargo.toml --lib \
  read_parent_sampling_config_strips_api_key_for_auth_scheme_none -- --nocapture
```
Expected: FAIL (api_key still Some, or compile until wired).

**Step 3: Minimal implementation**

In `read_parent_sampling_config`, after resolving `auth_scheme` / before building `inherited`:

```rust
let mut auth_scheme = crate::agent::config::try_resolve_model_credentials(&cfg.model, None)
    .map(|r| r.auth_scheme)
    .unwrap_or(ctx.sampling_config.auth_scheme);
// Prefer explicit None from parent spawn baseline over silent Bearer default.
if ctx.sampling_config.auth_scheme == xai_grok_sampler::AuthScheme::None {
    auth_scheme = xai_grok_sampler::AuthScheme::None;
}
let api_key = if auth_scheme == xai_grok_sampler::AuthScheme::None {
    None
} else {
    creds.api_key
};
```

Use `api_key` / corrected `auth_scheme` in the `SamplerConfig { ... }` literal. Keep the fallback branch that uses `ctx.sampling_config` unchanged except applying the same None strip if that config's scheme is None.

**Step 4: Run tests to verify they pass**

Run:
```bash
cargo test --manifest-path crates/codegen/xai-grok-shell/Cargo.toml --lib \
  read_parent_sampling_config_ -- --nocapture
```
Expected: all matching tests PASS (including new ones).

**Step 5: Commit**

```bash
git add crates/codegen/xai-grok-shell/src/agent/subagent/mod.rs \
  crates/codegen/xai-grok-shell/src/agent/subagent/tests/rest.rs
git commit -m "$(cat <<'EOF'
fix(shell): strip stale api_key for AuthScheme::None subagents

EOF
)"
```

---

### Task 2: Clear chat_state credentials when switching to `AuthScheme::None`

**Files:**
- Modify: `crates/codegen/xai-grok-shell/src/session/acp_session_impl/model_switch.rs` (~61–76)
- Optionally reinforce: `crates/codegen/xai-grok-shell/src/session/acp_session_impl/sampler_turn.rs` (`reconstruct_full_config` already strips for the wire; do **not** duplicate complex logic — only ensure switch path writes `None`)
- Test: `crates/codegen/xai-grok-shell/src/session/acp_session_tests/auth_error_no_retry_tests.rs` (extend near None reconstruct tests ~986+)

**Step 1: Write the failing test**

Add a test that:
1. Session starts with session/Bearer credentials in chat_state.
2. Calls `handle_set_session_model` (or the public command path the other tests use) with a sampling config whose `auth_scheme == AuthScheme::None` and `api_key == None`.
3. Reads chat_state credentials afterward.
4. Asserts `api_key.is_none()`.

If an existing helper already switches models in these tests, reuse it.

**Step 2: Run test to verify it fails**

Run:
```bash
cargo test --manifest-path crates/codegen/xai-grok-shell/Cargo.toml --lib \
  handle_set_session_model_clears_credentials_for_none -- --nocapture
```
Expected: FAIL if switch currently preserves stale key when `sampling_config.api_key` is somehow still set, **or** write the test to force the bug: pass `auth_scheme: None` with a non-None `api_key` in the sampling config and assert credentials end up cleared (defense-in-depth). Preferred assertion: even if caller passes a stale key alongside `AuthScheme::None`, chat_state stores `None`.

**Step 3: Minimal implementation**

In `handle_set_session_model`:

```rust
let api_key = if sampling_config.auth_scheme == xai_grok_sampler::AuthScheme::None {
    None
} else {
    sampling_config.api_key.clone()
};
self.chat_state_handle
    .update_credentials(xai_chat_state::Credentials {
        api_key,
        // ... existing fields ...
    });
```

**Step 4: Run related tests**

```bash
cargo test --manifest-path crates/codegen/xai-grok-shell/Cargo.toml --lib \
  none_auth_scheme -- --nocapture
cargo test --manifest-path crates/codegen/xai-grok-shell/Cargo.toml --lib \
  reconstruct_full_config_no_bearer_resolver_for_none -- --nocapture
cargo test --manifest-path crates/codegen/xai-grok-shell/Cargo.toml --lib \
  handle_set_session_model_clears_credentials_for_none -- --nocapture
```
Expected: PASS.

**Step 5: Commit**

```bash
git add crates/codegen/xai-grok-shell/src/session/acp_session_impl/model_switch.rs \
  crates/codegen/xai-grok-shell/src/session/acp_session_tests/auth_error_no_retry_tests.rs
git commit -m "$(cat <<'EOF'
fix(session): clear chat_state api_key when switching to AuthScheme::None

EOF
)"
```

---

### Task 3: Hard-block unready models in `SetDefaultModel` / `SwitchModel` dispatch

**Files:**
- Modify: `crates/codegen/xai-grok-pager/src/app/dispatch/settings/setters.rs` (`set_default_model`, `set_default_model_confirmed`)
- Modify: `crates/codegen/xai-grok-pager/src/app/dispatch/router.rs` (`Action::SwitchModel` arm ~853)
- Reuse helper: `crates/codegen/xai-grok-pager/src/slash/commands/model.rs` (`model_not_ready_reason` — make `pub(crate)` if not already visible)
- Test: `crates/codegen/xai-grok-pager/src/slash/commands/model.rs` unit tests **and/or** dispatch tests if a settings/setters test module exists; otherwise add focused tests next to existing model readiness tests and a small dispatch unit test module if one already covers setters.

**Step 1: Write failing tests**

1. `set_default_model` with meta `ready: false` → returns toast/error effect (or empty + toast), **does not** persist default, **does not** emit `Effect::SwitchModel`.
2. Direct `Action::SwitchModel` with unready model → blocked with same reason string as `/model`.
3. After auth-class confirm path (`set_default_model_confirmed` / lifecycle answered handler): still re-check readiness before switching.

Reuse `model_with_meta` / readiness helpers from `model.rs` tests.

**Step 2: Run tests — expect FAIL**

```bash
cargo test --manifest-path crates/codegen/xai-grok-pager/Cargo.toml --lib \
  set_default_model_hard_blocks_unready -- --nocapture
cargo test --manifest-path crates/codegen/xai-grok-pager/Cargo.toml --lib \
  switch_model_hard_blocks_unready -- --nocapture
```

**Step 3: Minimal implementation**

- At the top of `set_default_model` (after catalog contains check): if `model_not_ready_reason(&agent.session.models, &new_id)` is `Some(reason)`, push the same user-visible error path `/model` uses (toast / scrollback message — match existing patterns in setters for validation failures) and return `vec![]` (or a single toast effect).
- Same check at start of `set_default_model_confirmed`.
- In `router.rs` `Action::SwitchModel`, after resolving agent models, before auth-class confirm / `Effect::SwitchModel`: if unready, toast + return `vec![]`.
- Ensure `AuthClassSwitchAnswered` → confirmed switch also goes through the confirmed helpers that re-check.

**Step 4: Run pager model + new tests**

```bash
cargo test --manifest-path crates/codegen/xai-grok-pager/Cargo.toml --lib \
  slash::commands::model:: -- --nocapture
cargo test --manifest-path crates/codegen/xai-grok-pager/Cargo.toml --lib \
  set_default_model_hard_blocks_unready -- --nocapture
cargo test --manifest-path crates/codegen/xai-grok-pager/Cargo.toml --lib \
  switch_model_hard_blocks_unready -- --nocapture
```
Expected: PASS.

**Step 5: Commit**

```bash
git add crates/codegen/xai-grok-pager/src/app/dispatch/settings/setters.rs \
  crates/codegen/xai-grok-pager/src/app/dispatch/router.rs \
  crates/codegen/xai-grok-pager/src/slash/commands/model.rs
# plus any new test files
git commit -m "$(cat <<'EOF'
fix(tui): hard-block unready models in SwitchModel and SetDefaultModel

EOF
)"
```

---

### Task 4: Fix docs badge `local` → `none`

**Files:**
- Modify: `crates/codegen/xai-grok-pager/docs/user-guide/11-custom-models.md` (~45)
- Optionally: `FORK.md` TUI section if it mentions badge names

**Step 1: Edit the sentence**

Change:
```markdown
Each row shows a short provider hint and a readiness badge (`ready`, `missing`, or `local`).
```
To:
```markdown
Each row shows a short provider hint and a readiness badge (`ready`, `missing`, or `none`).
```

Note: `providerHint` may still be `"local"` — that is separate from the badge. Do not confuse them in the docs.

**Step 2: Grep for other stale mentions**

```bash
rg -n 'badge.*local|`local`' crates/codegen/xai-grok-pager/docs/user-guide/11-custom-models.md FORK.md
```
Fix any badge wording only.

**Step 3: Commit**

```bash
git add crates/codegen/xai-grok-pager/docs/user-guide/11-custom-models.md
git commit -m "$(cat <<'EOF'
docs: align model picker badge name with none auth class

EOF
)"
```

---

### Task 5: Extend CI filters for new coverage

**Files:**
- Modify: `.github/workflows/ci.yml` (Tests job)
- Modify: `FORK.md` CI bullet if listing filters

**Step 1: Add filters**

Under Shell / Pager test steps, append:

```bash
cargo test --manifest-path crates/codegen/xai-grok-shell/Cargo.toml --lib \
  read_parent_sampling_config_strips_api_key_for_auth_scheme_none -- --nocapture
cargo test --manifest-path crates/codegen/xai-grok-shell/Cargo.toml --lib \
  handle_set_session_model_clears_credentials_for_none -- --nocapture
cargo test --manifest-path crates/codegen/xai-grok-pager/Cargo.toml --lib \
  set_default_model_hard_blocks_unready -- --nocapture
cargo test --manifest-path crates/codegen/xai-grok-pager/Cargo.toml --lib \
  switch_model_hard_blocks_unready -- --nocapture
```

(Use the exact final test names from Tasks 1–3.)

**Step 2: Commit + push**

```bash
git add .github/workflows/ci.yml FORK.md
git commit -m "$(cat <<'EOF'
ci: cover subagent none strip and readiness hard-blocks

EOF
)"
git push origin providers
```

**Step 3: Watch CI**

```bash
gh run list --repo ImL1s/grok-build --branch providers --limit 1
# then gh run watch <id> --exit-status
```
Expected: Format / Clippy / Tests all success.

---

### Out of scope (YAGNI for this plan)

- Session-only `(s)` key for picker
- Full-workspace clippy / full `cargo test`
- Upstream PR to `xai-org/grok-build`
- Changing `local.none` ACP advertise mid-session
- Auto-inferring `auth_scheme=none` for loopback URLs

---

### Done criteria

- [ ] PR #1 closed (not mergeable into `main`)
- [ ] Subagent inherit strips stale key under None + tests green
- [ ] Model switch clears chat_state api_key under None + tests green
- [ ] Dispatch hard-blocks unready for SwitchModel + SetDefaultModel + tests green
- [ ] Docs badge says `none`
- [ ] CI on `providers` green including new filters
