# Open Payments Elixir

An Elixir client for the Open Payments wallet address, authorization, and resource
server APIs. Supports Elixir 1.17 and later on compatible Erlang/OTP versions.

The package is under development and has not been published.
Its package/application name is `open_payments_elixir`; Elixir modules use the
`OpenPayments` namespace.

## Public wallet discovery

Create a public client and look up a wallet using its URL or payment pointer:

```elixir
{:ok, client} = OpenPayments.Client.new_public()
{:ok, wallet} = OpenPayments.WalletAddress.get(client, "$wallet.example.com/alice")

wallet.auth_server
wallet.resource_server
```

Replace the example address with a conforming Open Payments wallet. Discovery is
an unsigned GET returning `{:ok, %OpenPayments.Types.WalletAddress{}}` or
`{:error, %OpenPayments.Error{}}`. The client requests JSON with identity encoding,
validates the response, and preserves returned server URLs and additional fields.

Public clients accept positive millisecond timeout options and a custom headers
map. Accept/Accept-Encoding and signing/transport headers are SDK-owned. A Req
adapter module can be supplied for tests. Clients make no requests on construction
and can be shared between processes without storing per-call tokens.

For a local playground, opt into HTTP explicitly:

```elixir
{:ok, client} = OpenPayments.Client.new_public(allow_http: true, receive_timeout: 5_000)
{:ok, wallet} = OpenPayments.WalletAddress.get(client, "http://localhost:3000/accounts/alice")
```

