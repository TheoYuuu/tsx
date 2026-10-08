# Isolated official Codex authentication fixture

This prototype uses unmodified official `codex-login`, `codex-model-provider`, `codex-http-client` and `codex-keyring-store` from OpenAI Codex commit `36650394c5b38c2990ccf2a3457165ca3e9d9726` (`rust-v0.157.1`). It is only a loopback fake-authentication test. No real account, browser login, default Codex home or machine-managed authentication requirements are accessed. Official upstream license files remain in the fixed source archive; the original unpublished fixture manifest does not assert a project license.

## Invocation

Package/binary: `translatex-codex-auth-prototype`. The tracked `verify.py` stages this crate below the ignored prototype root; its manifest dependencies then resolve to `../../CodexTranslationPrototype/source/codex-36650394c5b38c2990ccf2a3457165ca3e9d9726/codex-rs/...`. It uses the previously verified private Rust 1.95.0 toolchain, a separate cache/target, and `RUSTFLAGS=-D warnings`. It does not modify parent HOME or default Cargo/Rust settings.

For the legacy one-object operations, send one JSON object on stdin, then close stdin. The continuous `login_session` operation below instead keeps stdin open for control messages. Launch with only PATH, LANG and TMPDIR. CoreFoundation adds `__CF_USER_TEXT_ENCODING` before main; that one system value is accepted only with bounded hexadecimal fields and the current UID. Every other externally added variable is rejected before authentication work. For the authenticated fixture operation only, the supervisor constructs CODEX_REFRESH_TOKEN_URL_OVERRIDE from its validated loopback issuer; that worker requires the exact value. It cannot accept a missing or alternate refresh URL. Other workers retain the original whitelist. The helper must be code-signed before Keychain verification. The tracked wrapper has now executed the constructed-identity suite; see the assessment for exact evidence.

Required fields:

- `operation`: `request_device_code`, `complete_device_code_login`, `status`, `logout`, `authenticated_translate`, or the test-only `fixture_corrupt_storage`.
- `identity_home`: existing absolute, canonical directory strictly below this prototype's `runtime/`. Create a fresh unpredictable directory for each test. Symlink aliases are rejected.
- `issuer`: `http://127.0.0.1:<explicit-port>` (optional trailing slash), with no credentials, query, fragment or path.

Optional fields:

- `deadline_ms`: business-worker deadline, default and maximum 6000, clamped to 1…6000.
- `expected_account_id`, `expected_user_id`: in-memory fixture challenge values. The output reports equality booleans, not identities.
- `cancel_after_saved`: default false; a deterministic test hook between successful stage persistence plus worker join, and promotion. It does not interrupt the Keychain write itself.

The internal worker operations and stage/cleanup fields are not accepted through the supervisor's public stdin protocol.

The two device-code operations are **independent fixtures**. `request_device_code` returns a newly requested constructed code; `complete_device_code_login` requests another fresh code and completes that code within one child. These cannot be wired sequentially to a real login UI. The separate `login_session` operation now retains one official DeviceCode in a persistent worker, emits its ready event and accepts cancellation for that same operation. It remains a loopback QA interface, not a real-account product login.

## Continuous login protocol (version 1)

Start with one UTF-8 JSON object followed by LF, at most 32,768 bytes including LF:

```json
{"operation":"login_session","protocol_version":1,"request_id":"87e33d31-e1cb-42fc-8cdc-f1cc567d6fe0","identity_home":"/absolute/owned/runtime/identity","issuer":"http://127.0.0.1:12345","deadline_ms":6000}
```

`request_id` must parse as a standard 36-character UUID. Its exact case-sensitive string is echoed in every event and required for cancellation. Keep stdin open to continue login. The optional existing identity challenge fields remain supported. No real issuer is allowed.

Cancel with one LF-terminated JSON object of at most 4,096 bytes including LF:

```json
{"operation":"cancel","protocol_version":1,"request_id":"87e33d31-e1cb-42fc-8cdc-f1cc567d6fe0"}
```

