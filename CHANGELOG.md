# Changelog

## Unreleased

- Add signed outgoing-payment reads with per-call raw/typed tokens, typed
  responses, Node payment consistency checks and operation-specific safe errors.
- Add strict outgoing-payment creation payloads for quote and incoming-payment
  forms, with typed debit amounts, metadata, JSON codecs and safe inspection.
- Add the outgoing-payment creation response with optional typed grant spent
  amounts, shared detail validation, preserved JSON extensions and safe codecs.
- Add the strict outgoing-payment response type with three typed amounts,
  optional failure/quote/metadata fields, JSON codecs and safe inspection/errors.
- Add signed quote creation for all amount variants with typed/map payloads,
  shared collection URL rules, typed responses and no automatic replay.
- Add signed quote reads with per-call raw/typed tokens, strict typed responses,
  operation-specific errors and no automatic replay.
- Add quote creation payloads for fixed-debit, fixed-receive and receiver-inferred
  amounts with strict variants, nested validation, JSON codecs and safe inspection.
- Add the strict quote response type with typed debit/receive amounts, schema-specific
  URI/timestamp rules, JSON codecs and safe inspection/errors.
- Add signed incoming-payment listing with typed/map pagination, Node-compatible
  query encoding, typed pages and indexed asset consistency errors.
- Add typed incoming-payment pages with pagination metadata, ordered detailed
  items, combined-field restrictions, preserved wrapper extensions and indexed errors.
- Add pagination query arguments with bounded integer counts, mutually exclusive
  directions, opaque cursors, strict input fields and JSON codecs.
- Add shared pagination metadata with required page flags, optional opaque cursors,
  strict fields, JSON codecs and safe inspection/errors.
- Add signed incoming-payment completion with per-call tokens, bodyless POSTs,
  detailed response fields and Node-style completed/asset consistency checks.
- Add signed incoming-payment creation with typed/map payloads, per-call tokens,
  tenant-aware collection URLs and Node-style creation response checks.
- Add signed authenticated incoming-payment reads with per-call string/typed tokens,
  typed responses, amount-asset consistency checks and operation-specific errors.
- Add the incoming-payment create request type with strict fields, typed optional
  amount, expiry/metadata validation, JSON codecs and safe inspection/errors.
- Add the incoming-payment response with required typed ILP methods, protocol-object
  uniqueness, shared detail validation and secret-safe inspection/errors.
- Add the detailed incoming-payment response type with typed amounts, wallet and
  metadata validation, preserved JSON fields and safe inspection/errors.
- Add signed access-token revocation using typed management credentials, HTTP 204
  acknowledgement and operation-specific errors without automatic replay.
- Add signed access-token rotation and a typed response wrapper with metadata
  preservation, credential-role validation and operation-specific errors.
- Add pure SHA-256 interaction callback-hash calculation and constant-time verification,
  explicit Base64/base64url profiles, canonical input validation and safe errors.
- Add signed grant cancellation using typed continuation credentials, HTTP 204
  acknowledgement, shared no-content response handling and operation-specific errors.
- Add signed grant continuation with typed credentials, optional JSON/body omission,
  typed result variants, per-call token handling and operation-specific errors.
- Add signed grant initiation with default wallet identification, explicit typed/JSON
  payloads, directed-key matching, typed initial responses and operation-specific errors.
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
