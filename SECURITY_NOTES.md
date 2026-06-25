# SECURITY_NOTES — OpenWebUI-iOS

Hardening ported from the Odysseus-iOS red-team review (2026-06-24, branch `security-url-hardening`,
rollback tag `pre-security-fix-snapshot`). These forks share the same `ServerConfig`/`OWClient`
patterns, so the same vulnerabilities applied here.

| Issue | Fix |
|-------|-----|
| **Cleartext credential leak** — `OWConfig.normalize` used `hasPrefix("10.")/"192.168."` to decide http vs https, so a public name like `10.evil.com` was downgraded to plain HTTP, leaking the Bearer token. | `isLocalHost` now parses real IPv4/IPv6 private ranges (127/8, 10/8, 172.16/12, 169.254/16, 192.168/16, ::1, fc00::/7). |
| **SSRF / scheme smuggling** — any scheme (`file://`, `data:`) accepted. | `normalize` rejects non-http(s) via an allowlist. |
| **Path/param smuggling** — server-supplied chat/note/file ids interpolated raw into authenticated URLs. | `OpenWebUIClient.encPath` applied at every id call site (OWChatActions, OWChatPersistence, OWNotes, OWFiles). |
| **ATS blanket cleartext** — `NSAllowsArbitraryLoads: true`. | Dropped; kept `NSAllowsLocalNetworking` (public hosts use HTTPS). |

Verified: the `OpenWebUIKit` package builds clean (`swift build`). Full-app build pending the
SPM/whisper DNS resolution (known environment blocker — unrelated to these changes).
Team id was already handled safely via `${DEVELOPMENT_TEAM}` env (setup.sh) — no S1 issue here.

Deferred (same rationale as Odysseus): per-server cookie/token isolation, error-string redaction.