Normal stdin EOF is cancellation. Malformed JSON, unknown control fields, missing LF on a partial control, wrong version, wrong request ID, unknown operation or an oversized control ends the attempt as `invalid_control` after cleanup. The only accepted control is cancellation; the reader stops after that first control. Host code must not send credentials or arbitrary text through this channel. Initial malformed input fails before workers are started; when no valid request identity exists, the helper emits the legacy fixed error object instead of echoing unvalidated identifiers.

Every normal session output is one bounded JSON line with `event`, `protocol_version:1`, the same `request_id`, and `authorization_ui_disabled:true`:

| Event | Additional fields | Cardinality |
| --- | --- | --- |
| `ready` | `user_code`, `verification_url` | At most once, from the single DeviceCode actually completed |
| `phase` | `phase:"before_promotion"` or `"after_promotion"` | Each at most once on the corresponding successful path |
| `terminal` | `status` and applicable fixed cleanup/status metadata described below | Exactly once if stdout remains writable |

Each output line is less than 32,768 bytes before LF; each worker's cumulative output is at most 32,768 bytes. The ready user code is nonempty and at most 128 UTF-8 bytes; its verification URL is at most 512 bytes. Codes stay in host memory and are removed from reports. No token, raw authentication error or account/user identity is emitted.

Terminal statuses add `timed_out` (business deadline), `invalid_control`, `output_closed`, and `process_isolation_failed` to the fixed statuses below. Explicit cancel and normal EOF yield `cancelled` when cleanup succeeds. Cleanup uncertainty takes precedence as `cleanup_required`. `cancelled` means this attempt did not leave a newly written account; it does not delete an account which already existed before the attempt.

Before creating any worker, the supervisor reuses an existing private process group when `getpgrp()` equals its own PID; otherwise it calls `setsid()` to create a private group/session. Foundation.Process may already create the private group while retaining the host session, and a group leader cannot call `setsid()` again. Failure returns `process_isolation_failed`. Workers inherit that private group. The native host can therefore terminate its exact owned group after an independent grace period, then report `cleanup_required`; killing a group alone does not prove Keychain cleanup.

The stdin control reader is a detached standard thread, not a Tokio blocking task, so success does not wait for host EOF. Session stdout is nonblocking. A failed output cannot stall child cleanup. A host that cannot receive a complete terminal must consider the result uncertain and inspect the exact recovery metadata after terminating/waiting for its owned process group.

A control mutex orders cancellation against successful terminal delivery. Cancellation received before that commit gate wins: the current worker is killed and joined before stage cleanup and rollback of any target this attempt may have written. This includes cancellation while the promotion worker is saving or after that worker has saved successfully. A late control after successful terminal delivery does not rewrite success as cancelled. The host must wait for terminal, stdout EOF and successful helper exit; sending cancel alone is not an acknowledgement.

The journal remains present until successful terminal delivery. If a successful-terminal write fails or is partial, the helper rolls back the attempted target, retains recovery metadata if cleanup fails, and exits with code 4 without attempting another terminal. If final journal removal fails after successful delivery, the helper retains the journal and exits with code 3; a host must not report a successful operation from the terminal frame alone. Missing terminal, nonzero exit, or cleanup failure requires reconciliation from that non-sensitive record. This is not automatic crash recovery.

Two optional QA windows, `fixture_pause_before_promotion_ms` and `fixture_pause_after_promotion_ms`, accept 0…1000 ms. They pause after the corresponding `phase` event while still processing cancellation/deadline. `before_promotion` means the official stage save completed and its worker was joined; `after_promotion` means the official target save/status completed and its worker was joined. These deterministic windows do not intercept SecItem calls internally. The default is zero. The earlier `cancel_after_saved` stage hook remains compatible.

## Network and storage boundaries

Official ServerOptions use `translatex-fixture-client`, `open_browser=false`, strict `Keyring` and `Direct`. NetworkPolicyController publishes a managed policy narrowed to three exact URLs at the supplied loopback issuer:

1. `/api/accounts/deviceauth/usercode`
2. `/api/accounts/deviceauth/token`
3. `/oauth/token`

