# Sign in with Ambitious — Prompter integration

Prompter is the first internal client of "Sign in with Ambitious" (Ambitious
Social as an OAuth 2.1/OIDC identity provider). This doc is the
Prompter-specific plan; the authoritative server-side contract lives in the
ambitious monorepo at `apps/web/SIGN_IN_WITH_AMBITIOUS.md` (activation
checklist, security guarantees) and
`apps/web/SIGN_IN_WITH_AMBITIOUS_CLIENT_GUIDE.md` (generic client guide).

> **Status: live in production.** The hosted OAuth server, ES256 signer,
> identity-only claims hook, consent UI, and manually registered Prompter
> client are active. Dynamic registration remains disabled.

## What sign-in gives Prompter (and what it can't)

A signed-in user proves, cryptographically, **who they are on Ambitious**:

- `sub` — stable Ambitious user ID. Key any local state by `(iss, sub)`.
- `email` + `email_verified` — current email (with `email` scope).

That is all, by enforced server-side design. **These tokens cannot post to
Ambitious, read the feed, send DMs, or touch any Ambitious product API** —
every product resource rejects them (401/403). A future "share your streak
to Ambitious" feature would require a deliberate new server-side API on the
Ambitious side; do not attempt it with these tokens.

Product decision (2026-07-18): a free Ambitious account is **required** for
Prompter dictation and Prompt Mode. This supersedes the earlier optional-sign-in
plan and the README's former “no account” promise. This is a simple growth
funnel, not DRM: the repository stays public and source-available, with no
obfuscation or attempt to stop a fork from changing the gate.

## Client model

| Setting | Value |
| --- | --- |
| Client type | **Public** (`token_endpoint_auth_method=none`) — Prompter has no backend; there is no client secret anywhere |
| Client ID | `6f2eb6a1-e2b8-470f-a35d-0df05fbdd717` |
| Flow | Authorization code + PKCE **S256** (never `plain`) |
| Scopes | `openid email` |
| Redirect URI | `https://www.ambitious.social/oauth/prompter/callback` |
| Issuer | `https://ehplhuzlsxrhhpkqxeyc.supabase.co/auth/v1` |
| Discovery | `<issuer>/.well-known/openid-configuration` |
| JWKS | `<issuer>/.well-known/jwks.json` |

### Why an HTTPS callback instead of a release `prompter://` URL scheme

Any Mac app can claim the same custom URL scheme and intercept the redirect.
Combined with the hosted server's current tolerance of the weak `plain` PKCE
method (documented upstream gap), a scheme hijack could let a malicious app
observe a stolen authorization code. Prompter instead uses the macOS 26
`ASWebAuthenticationSession.Callback.https(host:path:)` matcher: the exact
HTTPS navigation is returned only to the active authentication session, while
PKCE S256 binds the code to Prompter's in-memory verifier. This is an
authentication-session callback, not a universal-link handoff, so Prompter
does not claim the Ambitious website through Associated Domains. Ambitious
client policy still requires an exact HTTPS redirect URI.

## One-time platform setup (owner + web repo)

1. **Callback page**: static route at
   `/oauth/prompter/callback` on www.ambitious.social showing "You're
   signed in — return to Prompter." (ASWebAuthenticationSession intercepts
   the redirect before rendering in the normal case; the page is the
   fallback.) Middleware must allow it unauthenticated.
   The fallback must never read, render, persist, or deliberately log query
   parameters; OAuth codes and state belong only to the authentication session.
2. **No Associated Domains entitlement**: HTTPS callback matching is performed
   by `ASWebAuthenticationSession`, not by a universal-link launch. Keep both
   release and local entitlements minimal; `webcredentials` is for shared
   passwords and is not this callback mechanism.
3. **Registration**: the Prompter client is manually registered exactly per
   the table above. Its public `client_id` is embedded in the release binary;
   no client secret exists.

## Implemented client design (this repo)

`Sources/Prompter/Auth/` owns the protocol, Keychain storage, and pure gate;
onboarding and Settings provide the account UI.

1. **Discovery**: fetch the OIDC discovery document for each sign-in or due
   refresh and validate the exact issuer plus secure endpoint URLs.
2. **PKCE**: 32 random bytes → base64url verifier; challenge =
   base64url(SHA256(verifier)) via CryptoKit. Fresh `state` and `nonce`
   per attempt.
3. **Authorize** with `ASWebAuthenticationSession`:

```swift
import AuthenticationServices
import CryptoKit

let session = ASWebAuthenticationSession(
    url: authorizeURL, // built from discovery + client_id, redirect_uri,
                       // scope, state, nonce, code_challenge(_method=S256)
    callback: .https(host: "www.ambitious.social",
                     path: "/oauth/prompter/callback")
) { callbackURL, error in
    // 1. verify returned state == saved state (constant-time)
    // 2. extract code; POST form to token endpoint with
    //    grant_type=authorization_code, client_id, redirect_uri,
    //    code, code_verifier   (no client secret — public client)
}
session.presentationContextProvider = provider
session.start()
```

