# Changelog

## Unreleased

- Add the grant continuation request payload with an optional interaction reference,
  empty-object support, JSON extensions/codecs and redacted inspection/errors.
- Add typed grant continuation responses for token, subject, combined and
  continuation-only results, with presence predicates, nested validation and JSON codecs.
- Add typed initial grant responses with pending/approved predicates, nested
  validation, subject/extension preservation and redacted inspection/errors.
- Add typed pending-grant interaction instructions with redirect/finish validation,
  preserved JSON extensions and redacted inspection/errors.
- Add typed grant continuation data and separate continuation credentials, with
  URI/wait validation, preserved JSON extensions and redacted inspection/errors.
- Add the issued access-token response type with typed access entries, expiry/URI
  validation, strict fields, JSON codecs and redacted inspection/errors.
- Add complete grant-request and access-token-request types with typed composition,
  request-variant and directed-identity validation, JSON codecs and safe errors.
- Add subject and subject-identifier types with exact array cardinality, preserved
  JSON extensions, indexed validation errors and redacted inspection.
- Add typed outgoing grant access and complete access-array validation, with nested
  limits/card payloads, cardinality/uniqueness checks and indexed safe errors.
- Add card-authorization and PIN working-key payload types with strict fields,
  the PIN-block dependency, JSON codecs and redacted inspection/errors.
- Add typed outgoing-payment grant limits with exclusive debit/receive amounts,
  receiver validation, preserved interval/extension data and JSON codecs.
- Add incoming-payment and quote grant-access types with unique action validation,
  optional incoming identifiers, strict union fields and JSON codecs.
- Add typed grant interaction requests and finish callbacks with nested validation,
  extension preservation, JSON codecs and nonce-safe inspection/errors.
- Add typed grant client identities for wallet strings, wallet objects and
  directed public JWKs, with optional display metadata and exact JSON round trips.
- Add typed grant client display information with optional-field validation,
  strict field names and JSON encoding.
- Add authenticated client construction with explicit key imports or validated
  existing keys, shared wallet identity policies and internal per-call signing.
- Add unsigned public incoming-payment reads from full resource URLs, with typed
  responses, schema validation and operation-specific HTTP/decoding/transport errors.
- Add the public incoming-payment response type with nested amounts and methods,
  RFC 3339 validation, preserved extensions and safe inspection/error paths.
- Add the typed ILP payment method with schema validation, explicit JSON codecs
  and shared-secret redaction in inspection and validation errors.
- Add unsigned wallet JWKS discovery with URL/payment-pointer resolution, typed
  public keys, indexed response validation and operation-specific errors.
- Add public client construction and unsigned wallet discovery from URLs or payment
  pointers, with typed responses, request policies and structured HTTP/decoding errors.
- Add raw Req transport with finite timeouts, safe errors, and no automatic retries,
  redirects or decoding; verify signed wire bytes and align empty-query/IPv6 Host handling.
- Add immutable request preparation with one-time JSON encoding, per-request
  GNAP authorization/signing, URL and header policies, and safe inspection/errors.
- Add internal Node-profile Signature and Signature-Input generation, opaque-key
  Ed25519 signing, deterministic Node vectors, and covered-field tampering tests.
- Prepare SHA-512 content digests and byte-accurate JSON content headers from the
  exact encoded request body, with RFC and independent Node crypto test vectors.
- Add private Ed25519 JWK import with canonical key-byte validation, public/private
  consistency checks, signing metadata constraints, and Node interoperability tests.
- Add file and base64 PEM key imports with shared key validation, read-only file
  handling, and configuration errors that omit paths and key material.
- Add unencrypted Ed25519 PKCS#8 PEM import with configuration validation and
  independently generated Node crypto fixtures.
- Add explicit Ed25519 key generation, raw seed import, and typed public JWK/JWKS
  export using OTP crypto, with redacted key inspection and configuration errors.
- Add typed public JWK and JWKS models with schema validation, indexed errors,
  JSON conversion, metadata preservation, and private-key export protection.
- Add payment-pointer-to-URL conversion with standard well-known-path resolution
  and validation of the restricted pointer syntax.
- Add the typed wallet-address model with URI-format validation, optional public-name
  handling, JSON conversion, and extension preservation, tested against documented
  tenant-scoped and local development endpoint layouts.
- Add the typed amount model with uint64 validation, explicit JSON field mapping,
  extension preservation, and structured validation errors.
- Initialize the Open Payments Elixir client package.
- Bundle the shared Open Payments 1.5.0 specifications with revision and checksums.
- Add a reproducible specification sync/check task and operation inventory.
- Verify the HTTP-signature dependency against the RFC 9421 Ed25519 test vector.