Production discovery identifiers follow the [wallet-address URL rules](https://openpayments.dev/concepts/wallet-addresses/):
HTTPS without user-info, explicit port, query or fragment. HTTP development URLs
may include a local port when enabled. This request-side policy is stricter than
Node's generic URL handling; the response model continues to follow its URI schema.
Automatic payment-pointer resolution is an Elixir convenience. Redirects are not
followed. Grant, token and authenticated resource operations are still being implemented.

Errors identify `operation: :get_wallet_address`. HTTP failures retain the status
and recognized server error fields; invalid success JSON or wallet data returns a
decoding error. Non-JSON error bodies are not copied into diagnostics. Inspection
omits server descriptions/details; read those fields explicitly when needed.

Fetch the wallet's public keys with the same client:

```elixir
{:ok, key_set} = OpenPayments.WalletAddress.get_keys(client, wallet.id)
Enum.map(key_set.keys, & &1.kid)
```

`get_keys/2` also accepts payment pointers and returns a validated
`OpenPayments.Types.JWKS` containing typed public keys. It requests the wallet URL
plus `/jwks.json`, reusing a trailing slash instead of adding a second one. This
differs from Node's literal suffix concatenation; other path bytes are preserved.
A root pointer resolves to `/.well-known/pay/jwks.json`. Supply the wallet address,
rather than the complete JWKS endpoint. Each call fetches afresh without caching,
key selection or signature verification. Empty key sets and duplicate key IDs
follow the shared schema. Errors use `operation: :get_wallet_address_keys`, with
indexed validation paths such as `keys[1].d` for a rejected private key field.

## Authenticated client configuration

Configure a wallet identity and an Ed25519 key for authenticated operations:

```elixir
{:ok, client} =
  OpenPayments.Client.new_authenticated(
    wallet_address: "https://wallet.example.com/alice",
    key_id: "registered-key-id",
    private_key: {:file, "private-key.pem"}
  )

OpenPayments.Client.authenticated?(client)
# => true
OpenPayments.Client.wallet_address(client)
# => "https://wallet.example.com/alice"
```

Private-key sources are explicit: `{:pem, text}`, `{:file, path}`,
`{:base64_pem, text}`, `{:jwk, map}`, or `{:seed, bytes}`. Alternatively, supply
`key: key` using an existing `OpenPayments.Key` and omit `private_key`/`key_id`.
The key's public/seed consistency and key ID are checked. Invalid input returns a
configuration error without retaining rejected values or generating a replacement
key. No key source is guessed from a string.

The constructor accepts the same HTTP options as `new_public/1`. Wallet identities
use the same URL/payment-pointer rules as discovery and are normalized once.
Construction makes no HTTP requests and does not check wallet/key registration.
Client inspection omits the identity, key and custom headers. Access tokens remain
per-call data rather than client state. Public reads stay unsigned, following
Node's public-GET behavior; signed dispatch is an internal building block for the
upcoming grant, token and authenticated resource operations.

## Grant client identities

`OpenPayments.Types.GrantClient.from_value/1` decodes a grant's client identity
from a `walletAddress` object, a public `jwk` object, or the deprecated wallet URI
string. Object forms support a typed optional `ClientDisplay`. Exactly one
identity is required; extra object fields and explicit null displays are rejected.

```elixir
{:ok, identity} = OpenPayments.Types.GrantClient.from_value(%{
  "walletAddress" => "https://wallet.example.com/alice",
  "display" => %{"name" => "Example client"}
})

OpenPayments.Types.GrantClient.to_value(identity)
```

`to_value/1` and JSON encoding preserve the supplied string/object form and wire
field names. URI values retain their spelling; this data codec does not resolve
payment pointers or fetch keys. Directed identities contain validated public JWK
structs and reject private key material. Inspection omits nested JWK/display data.
Use `validate/1` after modifying a struct. `GrantRequest` enforces the restriction
on directed identity with explicit interaction; matching the public JWK to the
configured signing key belongs to the upcoming grant operation. This identity
codec makes no requests or changes to client configuration.

## Grant client display information

`OpenPayments.Types.ClientDisplay.from_map/1` decodes optional `name`, `uri` and
`logo_uri` fields for the grant client's display information. All fields may be
omitted, including for an empty display object. Explicit JSON nulls and extra
fields are rejected. `validate/1` checks manually modified structs; `to_map/1`
and JSON encoding omit nil fields and preserve the protocol name `logo_uri`.

URI values are preserved and follow the schema's absolute-URI format, including
`data:` image URIs. This self-asserted information is not verified by the SDK and
no URI is fetched. `GrantClient` composes this metadata with either object identity.
`GrantRequest` composes this identity data; grant HTTP operations remain under
development. Display metadata does not change client-constructor options.

## Grant interaction requests

`OpenPayments.Types.InteractionRequest` describes the grant request's `interact`
field, with a required `start` array and an optional typed `InteractionFinish`
callback. For example, generate a fresh nonce for each grant request:

```elixir
nonce = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

{:ok, interaction} = OpenPayments.Types.InteractionRequest.from_map(%{
  "start" => ["redirect"],
  "finish" => %{
    "method" => "redirect",
    "uri" => "https://client.example.com/callback",
    "nonce" => nonce
  }
})
```

Both start entries and the finish method must be `redirect`. The pinned schema
does not require `start` to be nonempty or unique. Omitted `finish` becomes nil;
explicit null is rejected. Callback URIs retain their spelling and follow the
schema's absolute-URI format, independently of HTTP request-target policies.
Additional JSON fields at both levels are preserved in `extensions`.

Both types provide `from_map/1`, `validate/1`, `to_map/1` and JSON encoding.
Inspection and validation errors omit nonce values; explicit protocol exports
include them. Data validation checks nonce strings without assessing randomness.
The types do not generate nonces, open consent pages, verify callback hashes or
continue grants. Those operations remain under development.

## Grant access permissions

`OpenPayments.Types.AccessIncoming` describes incoming-payment permissions:

```elixir
{:ok, access} = OpenPayments.Types.AccessIncoming.from_map(%{
  "type" => "incoming-payment",
  "actions" => ["create", "read"],
  "identifier" => "https://wallet.example.com/alice"
})
```

Its allowed actions are `create`, `complete`, `read`, `read-all`, `list` and
`list-all`. `OpenPayments.Types.AccessQuote` uses type `quote` and permits
`create`, `read` and `read-all`. Both types require unique action strings, preserve
their order and allow an empty actions array. Incoming identifiers are optional;
explicit null is invalid and URI spelling is preserved without request-target
restrictions. Quote entries do not accept an identifier.

Both types validate the enclosing `access-item` union, which forbids extra fields.
They provide `from_map/1`, `validate/1`, `to_map/1` and JSON encoding. These codecs
describe individual permission entries; they do not obtain grants or authorize
requests.

`OpenPayments.Types.AccessOutgoing` uses type `outgoing-payment` and requires an
absolute-URI `identifier`. Its unique actions may be `create`, `read`, `read-all`,
`list` and `list-all`. Optional `limits` and `cardAuthorization` decode to typed
`OutgoingLimits` and `CardAuthorization`; explicit nulls and extra top-level fields
are rejected. Inspection omits identifiers, limits and card payloads.

Use `OpenPayments.Types.Access` to validate a complete access array:

```elixir
{:ok, access} = OpenPayments.Types.Access.from_list([
  %{"type" => "incoming-payment", "actions" => ["create", "read"]},
  %{"type" => "quote", "actions" => ["create"]}
])

OpenPayments.Types.Access.validate(access)
# => :ok
```

The result is a list of typed access structs. `OpenPayments.Types.Access.to_list/1` converts it to
wire maps; Jason also encodes the typed list directly. Empty arrays are allowed,
with at most three unique complete access objects. Distinct entries of the same
resource type are permitted. Entry and action order are preserved. Uniqueness
follows [JSON Schema equality](https://json-schema.org/draft/2020-12/json-schema-core#section-4.2.2),
including object-key order independence and equivalent numeric values in metadata.
Errors carry indexed paths such as `access[1].card_authorization.pwk.key`, without
retaining rejected payloads. Explicit JSON exports include card data.
`GrantRequest` composes these access requests; grant HTTP operations remain under
development.

Outgoing-payment limits are described by `OpenPayments.Types.OutgoingLimits`:

```elixir
{:ok, limits} = OpenPayments.Types.OutgoingLimits.from_map(%{
  "receiver" => "https://wallet.example.com/tenant/incoming-payments/payment-1",
  "interval" => "R12/2019-08-24T14:15:22Z/P1M",
  "debitAmount" => %{"value" => "500", "assetCode" => "USD", "assetScale" => 2}
})
```

An empty object or limits without an amount are allowed. `debit_amount` and
`receive_amount` become typed `Amount` structs; at most one may be supplied.
This exclusivity follows Node's grant-request validation in addition to the
schema's permissive `anyOf` branches. Amount fields are validated whenever
present. Optional-field omission becomes nil; explicit JSON null is rejected.

Receivers follow the schema's absolute-URI format and HTTP(S) incoming-payment
URL pattern, with tenant paths and opaque identifiers preserved. Intervals follow
the schema's string constraint; their recurrence syntax is not parsed or
calculated. Additional JSON fields remain in `extensions`. The type provides
`from_map/1`, `validate/1`, `to_map/1` and JSON encoding, without network requests or
spending tracking. Inspection omits amount and extension metadata.

## Card authorization payloads

`OpenPayments.Types.CardAuthorization` represents card credentials or results on
outgoing-payment access. Required protocol fields are `tlvData` and `requestId`,
mapped to `tlv_data` and `request_id` in the struct. Optional `pinBlock` maps to
`pin_block` and requires a typed `OpenPayments.Types.PINWorkingKey` in `pwk`
whenever present, including for an empty string. A working key may be supplied
without a PIN block. Omitted optional fields become nil; explicit nulls are rejected.

`PINWorkingKey` requires the exact string fields `key`, `kvc` and `iv`. Both types
forbid extra fields and provide `from_map/1`, `validate/1`, `to_map/1` and JSON
encoding. Payload strings retain their supplied values; the schema declares no
hex, byte-length or request-ID format constraint.

Inspection omits all card and working-key values, and validation errors contain
safe paths such as `pwk.kvc`. Explicit map/JSON exports include the sensitive
protocol data. These codecs perform no EMV decoding, PIN encryption, request-ID
generation, replay correlation or network requests. `AccessOutgoing` composes
these payloads; grant HTTP operations remain under development.

## Grant subject information

`OpenPayments.Types.Subject` contains exactly one typed `SubjectIdentifier` in its
required `sub_ids` array:

```elixir
{:ok, subject} = OpenPayments.Types.Subject.from_map(%{
  "sub_ids" => [%{"id" => "https://wallet.example.com/alice", "format" => "uri"}]
})
```

Missing, null, empty and multi-entry `sub_ids` arrays are rejected. Each identifier
requires an `id` string and the exact format discriminator `uri`. The pinned
schema puts no URI-format, pattern or minimum-length constraint on `id` itself;
its supplied spelling is retained without wallet discovery or request-target
validation. Additional JSON fields are preserved in `extensions` at both levels.

Both types provide `from_map/1`, `validate/1`, `to_map/1` and JSON encoding. The
wire name remains `sub_ids`. Errors include safe paths such as `sub_ids[0].format`.
Inspection omits identifiers and extension values; explicit protocol exports
contain them. These types describe subject information without verifying identity
or making requests. `GrantRequest` composes subject data; grant HTTP operations
remain under development.

## Complete grant-request data

`OpenPayments.Types.GrantRequest.from_map/1` composes the client identity,
requested access, interaction and subject types into a complete grant payload:

```elixir
{:ok, request} = OpenPayments.Types.GrantRequest.from_map(%{
  "client" => %{"walletAddress" => "https://wallet.example.com/alice"},
  "access_token" => %{
    "access" => [%{"type" => "incoming-payment", "actions" => ["create", "read"]}]
  }
})

OpenPayments.Types.GrantRequest.validate(request)
# => :ok
```

`client` is required. Requests may contain `access_token`, or `subject` with
`interact`, or both. Subject data alongside an access-token request does not
itself require interaction. Directed public-JWK identity rejects an explicit
`interact` field, following the specification's non-interactive restriction.

The `access_token` object becomes an `OpenPayments.Types.AccessTokenRequest` with
a typed access list. Optional fields become nil when omitted; explicit nulls are
rejected. Permitted JSON extensions are preserved at the grant and access-token
request levels. `validate/1` revalidates all nested typed models; `to_map/1` and
JSON encoding preserve protocol field names and string/object identity forms.

Inspection omits payload values; explicit exports include any card data, callback
nonces and subject identifiers. Nested errors use paths such as
`access_token.access[0].card_authorization.pwk.key`. These codecs make no requests,
perform no signing-key/identity match and do not verify callbacks. Grant response
models and the signed HTTP operation remain under development.

## Public incoming payments

Read the public state of an incoming payment using its complete resource URL:

```elixir
{:ok, client} = OpenPayments.Client.new_public()
{:ok, payment} =
  OpenPayments.IncomingPayment.get_public(
    client,
    "https://wallet.example.com/tenant/incoming-payments/payment-1"
  )

payment.completed
payment.received_amount.value
```

This unsigned GET sends no access token or signature and returns
`{:ok, %OpenPayments.Types.PublicIncomingPayment{}}` or `{:error, %OpenPayments.Error{}}`.
Supply the full payment URL; payment pointers are wallet identifiers. Resource
paths and queries are preserved, HTTPS ports are allowed, and HTTP requires the
client's explicit development opt-in. The SDK does not append a resource path,
cache results, follow redirects or retry requests. Errors identify
`operation: :get_public_incoming_payment` and distinguish HTTP, decoding,
validation, configuration and transport failures.

`OpenPayments.Types.PublicIncomingPayment.from_map/1` validates the pinned
`incoming-payment-without-access-token` response. Its required fields are `id`,
`completed`, `received_amount`, `created_at`, `methods` and `auth_server`; amounts
and ILP payment methods are typed structs. Optional `incoming_amount` and
`expires_at` become nil when omitted. Explicit JSON nulls are rejected. Empty
method lists are allowed; duplicate method objects are rejected. Additional JSON
fields remain in `extensions`.

URI and [RFC 3339](https://www.rfc-editor.org/rfc/rfc3339.txt) timestamp strings
retain their original spelling, offsets and fractional precision. Timestamp
validation checks calendar/clock bounds and leap-second placement at the final
UTC minute of a month, without verifying a historical leap-second table. It
preserves the unknown-local-offset notation `-00:00`. This data validation does
not compare amounts, assets or expiration times, or authorize URI request targets.

`validate/1` checks manually modified structs, and `to_map/1`/JSON encoding export
protocol fields, including ILP shared secrets. Inspection omits methods and
extensions. Validation errors use paths such as `received_amount.value` and
`methods[0].shared_secret`, without retaining rejected values. Public reads use
this current schema; authenticated incoming-payment operations are still being
implemented.

## ILP payment methods

`OpenPayments.Types.ILPPaymentMethod.from_map/1` decodes an incoming payment's
`{"type":"ilp","ilpAddress":...,"sharedSecret":...}` method into a struct with
`type`, `ilp_address` and `shared_secret` fields. It validates the shared schema's
ILP address syntax and 1023-character limit, nonempty unpadded base64url secret
alphabet, and prohibition on additional fields. It does not impose a decoded
secret length or establish a STREAM connection.

Inspection omits the shared secret; `to_map/1` and JSON encoding explicitly include
it for protocol use. Treat exported maps and JSON as sensitive. Use `validate/1`
after manually constructing or modifying a struct. Authenticated incoming-payment
HTTP APIs are still being implemented.

## Amounts

Amounts retain integer values as decimal strings, with explicit asset codes and
scales:

```elixir
{:ok, amount} = OpenPayments.Types.Amount.new("1000", "USD", 2)
OpenPayments.Types.Amount.to_map(amount)
# => %{"value" => "1000", "assetCode" => "USD", "assetScale" => 2}
```

`OpenPayments.Types.Amount.from_map/1` validates decoded JSON objects, retaining
additional fields. The struct also supports `Jason.encode/1` with the protocol's
field names. Invalid inputs return `{:error, %OpenPayments.Error{}}` with
field-specific validation issues.

## Wallet address data

Decode wallet information into a typed struct:

```elixir
{:ok, wallet} =
  OpenPayments.Types.WalletAddress.from_map(%{
    "id" => "https://wallet.example.com/alice",
    "assetCode" => "USD",
    "assetScale" => 2,
    "authServer" => "https://auth.wallet.example.com/123e4567-e89b-12d3-a456-426614174000",
    "resourceServer" => "https://wallet.example.com/123e4567-e89b-12d3-a456-426614174000"
  })

wallet.resource_server
# => "https://wallet.example.com/123e4567-e89b-12d3-a456-426614174000"
```

Additional JSON fields are preserved. `publicName` is optional; when present it
must be a string. `WalletAddress.to_map/1` and the Jason encoder use protocol field
names and omit an absent public name. This model performs no HTTP requests.

The example uses the tenant-scoped endpoint layout documented by
[Rafiki](https://rafiki.dev/overview/concepts/payment-pointers/). The SDK preserves
server URLs exactly; it does not require tenant UUIDs or particular hostnames or paths.

Following the Node SDK's separation of response data and request handling, this
model validates the shared schema's URI format and preserves the data. It also
accepts local HTTP data, including wallet IDs on `http://localhost:3000` and an
auth server on `http://localhost:3006`, as documented for the
[Rafiki playground](https://rafiki.dev/integration/playground/overview/).

Successful decoding does not authorize an endpoint for network requests.
Production wallet identifiers have stricter
[Open Payments URL rules](https://openpayments.dev/concepts/wallet-addresses/):
HTTPS with no user-info, explicit port, query, or fragment. Enforcing request
policies belongs to request preparation and discovery, separately from this model.

One deliberate validation difference: the Node SDK's `@interledger/openapi` 2.0.4
response validator accepts malformed URI strings. This model enforces the shared
schema's `uri` format and rejects malformed or relative URIs.

## Payment pointers

Convert payment-pointer shorthand to an HTTPS discovery URL:

```elixir
OpenPayments.PaymentPointer.to_url("$wallet.example.com/alice")
# => {:ok, "https://wallet.example.com/alice"}

OpenPayments.PaymentPointer.to_url("$wallet.example.com")
# => {:ok, "https://wallet.example.com/.well-known/pay"}
```

Both `$host` and `$host/` use `/.well-known/pay`; other paths are preserved.
User-info, explicit ports, queries, fragments, and malformed input return
`{:error, %OpenPayments.Error{}}`. Full URLs should be passed directly to discovery,
rather than to this shorthand-only helper.

This helper implements [payment-pointer syntax and resolution](https://paymentpointers.org/syntax/)
without making requests. Discovery must still check whether the resulting endpoint
supports Open Payments. Wallet response fields remain unchanged by this helper.

## Public keys

Decode a wallet's public key set into nested structs:

```elixir
{:ok, key_set} =
  OpenPayments.Types.JWKS.from_map(%{
    "keys" => [%{
      "kid" => "key-1",
      "alg" => "EdDSA",
      "kty" => "OKP",
      "crv" => "Ed25519",
      "x" => "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
    }]
  })

[%OpenPayments.Types.JWK{kid: "key-1"}] = key_set.keys
```

`JWK.from_map/1` also decodes individual keys. Both types provide `validate/1`,
`to_map/1`, and Jason encoding. Nested errors identify the key and field, for
example `keys[0].x`. Additional metadata is preserved within keys; the shared
schema forbids additional fields on the set itself.

These public-key types require the schema's `EdDSA`, `OKP`, and `Ed25519` values.
The optional `use` field must be `sig` when present. Unlike the shared schema's
unrestricted additional JWK properties, these public types reject private `d`
material and exclude it from public export. Cryptographic validation of decoded
key bytes and key selection will be provided by the signing utilities.

## Signing keys

Generate a new Ed25519 key explicitly and export its public key for registration:

```elixir
{:ok, key} = OpenPayments.Key.generate("registered-key-id")
public_key_set = OpenPayments.Key.public_jwks(key)
{:ok, public_json} = Jason.encode(public_key_set)
```

`OpenPayments.Key.from_seed(seed, key_id)` imports an existing raw 32-byte Ed25519
seed, preserving its identity. `OpenPayments.Key.from_pem(pem, key_id)` imports
an unencrypted Ed25519 PKCS#8 private key, such as one exported by Node's crypto
library. It requires a single PEM entry and rejects encrypted keys, public-only
keys, other algorithms, and malformed inputs. It never generates a replacement
when an import fails.

Load PEM from a file or from base64-encoded configuration text:

```elixir
{:ok, key} = OpenPayments.Key.from_file("/path/to/private-key.pem", "registered-key-id")
{:ok, key} = OpenPayments.Key.from_base64_pem(encoded_pem, "registered-key-id")
```

File import only reads the file. Base64 import accepts optional padding and ASCII
whitespace; decoded contents must satisfy the same PEM requirements above. Invalid
encoding, file-read failures, and invalid key contents return configuration errors.

`OpenPayments.Key.from_jwk(private_jwk, key_id)` imports an Ed25519 private JWK,
including Node's native JWK exports. It requires `kty: "OKP"`, `crv: "Ed25519"`,
and canonical unpadded base64url `d` and `x` values encoding 32 bytes each. The
public key must match the private seed. Unlike public response models, this
cryptographic import checks decoded key sizes and key consistency.

Optional `alg` and `use` must be `EdDSA` and `sig`. If `key_ops` is supplied, it
must allow `sign` and may also allow `verify`, without duplicates. The explicit
`key_id` determines the exported ID; any JWK `kid` must be a string and does not
override it. Other JSON metadata is accepted and discarded. This import follows
the [OKP key format](https://www.rfc-editor.org/rfc/rfc8037.html#section-2) and
[JWK operation restrictions](https://www.rfc-editor.org/rfc/rfc7517.html#section-4.3)
for signing keys.

Key IDs must be nonblank strings. Invalid inputs return configuration errors
without retaining rejected values.

`public_jwk/1` and `public_jwks/1` return the typed public models described above,
without private material. Key structs hide key material during inspection and have
no JSON encoder; the seed remains in process memory. The Open Payments
request-signing pipeline is still being implemented.

`OpenPayments.Key.key_id/1` reads the configured identifier. `Key.sign/2` signs
exact binary data and returns raw Ed25519 signature bytes; it does not construct
an HTTP request or send one.

## Development

```sh
mix deps.get
mix check
mix dialyzer
```

After dependencies are installed, `mix test` runs without network access,
credentials, a database, or an external payment server. External integration tests
are excluded by default.

## Protocol baseline

The SDK targets Open Payments specification 1.5.0. Its specification artifacts are
bundled with the package; consumers do not need Git submodules.

The source of truth is the shared
[Open Payments Specifications repository](https://github.com/interledger/open-payments-specifications).
The bundled `priv/specifications/SOURCE.json` records the exact upstream commit,
version, and checksums for all three API documents.

To adopt an upstream revision:

```sh
mix open_payments.spec.sync --ref FULL_COMMIT_SHA
mix check
```

Use `--source /path/to/specifications` to sync from an existing local checkout,
and `--check` to verify without modifying files. Review the upstream changes and
update affected SDK types, validators, and tests before merging a new baseline.

The current operation inventory is available through
`OpenPayments.Specification.operations/0`. Source documents are available through
`OpenPayments.Specification.document/1`.

## Signing dependency

HTTP signature framing uses `message_signatures`, with Ed25519 provided by OTP
crypto. A contract test reproduces the published RFC 9421 Appendix B.2.6 signature.
Content-header preparation uses SHA-512 and byte lengths from the exact encoded
request body, following [RFC 9530](https://www.rfc-editor.org/rfc/rfc9530.html#section-2).
An absent body produces no content headers; an explicit empty binary produces a
zero-length body with its digest. Protocol payload validation and JSON encoding
belong before this byte-level preparation.

One deliberate difference from the Node SDK's content-header helper: the Elixir
helper hashes the supplied bytes directly, preserving whitespace, property order,
and Unicode spelling. Node's helper parses and re-serializes JSON before hashing.
The future transport must send the same bytes used for the digest and signature.

Internal header generation now uses the reviewed Node Open Payments profile:
`sig1` covers `@method`, `@target-uri`, authorization when present, and all three
content headers when a body is present. Its parameters are `keyid` and `created`,
in that order. Header matching is case-insensitive. Structured-field escaping and
signature-base construction use the signing dependency; private key bytes remain
inside `OpenPayments.Key`.

The profile matches deterministic vectors from `@interledger/http-signature-utils`
2.0.3 for equivalent prepared requests. It uses SHA-512 content digests and has
no `tag` or `nonce`. Final [GNAP RFC 9635 §7.3.1](https://www.rfc-editor.org/rfc/rfc9635.html#section-7.3.1)
requires `tag="gnap"`, recommends a nonce, and defaults string-form `httpsig` to
SHA-256. This initial profile follows the sibling SDK; it is not a claim of full
final-GNAP profile compliance or live-server interoperability.

Internal request preparation now assembles the final method, URL, headers and
body before signing. JSON is encoded once; pre-encoded body bytes are retained.
Omitted bodies, empty binaries, and JSON null have distinct representations.
The signing key and access token are per-request values. A key explicitly requests
signing; public operations omit it. Key-bound GNAP tokens use the
[token68 character set](https://www.rfc-editor.org/rfc/rfc9635.html#section-3.2.1)
and require a signing key.

Request URLs require HTTPS by default; HTTP needs explicit `allow_http: true`.
User-info and fragments are rejected. Host case, default ports and empty root
paths are normalized; paths and nonempty query strings retain their spelling,
including percent escapes, ordering and dot segments. A trailing empty `?` is
removed before signing to match Finch's actual request-target serialization.
This preserves more path spelling
than Node's WHATWG URL handling. Wallet-identifier discovery rules and operation
payload validation belong to the resource clients, separately from this generic
HTTP request preparation.

Custom headers are checked for case-insensitive duplicates and invalid ASCII or
control characters. Authorization, content/signature headers and transport framing
are SDK-owned and cannot be overridden through custom headers. Request inspection
omits URLs, headers and bodies. These are internal building blocks used by the
public client and wallet discovery; authenticated resources remain to be implemented.

The internal transport sends prepared requests through Req's low-level API.
It has no automatic retries, redirects, request re-encoding, response decoding,
or decompression, and does not inherit global Req defaults or plugins. It sets
Host from the prepared URL, including IPv6 brackets and nondefault ports. Local
TCP tests verify the actual received target, headers, body digest and signature.

Connect and pool timeouts default to 5 seconds; receive and complete-response
timeouts default to 15 seconds. Each accepts a finite positive millisecond value.
A Req adapter module can be supplied for testing. Transport errors return safe
SDK errors; all HTTP status codes return raw response data for resource-level JSON,
error and schema handling. This transport does not establish live-server interoperability.

## License

Apache-2.0. See the `LICENSE` file.
