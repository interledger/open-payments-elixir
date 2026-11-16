# Changelog

## Unreleased

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
