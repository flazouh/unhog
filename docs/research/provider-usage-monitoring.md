# Provider usage monitoring

Checked against `robinebers/openusage` on 24 July 2026.

## Product boundary

Unhog reports provider usage; it does not inspect work-in-progress, render
prompts or transcripts, display tool calls, or launch provider commands.

The Usage section currently covers:

- Claude session, weekly, and Sonnet limits
- Codex session and weekly limits
- provider-reported reset times and balances
- measured local token/turn totals for today, seven days, and 30 days

## OpenUsage reference

[OpenUsage](https://github.com/robinebers/openusage) is a native Swift macOS
menu-bar app under the MIT License. Its provider architecture normalizes each
provider into bounded progress metrics, unbounded values, reset times, and
local history.

The relevant provider behavior is:

- Claude credentials: the `Claude Code-credentials` macOS Keychain item, then
  `~/.claude/.credentials.json` (or `CLAUDE_CONFIG_DIR`).
- Claude limits: `GET https://api.anthropic.com/api/oauth/usage`.
- Claude local usage: aggregate token counts from JSONL files under
  `~/.claude/projects/`.
- Codex credentials: `$CODEX_HOME/auth.json`, with `~/.codex/auth.json` as the
  default.
- Codex limits: `GET https://chatgpt.com/backend-api/wham/usage`.
- Codex local usage: aggregate token counts from JSONL files under
  `~/.codex/sessions/` and `archived_sessions/`.

OpenUsage 0.7.4 is installed directly at `/Applications/OpenUsage.app` on this
Mac (it is not Homebrew-managed). It is a signed, unsandboxed native Swift
menu-bar app with bundle ID `com.robinebers.openusage`. Its loopback API is
available at `http://127.0.0.1:6736/v1/usage`.

Unhog does not depend on that API: other Unhog users may not have OpenUsage
installed, and a browser-accessible loopback service adds a separate privacy
boundary. The implementation is native and self-contained instead.

## Unhog implementation choices

- Existing CLI credentials are read only; Unhog never stores a provider token.
- Local JSONL files are streamed in 256 KiB chunks so large histories do not
  create a memory spike.
- Only aggregate counts leave the scanner. Prompt and response content is
  never retained in the model or passed to the UI.
- Provider requests go directly to Anthropic or OpenAI. Local token history
  stays on the Mac.
- Missing authentication degrades to local-only totals. A temporary provider
  failure preserves the last successful live limits and marks them stale.
- The scanner refreshes every five minutes while the Usage section is visible,
  with an explicit manual refresh control. This matches OpenUsage and avoids
  unnecessarily rate-limiting Anthropic's usage endpoint.

See `THIRD_PARTY_NOTICES.md` for the OpenUsage license notice.