4. **Validate the ID token before trusting it** with the small CryptoKit JOSE
   validator in `AmbitiousAuthCore.swift`:
   - signature against current JWKS by `kid` (expect ES256; reject
     `alg=none`/HS*),
   - `iss` exactly the issuer above, `aud` contains our client_id,
   - `exp`/time claims with small skew, `nonce` matches this attempt.
5. **UserInfo**: GET with the access token; use it only for identity.
6. **Storage**: tokens + identity go in the **Keychain**
   (`kSecClassGenericPassword`, service `com.drew.prompter.ambitious`) —
   not `config.json`. Even the display email and subject stay in Keychain; this
   implementation adds no config fields.
7. **Settings UI**: “Ambitious account” shows signed-in identity, an explicit
   account check, and sign-out. It reminds the user that grants can also be
   removed at Ambitious → Settings → Connected Apps.
8. **Gate**: GUI Dictation, GUI Prompt Mode, `--transcribe`, and
   `--transcribe-openrouter` require cached identity. `--test-*` diagnostics
   and render tools remain ungated developer tooling.
9. **Never log** authorization codes, tokens, or full callback URLs to
   `prompter.log`.

## Product and lifecycle decisions

1. **Onboarding order:** Ambitious sign-in is the first setup step, before the
   welcome tour and before macOS asks for Microphone or Accessibility. Returning
   users who have already completed setup return straight to Prompter after
   signing in.
2. **Offline and refresh:** cached Keychain identity enables Prompter
   indefinitely, even if access tokens expire or every account check fails.
   Refresh runs at launch only when the previous successful refresh is at least
   24 hours old; a six-hour timer checks that same threshold. “Check account”
   in Settings forces the next refresh immediately. There are no auth network
   calls in the dictation hot path.
3. **Revocation:** only an HTTP 400 token-endpoint refresh response whose OAuth
   `error` is exactly `invalid_grant` or Supabase's post-revocation
   `refresh_token_not_found` is definitive revocation. Network errors,
   timeouts, malformed success responses, validation failures, 5xx responses,
   and every other OAuth/HTTP error are transient and preserve offline access. Revocation
   or user-requested sign-out waits for any recording/transcription/paste to
   finish before deleting Keychain state and re-gating.
4. **Headless behavior:** the two real transcription commands honor the cached
   identity gate. Diagnostics beginning `--test-` remain ungated so a developer
   can inspect a broken build or auth environment.

## Local Prompter client for the canonical lab

The macOS 26 SDK supports `ASWebAuthenticationSession.Callback.https(host:path:)`
and a custom-scheme callback, but Prompter does not provide a loopback HTTP
listener. Prompter therefore uses
`prompter-lab://oauth/callback` only inside `#if DEBUG`. Build a DEBUG app whose
Info.plist registers that scheme:

```bash
./scripts/build-app.sh --auth-lab
PROMPTER_AMBITIOUS_ISSUER=http://127.0.0.1:54321/auth/v1 \
PROMPTER_AMBITIOUS_CLIENT_ID='<local-public-client-id>' \
PROMPTER_AMBITIOUS_REDIRECT_URI=prompter-lab://oauth/callback \
  ./build/Prompter.app/Contents/MacOS/Prompter
```

Register that exact redirect on the disposable local public client. Release
compilation removes the environment override and custom callback code, and the
ordinary release Info.plist contains no custom scheme. The lab build uses the
separate bundle identifier `com.drew.prompter.auth-lab` and Keychain service
`com.drew.prompter.ambitious.auth-lab`, so LaunchServices callback routing and
test credentials cannot collide with an installed release. It opens the normal
system browser to make the server consent UI observable; macOS returns the
custom-scheme callback to the DEBUG-only app delegate.

For a deterministic refresh/revocation acceptance check, the DEBUG binary also
provides `--test-ambitious-refresh`. It performs one immediate account refresh
and prints only `SIGNED_IN` or `SIGNED_OUT`; the command and its supporting code
are absent from release builds.

## Testing

- **Before activation**: run the ambitious repo's disposable local
  Supabase lab (server doc §"Zero-cost canonical local lab"), register a
  public PKCE-S256 test client with Prompter's exact DEBUG custom callback,
  point Prompter's issuer/client_id at the lab, and exercise: approve, deny,
  bad state, reused code, and token validation failures.
- **After activation**: repeat against production with the real client_id,
  plus revoke-from-Connected-Apps and refresh-after-revoke.
- Headless CI can't drive the browser flow; keep validation logic
  (PKCE, JWT checks) in pure functions with unit tests in
  `Tests/PrompterTests`.

## Production activation record

The callback page, hosted OAuth server, ES256 JWKS, identity-only claims hook,
and public Prompter registration are active. Production acceptance includes a
real authorization-code/PKCE-S256 sign-in, Connected Apps grant visibility,
revocation, and refresh-after-revoke behavior. Supabase's hosted discovery also
advertises `plain`; Prompter never uses it and always generates S256.