The managed policy enters the official route-aware client path and checks redirects before following them. These login/status operations do not invoke refresh, revoke, model or browser-login APIs. The authenticated operation below separately narrows its official managed policy to `/oauth/token` and `/v1/responses`. Local logout deletes only the derived exact item and the official auth fallback file within the explicitly owned home; it does not revoke server tokens.

The official service is `Codex Auth`; its Direct account is `cli|` plus the first 16 hexadecimal digits of SHA-256 of the canonical home string. The corruption fixture reproduces this derivation only for its initial empty random home, and writes the fixed string `fixture-invalid-auth-json`. It never enumerates existing items. A later official status must distinguish this storage decoding failure from a missing identity.

`SecKeychainSetUserInteractionAllowed(false)` affects only each probe process. A denied Keychain operation reports a fixed failure and does not request user interaction. The helper neither changes system security settings nor edits Keychain configuration. AuthManager is bound to the explicit home and the same strict backend. Only its cached official authentication adapter is inspected; no token refresh is attempted. No raw error, token, account ID, user ID or authentication headers leave the worker. A successful status reports only header presence and challenge equality.

## Authenticated single-request fixture

`authenticated_translate` is another one-object operation, protected by the same target-home lock. It requires `text` (nonblank, at most 8192 UTF-8 bytes) and accepts `fixture_policy_case`, `fixture_policy_workspace`, `fixture_refresh`, and `fixture_replacement_home`. The last path must be a different canonical sibling created and registered by this test run. These are QA hooks; no arbitrary external provider, policy file or existing account is accepted.

`auth_policy.rs` feeds in-memory system/MDM/cloud fixtures through the pinned official requirements loader. Its custom read-only filesystem rejects unregistered reads and all mutations, and both MDM overrides are explicit so the host's real preferences are never consulted. Official AuthConfig validation and load enforce login methods and allowed workspaces. An unavailable/malformed or unsupported policy stops the operation. Official cloud requirements deliberately cannot replace the local authentication constraints; this is an upstream rule, not a TranslateX override.

Before a model call, `account_request.rs` anchors the original official adapter, checks persisted versus parsed ID-token account fields, and decides whether a refresh is due. It follows this pinned source's five-minute JWT expiry window and eight-day opaque-token fallback; the fallback's timestamp must come from the same strict-Keyring token snapshot. Required or fixture-forced refresh invokes the public official Result-returning refresh method once. Failure, stale refreshed access token or conflicting identity stops before model transport. This consistency check does not verify JWT signatures.

A wrapper resolves headers only through the official adapter's synchronous cached-header path, rejecting a missing Authorization header. It never calls the upstream asynchronous auth path that can return an old token after a failed proactive refresh. Tokens and raw headers remain inside Rust. This assumes the supervisor's exact-home lock and one worker/request; production still needs its account-generation/lifecycle protection.

The model engine is the same frozen `CodexTranslationProbe/src/translation.rs`: one POST, no tools, no retry or redirect, complete validated text only. For this loopback exception the raw no-proxy/no-retry transport is enclosed in an official account-bound network permit for header resolution, request and stream. The preceding explicit refresh has its own official route-aware network permit. Account changes may invalidate policy before the header adapter runs; a blocked model call does not prove both guards executed. Product traffic must use official outbound/workspace routing and trusted real policy sources.

An `ok` result contains only the translation plus safe metadata. The harness compares the constructed translation in memory and omits it from evidence; failure contains no text. `auth_checks` contains booleans and refresh-call counts, never identities. Actual OAuth grants and model POST counts come independently from the server. `explicit_refresh_calls` counts calls to the explicit Result-returning API, including a proactively required refresh; `explicit_refresh_requested` records only the fixture flag.

## Staging and bounded cleanup

The supervisor acquires an exclusive nonblocking kernel lock on a regular `O_NOFOLLOW` file in the target home. Login requires an initially signed-out target. A random `runtime/stage-<UUID>` is created, and a mode-0600 target `.pending-auth-cleanup.json` is synced before login starts. The journal contains only stage/target paths and `target_initially_signed_out=true`; continuous sessions also include their non-secret request ID.

