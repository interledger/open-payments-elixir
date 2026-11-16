# PEM test fixtures

`node-pem.json` contains public test keys generated or exported with Node.js
`crypto`. The `source` field records the generating runtime. These fixtures are
committed so Elixir tests do not require Node.js or OpenSSL command-line tools.

The Ed25519 seed and public key come from
[RFC 8032 section 7.1, test 1](https://www.rfc-editor.org/rfc/rfc8032.html#section-7.1).
Node's `createPrivateKey` imported that key as a JWK; its PKCS#8 private key, SPKI
public key, and public JWK were exported with `KeyObject.export`. The signature
was produced with `crypto.sign(null, Buffer.from("Open Payments PEM import"), key)`.
The `private_jwk` entry was exported from the same PEM with
`createPrivateKey(pem).export({format: "jwk"})` for private JWK import tests.

The encrypted Ed25519 entry uses AES-256-CBC and the public test password
`test-only-password`. Ed448, X25519, P-256, and RSA-2048 keys were generated with
`generateKeyPairSync` and exported as PKCS#8 for rejection tests.

These are test material only and must never be used as application credentials.
