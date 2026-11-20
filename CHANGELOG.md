# Changelog

## Unreleased

### Client operations

- Add immutable public and authenticated clients with per-call credentials.
- Add unsigned wallet-address and JWKS discovery with URL/payment-pointer
  resolution, plus public incoming-payment reads.
- Add signed grant initiation, continuation and cancellation, including wallet
  and directed identities, display metadata, interactive and subject responses.
- Add explicit access-token rotation and revocation, with separate issued and
  continuation credential types and latest-token management endpoints.
- Add signed incoming-payment create/read/complete/list operations, quote
  create/read operations, outgoing-payment create/read/list operations and
  current outgoing-grant spent-amount reads.
- Support fixed-debit, fixed-receive and receiver-inferred quotes, plus outgoing
  creation from either a quote or an incoming payment and debit amount.

### Protocol data and validation

- Accept minimal public incoming-payment responses containing `authServer` and
  optional `receivedAmount`, matching the Node SDK and deployed servers, while
  retaining full validation for detailed responses.
- Add typed snake_case Elixir structs with explicit protocol JSON field names,
  nested validation, omission/null distinctions and schema-permitted extensions.
- Cover uint64 amount strings, asset scales, wallet/public keys, ILP methods,
  grants, interactions, subjects, access rights, outgoing limits, pagination and
  payment responses. Preserve amount spelling and opaque server identifiers.
- Add card-authorization and PIN working-key payload validation, including the
  PIN-block dependency; card processing and PIN cryptography remain outside the SDK.
- Apply Node-style incoming/outgoing payment consistency checks at operation
  boundaries. Keep quote and grant-spent responses schema-based, including
  required nullable grant-spent amounts and context-specific payment responses.

### Keys, signing and transport

- Add OTP Ed25519 generation, raw seed and private JWK imports, unencrypted
  PKCS#8 PEM/file/base64 imports, and public JWK/JWKS exports. Reject mismatched
  or unsupported keys without generating replacements or exposing private material.
- Add SHA-256 interaction callback hashing with canonical padded Base64 and
  explicit base64url profiles, constant-time verification and no automatic continuation.
- Sign exact request bytes using the reviewed Node profile: Ed25519, SHA-512
  body digests, covered method/target/authorization/content headers and
  `keyid`/`created` parameters. Serialize JSON once before signing/transmission.
- Add a low-level Req transport with HTTPS by default, explicit HTTP development
  opt-in, finite timeouts, constructor header options and a test adapter boundary.
  Disable automatic retries, redirects, re-encoding and decompression.
- Add structured configuration/validation/signing/transport/HTTP/decoding errors,
  operation/status context, safe validation paths and redacted credential inspection.

### Specifications and compatibility

- Bundle the Open Payments 1.5.0 specifications with their source revision,
  checksums, self-contained references and all 17 HTTP operation IDs.
- Add a reproducible specification sync/check task. Document schema/Node
  differences and require implementation/test review when changing the baseline.
- Support Elixir 1.17+ on compatible OTP versions, with CI pairs 1.17/26,
  1.19/28 and 1.20/29. Verify the signing dependency with RFC 9421 and Node vectors.
- The request-signing profile follows the reviewed sibling SDK; it does not
  implement the complete final GNAP profile. CLI-driven testnet checks exercise
  all 17 HTTP operations, interactive consent/callback verification, token and
  grant lifecycles, and completed quote-based/direct payments.

### Tests and documentation

- Add an offline ExUnit/property/doctest suite covering protocol codecs,
  validation, independent cryptographic vectors, transmitted HTTP bytes,
  failures, concurrency and credential isolation.
- Add complete simulated quote/direct payment flows, callback rejection and
  reconciliation after ambiguous creation without automatic mutation replay.
- Add archive-only production/test Mix consumers with fresh runtime dependency
  resolution, bundled-specification/JSON/signing checks and CI integration.
- Add opt-in HTTPS testnet discovery and existing-resource signed-read checks,
  excluded by default, using local credential files and safe failure diagnostics.
- Document Git/local installation, public APIs, staged payment and callback
  handling, token rotation, natural/recurring expiry, optional early cleanup,
  application responsibilities, contributor checks and official protocol references.