A dedicated child performs the official device-code flow and stage save. The supervisor joins that child before a separate child reads the stage and saves the target with official storage APIs. Tokens never transit supervisor IPC. A business deadline kills and waits for the active child before cleanup. Cleanup removes the stage and any target this attempt may have written. A target already signed in at the initial check is rejected without deletion. These fixtures exclusively own their random homes; rollback against an unrelated writer that ignores the lock is not validated. Exact stage-home directories remain available for independent signed-out checks after cleanup.

Each kill/reap has a separate 2-second budget. Cleanup gets 2 seconds, plus up to 2 seconds for its own kill/reap. The continuous session may clean stage and target in separate workers, so its complete budget can reach 16 seconds: business 6 + active-worker termination 2 + stage cleanup/termination 4 + target cleanup/termination 4. Harness invocations must allow at least 18 seconds; 20 seconds is recommended. The 6-second business deadline is not a total wall-clock promise. Filesystem operations and process scheduling are not claimed to have a hard real-time bound.

A process which cannot be joined, a failed cleanup, or a journal-removal failure returns `cleanup_required`, preserves exact paths/journal, and must not have those directories removed by the harness. The harness should terminate and wait for the whole invocation process group before recovering registered random homes. Killing the supervisor alone can orphan a child: this prototype does not claim parent-death detection, automatic crash-journal recovery. The continuous protocol covers normal EOF and explicit cancellation, not forced supervisor death or power loss. Kernel locks release automatically on process death, but that is not proof all child work has stopped.

## Fixed outputs

All regular outputs include `status` and `authorization_ui_disabled`. Supervisor-run workers additionally report `worker_reaped` when known.

- Device request: `device_code_ready` with `user_code` and `verification_url`, or `device_code_failed`.
- Complete: `signed_in`, `cancelled`, `login_failed`, `device_code_failed`, `storage_unavailable`, `already_signed_in`, `target_changed`, `staging_failed`, or `cleanup_required`.
- Status: `signed_out`, `signed_in`, `storage_unavailable`, `invalid_stored_auth`, or `unexpected_auth_method`.
- Local logout: `signed_out` or `storage_unavailable`.
- Corruption hook: `fixture_corrupted`, `target_not_empty`, or `storage_unavailable`.
- Protocol/lifecycle failures: `invalid_input`, `invalid_operation`, `environment_rejected`, `identity_busy`, `worker_failed`, or `ui_suppression_failed`.

Completed staged attempts report `stage_home`, `stage_saved_confirmed`, `stage_cleanup_ok`; known target state is `target_auth_present`. `signed_in` may include `auth_header_present`, `account_matches`, `user_matches` (null if no challenge supplied). `cleanup_required` may include `pending_cleanup_homes` and `cleanup_journal`. Device codes and fixture challenge values must be removed from persisted harness reports. Only the fixed statuses and metadata are intended for evidence.

## Remaining product gates

Real authentication has not been exercised. Device-code beta requires user/workspace enablement. This fixture does not load actual MDM/requirements; production AuthConfig must compose and honor managed authentication requirements. Same-code events and normal cancellation are implemented in this QA protocol and require the separately recorded signed-helper fixture/native-host results. Real product UI, parent death/crash recovery, real-account refresh and revocation, packaged-helper signing and update compatibility remain separate product work. Successful fake authentication proves neither real-account eligibility nor model completion.


The native QA host consumes stdout and stderr through separate nonblocking DispatchSourceRead sources on the main queue, at most four 4096-byte reads per callback. Source cancellation handlers own closing the read descriptors; no queued callback may read a prematurely closed/reused descriptor. Earlier FileHandle.AsyncBytes fixtures intermittently delivered ready only after the fake helper timed out. The quiet-stderr/delayed-ready regression checks the actual cancelled terminal, not merely a successfully reaped host. The result still waits for protocol completion, EOF and process exit; queued descriptor-close callbacks are not represented as already executed.
