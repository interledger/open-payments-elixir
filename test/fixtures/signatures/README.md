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
