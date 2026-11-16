# Content-header test vectors

`content-headers.json` contains expected SHA-512 content headers for exact body
bytes. The `source` field records the Node.js runtime that generated them.

Each `body_base64` field preserves the full input bytes, including whitespace,
line endings, empty content and a non-UTF-8 test case. Expected digests were
produced with Node's `crypto.createHash("sha512").update(body).digest("base64")`;
lengths use `Buffer.length`. Tests do not need Node.js installed.

The `rfc9530-appendix-d` case also matches the published SHA-512 vector in
[RFC 9530 Appendix D](https://www.rfc-editor.org/rfc/rfc9530.html#appendix-D).
No trailing newline is included in that case.

These vectors check hashing and byte counting. They do not assert that every
input is valid JSON or a valid Open Payments payload; payload validation occurs
before content-header preparation in the future request pipeline.

## Signature vectors

`node-signatures.json` records deterministic Ed25519 signatures, complete bases,
and prepared headers. The source metadata records Node.js and package versions.
The private key is the existing public RFC 8032 test-1 fixture under `keys`.
The clock was fixed at Unix time 1618884473.

Six vectors use `@interledger/http-signature-utils` 2.0.3 `createHeaders` directly.
Three use its underlying `http-message-signatures` 1.0.8 `httpbis.signMessage` with
the same component and parameter order, supplying exact-byte content headers or
mixed-case authorization. Those cases exercise documented differences from the
Node helper's JSON canonicalization, empty-body truthiness, and authorization
casing check. Each vector identifies its source.

Bases were constructed with the Node library's `createSignatureBase` and
`formatSignatureBase`, and each result was checked with Node's `crypto.verify`
before recording. The key-ID escaping, Unicode body, tenant paths, query encoding,
HTTP development URL, and IPv6 cases require no live server or Node installation
when the Elixir tests run. All tokens in these vectors are public test strings.
