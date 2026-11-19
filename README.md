# Open Payments Elixir

An Elixir client for the Open Payments wallet address, authorization, and resource
server APIs. Supports Elixir 1.17 and later on compatible Erlang/OTP versions.

The package is under development and has not been published.
Its package/application name is `open_payments_elixir`; Elixir modules use the
`OpenPayments` namespace.

## Installation

Until a Hex release is available, add the Git dependency to your application's
`mix.exs`:

```elixir
defp deps do
  [
    {:open_payments_elixir, github: "interledger/open-payments-elixir"}
  ]
end
```

Mix records the selected Git revision in your application's `mix.lock`; commit
that lockfile with the application. Add a `ref` option if you need to select a
specific reviewed commit.

For development alongside a local SDK checkout, use this dependency instead:

```elixir
{:open_payments_elixir, path: "../open-payments-elixir"}
```

The path is relative to your application's project directory. It uses the local
working tree, including uncommitted SDK changes.

Install dependencies and open your application shell:

```sh
mix deps.get
iex -S mix
```

The SDK and its runtime dependencies start with your application. Clients are
immutable configuration structs and do not need entries in your supervision tree.
Specifications are bundled; no Git submodule setup is required. Use the public
discovery example below as a quick start with your own wallet address or payment
pointer. Public discovery needs no private key or access token.

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
followed. Grant/token management, incoming-payment operations, quote operations
and outgoing-payment create/read/list and grant-spent operations are available.

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

## Handling results and errors

Data-returning operations return `{:ok, result}`. Acknowledgements such as grant
cancellation and token revocation return `:ok`. Failures return
`{:error, %OpenPayments.Error{}}`; handle these tuples at the application boundary.
Given a client and an input `wallet_address`, for example:

```elixir
case OpenPayments.WalletAddress.get(client, wallet_address) do
  {:ok, wallet} ->
    {:ok, wallet}

  {:error, %OpenPayments.Error{kind: :http, status: 404}} ->
    {:error, :wallet_not_found}

  {:error, %OpenPayments.Error{kind: kind, status: status, operation: operation}} ->
    {:error, %{kind: kind, status: status, operation: operation}}
end
```

| Error kind | Meaning |
| --- | --- |
| `:configuration` | Invalid client options or signing-key configuration |
| `:validation` | Invalid operation input, URL, token or protocol data |
| `:signing` | Request-signature preparation failed |
| `:transport` | A connection or timeout failure prevented a complete response |
| `:http` | The server returned an unsuccessful HTTP status |
| `:decoding` | Unexpected success status, invalid JSON/schema data or failed response consistency checks |

`operation` identifies the SDK operation; `status` is nil when no HTTP response
is available. Validation issues identify fields without retaining rejected values.
Server `code`, `description` and `details` can contain provider-supplied data.
Choose fields deliberately when logging; the example retains only kind, status
and operation. Explicit JSON exports of tokens, grants and payment data include
their values even when their inspected representation hides sensitive fields.

A timeout or invalid success response after a mutation can leave its outcome
unknown: the server may already have created the payment, continued the grant or
rotated the token. The SDK returns the error without automatically replaying the
request. Use provider-supported reads or application reconciliation before
deciding whether another mutation is appropriate.

## Application responsibilities

Clients hold immutable configuration; keys and tokens are not persisted by the
SDK. Keep workflow state in your application and pass credentials per operation.

| Workflow | Application responsibility |
| --- | --- |
| Grants and consent | Choose permissions, correlate sessions, store fresh client nonces and continuation state, honor `wait`, verify callbacks and prevent replay before continuing |
| Credentials | Register public keys, protect private keys/tokens and persist the latest continuation and rotated access-token data |
| Payments | Select accounts and amounts, arrange funding, reconcile uncertain outcomes and decide completion/settlement policy |
| Recurring grants and pages | Schedule work, interpret provider-enforced intervals and explicitly request subsequent pages |

Use client constructor options for custom headers, finite timeouts and a Req
adapter for tests. SDK-owned signing/transport headers cannot be overridden.
Arbitrary Req plugins and pre/post-signing hooks are not part of the public API.
The SDK performs explicit protocol calls; it does not schedule consent, token
refresh, retries or pagination for the application.

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
Node's public-GET behavior. Grant operations, `OpenPayments.Token.rotate/2` and
`OpenPayments.Token.revoke/2` use signed dispatch, as do
`OpenPayments.IncomingPayment.get/3`, `OpenPayments.IncomingPayment.create/4`,
`OpenPayments.IncomingPayment.complete/3`, `OpenPayments.IncomingPayment.list/4`,
`OpenPayments.Quote.get/3`, `OpenPayments.Quote.create/4`,
`OpenPayments.OutgoingPayment.get/3`, `OpenPayments.OutgoingPayment.create/4` and
`OpenPayments.OutgoingPayment.list/4`.
`OpenPayments.OutgoingPayment.get_grant_spent_amounts/3` reads the current token's
grant spent amounts through signed dispatch.

## Requesting a grant

Use an authenticated client and the complete authorization-server URL discovered
from the wallet:

```elixir
{:ok, grant} =
  OpenPayments.Grant.request(client, wallet.auth_server, %{
    "access_token" => %{
      "access" => [%{"type" => "incoming-payment", "actions" => ["create", "read"]}]
    }
  })

OpenPayments.Types.GrantResponse.approved?(grant)
```

The payload may be a complete typed `GrantRequest` or a string-keyed protocol map.
Maps missing `client` receive the configured wallet URI string, following Node's
default. Explicit client identities retain their string/object form and display
metadata; explicit null is invalid. Typed requests must already include a valid
client identity. Explicit wallet overrides are allowed; the authorization server
checks their key registration. The SDK performs no wallet or JWKS lookup.

Directed identity is checked locally: public JWK fields `kid`, `alg`, `kty`, `crv`
and canonical `x` must match the configured signing key. Optional public metadata
is retained. This check is additional to Node's request implementation. Existing
request validation rejects directed identity with an explicit interaction field.

The operation signs a POST without an access token using the documented Node
signing profile, serializes the body once for digest/signature/transmission, and
returns `{:ok, %OpenPayments.Types.GrantResponse{}}`. The authorization URL is used
directly, preserving path prefixes and queries; HTTPS ports are allowed, and HTTP
requires the client's explicit development opt-in. No path is appended. Redirects
and automatic retries are disabled, including after ambiguous transport failures.

Errors use `operation: :request_grant` and distinguish configuration, validation,
signing, transport, HTTP and decoding failures. Success requires HTTP 200 and a
valid initial response; nested errors retain safe field paths. Inspecting the
response hides tokens, callback values, subject identifiers and card results;
explicit map/JSON exports include them. Grant initiation does not open consent,
verify callbacks, poll, continue/cancel grants or compare granted/requested access.
Local signed wire checks pass; live signed-provider compatibility remains a release check.

## Continuing a grant

Pass the typed `continue` object from the latest response and the authenticated
client holding the same signing key used for initiation:

```elixir
# Call after honoring grant.continue.wait and verifying any interaction callback.
{:ok, continued} = OpenPayments.Grant.continue(client, grant.continue)

# Supply a callback reference only after verifying the callback.
{:ok, continued} =
  OpenPayments.Grant.continue(client, grant.continue, %{
    "interact_ref" => verified_interaction_reference
  })
```

These illustrate alternative calls. The SDK sends one POST to the supplied
continuation URI using `Authorization: GNAP ...` with the continuation credential,
and covers authorization in the signature. It accepts a typed `Continuation`;
an issued resource `AccessToken` cannot replace its typed continuation credential.
The usual request URL and token68 header rules apply. No path is appended.

Omitting the payload or passing nil sends no body. A string-keyed map or typed
`GrantContinuationRequest` sends JSON; `%{}` or an empty request struct sends `{}`
with content headers and a digest. Explicit-null `interact_ref` is invalid.
Success requires HTTP 200 and returns a typed `GrantContinuationResponse` that
may contain an access token, subject information, both, or neither. Errors use
`operation: :continue_grant`, with safe nested paths and the existing error kinds.

The caller must honor the server's `wait` interval before calling. The SDK does
not record receipt times, enforce the delay, sleep or poll. Callers also verify
callbacks with `Interaction.verify_hash/2` before submitting their references.
Use the returned `continued.continue` for a subsequent call, including
any changed URI or credential. Tokens remain per-call data when sharing a client
between processes. Redirects and automatic retries are disabled, including after
transport failures. Live signed-provider compatibility remains a release check.

## Cancelling a grant

Use the typed `continue` object from the latest response with the authenticated
client holding the same signing key used for initiation:

```elixir
:ok = OpenPayments.Grant.cancel(client, continued.continue)
```

This sends one signed DELETE to the supplied continuation URI using its
`Authorization: GNAP ...` credential, with no body or appended path. Authorization
is covered by the signature, and the usual outgoing URL/token68 policies apply.
Typed continuation data is revalidated; an issued resource access token cannot
replace the continuation credential.

HTTP 204 returns `:ok` without JSON parsing or content decoding. Other success
statuses return an `unexpected_status` decoding error. HTTP errors retain the
status and recognized server fields; transport failures retain their existing
error kinds. All errors use `operation: :cancel_grant`. Redirects and automatic
retries are disabled, including after ambiguous connection failures.

The SDK stores no grant state or credentials and leaves the supplied structs
unchanged. The server checks key binding and determines the cancellation's effect.
Use `Token.revoke/2` for resource-token revocation. Live signed-provider checks
remain pending.

## Rotating an access token

Pass an issued `OpenPayments.Types.AccessToken` and the authenticated client
holding its bound signing key:

```elixir
{:ok, rotated} = OpenPayments.Token.rotate(client, issued_token)
new_token = rotated.access_token
```

Rotation sends one signed POST to `issued_token.manage` using its current `value`
in `Authorization: GNAP ...`, with no request body or appended path. Authorization
is covered by the signature. The token is revalidated; continuation credentials
cannot replace it. The usual request URL/token68 policies apply, including HTTPS
by default and explicit development HTTP opt-in.

HTTP 200 returns `{:ok, %OpenPayments.Types.TokenRotationResponse{}}`, retaining
the `access_token` wrapper as Node does. The returned token is typed and permitted
root JSON metadata remains in `extensions`. Use `rotated.access_token`, including
its returned management URI, for subsequent calls. The application owns storage
and replacement of its current token; the SDK keeps no token state and leaves
the client/input unchanged. The server checks key binding and determines old-token
invalidation. The SDK does not rotate the signing key, assess elapsed expiry or
compare old/new access.

Errors use `operation: :rotate_access_token`, with configuration, validation,
signing, transport, HTTP or decoding kinds and safe nested field paths. Redirects
and automatic retries are disabled, including after ambiguous transport failures.
Inspecting the response hides tokens, card results and extensions; explicit
map/JSON exports include them.

`Types.TokenRotationResponse.from_map/1`, `validate/1`, `to_map/1` and JSON encoding
are also available for standalone response handling. Required `access_token`
rejects omission/null and revalidates all typed access entries. Additional JSON
fields are preserved at the wrapper level; the issued token itself keeps its
strict schema. Live signed-provider verification remains pending.

## Revoking an access token

Pass the latest issued token and the authenticated client holding its bound
signing key:

```elixir
:ok = OpenPayments.Token.revoke(client, rotated.access_token)
```

This sends one signed DELETE to the token's `manage` URI using its current `value`
in `Authorization: GNAP ...`, with no body or appended path. Typed token data is
revalidated; continuation credentials cannot replace it. The usual outgoing URL
and token68 header policies apply. The server checks key binding and determines
revocation's effect.

HTTP 204 returns `:ok` without JSON parsing or content decoding. Other success
statuses return an `unexpected_status` decoding error. HTTP/transport failures
retain their status or existing error kind, and all errors use
`operation: :revoke_access_token`. Redirects and automatic retries are disabled,
including after ambiguous connection failures.

Tokens remain per-call data, safe to use with a shared client. The SDK leaves the
client/input unchanged, stores no credentials and performs no elapsed-expiry or
grant-state tracking. The application owns removal of its stored token after
revocation. Grant cancellation uses `Grant.cancel/2` with continuation data.
Live signed-provider verification remains pending.

## Verifying an interaction callback hash

`OpenPayments.Interaction.hash/1` calculates a SHA-256 callback hash;
`verify_hash/2` returns `:ok` on a match or a safe validation error with operation
`:verify_interaction_hash`. Supply the stored client nonce, stored server nonce
(the initial response's `interact.finish`), callback reference and exact initial
grant endpoint. Preserve the URI spelling used for initiation, including its
path/query. Account for request URL preparation when storing that endpoint.

```elixir
hash_context = [
  client_nonce: session.client_nonce,
  server_nonce: session.server_nonce,
  interact_ref: callback_params["interact_ref"],
  grant_endpoint: session.grant_endpoint
]

with :ok <- OpenPayments.Interaction.verify_hash(callback_params["hash"], hash_context) do
  OpenPayments.Grant.continue(client, session.continuation, %{
    "interact_ref" => callback_params["interact_ref"]
  })
end
```

Default `encoding: :base64` produces canonical padded Base64, matching the
[Open Payments JavaScript example](https://openpayments.dev/identity/hash-verification/)
and the [reviewed server implementation](https://github.com/interledger/rafiki/blob/main/packages/auth/src/interaction/routes.ts).
Explicit `encoding: :base64url` produces unpadded base64url, as specified by
[GNAP RFC 9635 §4.2.3](https://www.rfc-editor.org/rfc/rfc9635.html#section-4.2.3).
The Open Payments page's prose/example hash and executable JavaScript differ in
encoding; the helper makes that choice explicit and never falls back to another
format. Select it from trusted configuration. Only SHA-256 is supported.

The hash base uses the four ASCII values in order with LF separators and no
trailing newline. Nonces/reference must be nonempty printable ASCII without
leading/trailing whitespace; internal spaces are retained. Controls and non-ASCII
values are rejected without conversion. The grant endpoint must be a valid
absolute HTTP(S) request URL without user-info or fragment; validation preserves
its hash-input spelling and makes no requests. General JSON codecs retain their
broader schema string constraints.

Pass the callback hash after your framework URL-decodes it once. Padded Base64
contains `+`, `/` and `=`; a correctly encoded callback parameter preserves them.
The helper rejects malformed/noncanonical encodings and compares equal-length
canonical hashes using [OTP's constant-time comparison](https://www.erlang.org/doc/apps/crypto/crypto.html#hash_equals/2).
It never guesses encodings or repairs spaces into plus signs.

Applications own session correlation, fresh unpredictable client nonces, callback
error/result handling, expiry, replay prevention and continuation timing. A hash
match verifies the supplied context; it does not consume a callback or establish
resource authorization. The helpers store no session state and never continue a
grant automatically. Hash mismatch must prevent submission of the reference.

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
on directed identity with explicit interaction; `Grant.request/3` also matches
the public JWK to the configured signing key. This identity
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
`GrantRequest` composes this identity data for `Grant.request/3`.
Display metadata does not change client-constructor options.

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
continue grants. Use `Interaction.verify_hash/2` for callback-hash verification
and `Grant.continue/2,3` for continuation.

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
`GrantRequest` composes these access requests for `Grant.request/3`.

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
these payloads for use in `Grant.request/3`.

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
or making requests. `GrantRequest` composes subject data for `Grant.request/3`.

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
perform no signing-key/identity match and do not verify callbacks.
`Grant.request/3` performs grant initiation with signing and directed-key matching.

## Issued access-token data

`OpenPayments.Types.AccessToken.from_map/1` decodes an issued `access_token` object
from a grant or continuation response. Required fields are the opaque string
`value`, absolute management URI `manage`, and typed `access` list. Optional
`expires_in` is an integer; omission becomes nil and explicit null is invalid.
Additional fields, including camel-case `expiresIn`, are rejected.

Token strings, management URI spelling and expiry metadata are retained as
received. The schema declares no minimum or maximum expiry integer. This response
codec does not calculate elapsed time or apply outgoing request URL/header policy;
those concerns belong to token use and management operations.

Use `validate/1` after modifying typed token data. `to_map/1` and JSON encoding
export protocol values, including the token and nested card results. Inspection
shows only expiry metadata; errors retain safe field paths. Use `Token.rotate/2`
for rotation and `Token.revoke/2` for revocation.

## Grant continuation data

`OpenPayments.Types.Continuation.from_map/1` decodes the `continue` object in a
grant response:

```elixir
{:ok, continuation} = OpenPayments.Types.Continuation.from_map(%{
  "access_token" => %{"value" => "example-continuation-token"},
  "uri" => "https://auth.example.com/tenant/continue/opaque-id",
  "wait" => 30
})

continuation.wait
# => 30
```

The required `access_token` becomes an `OpenPayments.Types.ContinuationToken`,
which is separate from an issued resource `AccessToken`. Its required `value` is
an opaque string. Required `uri` is an absolute URI whose spelling is preserved.
Optional `wait` retains integer seconds as supplied; the schema declares no
minimum or maximum. Omission becomes nil and explicit null is rejected. JSON
extensions are preserved at both object levels.

Both types support `validate/1`, `to_map/1` and JSON encoding. Inspection hides
credentials, continuation URLs and extensions; explicit exports include them.
These codecs perform no waiting, polling or network requests. Continuation timing
and outgoing URL/header policy apply when using `Grant.continue/2,3`.

## Grant interaction response data

`OpenPayments.Types.InteractionResponse.from_map/1` decodes the `interact` object
in a pending grant response. Required `redirect` is an absolute URI; required
`finish` is an opaque string used to secure the callback. Both retain their
spelling, and additional JSON fields are preserved in `extensions`.

The response's `finish` string is distinct from the request's
`InteractionFinish` callback configuration, which contains `method`, `uri` and
the caller's nonce. The response codec imposes no UUID or entropy checks on the
server's string and does not open the consent URI or verify the callback hash.

Use `validate/1` after modifying the struct. `to_map/1` and JSON encoding export
the protocol values; inspection hides redirect, finish and extension data.
Use `Interaction.verify_hash/2` with the stored request nonce, returned finish
value, callback reference and original grant endpoint to verify the callback hash.

## Initial grant responses

`OpenPayments.Types.GrantResponse.from_map/1` decodes the response to an initial
grant request. It requires a typed `continue` object and exactly one of:

- `interact`: typed `InteractionResponse` instructions for pending interaction.
- `access_token`: a typed issued `AccessToken` for immediate approval.

`GrantResponse.pending?/1` and `approved?/1` report the typed branch shape. They
do not revalidate modified nested data; call `validate/1` for that check. Neither
predicate verifies a callback or establishes permission to use a resource.

An accompanying `subject` becomes a typed `Subject`, matching the Node SDK's
grant model and the initial schema's allowance for extra fields. Subject-only
and wait-only results belong to the separate continuation-response contract;
they are rejected by this initial-response codec.

All recognized fields are validated when present, including explicit-null
rejection. This deliberately also rejects malformed `access_token` data beside
an otherwise valid interaction branch, and the reverse, although the schema's
permissive extra fields can allow those cases in the other branch. Other JSON
fields are preserved in `extensions`.

`validate/1` revalidates typed children and branch rules. `to_map/1` and JSON
encoding retain protocol field names and include credentials, callback values,
subject identifiers and any card results. Inspection omits payload values and
errors retain safe nested field paths. Use `Grant.request/3` for grant initiation.

## Grant continuation responses

`OpenPayments.Types.GrantContinuationResponse.from_map/1` decodes a response to
continuing a grant. Required `continue` becomes a typed `Continuation`. Optional
`access_token` and `subject` become typed `AccessToken` and `Subject` data. Either,
both or neither result may be present. Omission becomes nil; explicit null is
rejected for these recognized fields.

Use `has_access_token?/1` and `has_subject?/1` to check typed result presence.
`continuation_only?/1` reports that both recognized result fields are absent.
These predicates do not revalidate modified children, interpret extensions,
verify callbacks or infer server lifecycle state. They do not establish resource
authorization. No waiting or polling occurs during decoding.

Additional JSON fields are preserved in `extensions`. For this endpoint,
`interact` is an undeclared extension, retained without applying the initial grant
response's interaction branch rules. `validate/1` revalidates every recognized
typed child and extension data. `to_map/1` and JSON encoding include credentials,
subject identifiers and any card results; inspection hides payload values, and
errors retain safe nested field paths. Use `Grant.continue/2,3` for continuation.

## Grant continuation request data

`OpenPayments.Types.GrantContinuationRequest.from_map/1` decodes the JSON payload
for continuing a grant. Optional `interact_ref` is an opaque string; omission
becomes nil and explicit null is rejected. No UUID, length or alphabet rule is
imposed. Other JSON fields are retained in `extensions`, including camel-case
`interactRef`, which is treated as an extension rather than an alias.

The shared schema permits an empty object, which this codec accepts. Node's
TypeScript body type requires the reference when a body is supplied. An empty
Elixir struct exports as `{}`; `from_map(nil)` is invalid. Omitting an HTTP body
is a separate choice supported by `Grant.continue/2,3`.

`validate/1` revalidates modified structs. `to_map/1` and JSON encoding export
the reference and extension values; inspection hides them and errors retain safe
field names. This codec does not verify a callback hash, generate a reference,
wait, poll or send a request. Use `Grant.continue/2,3` for continuation.

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
this current schema; `IncomingPayment.get/3` reads authenticated details separately.

## Authenticated incoming-payment reads

Read the complete resource URL with an authenticated client and a per-call token:

```elixir
{:ok, payment} =
  OpenPayments.IncomingPayment.get(client, incoming_payment_url,
    access_token: issued_token
  )

payment.wallet_address
payment.methods
```

`access_token` is required and accepts an opaque token string or an
`OpenPayments.Types.AccessToken` struct. Typed tokens are revalidated before using
their value; a typed continuation credential is rejected. Opaque strings follow
Node's token input style, with token68 header validation. The server checks token
role, permissions, expiry and key binding. The SDK does not infer permission from
access metadata or track elapsed expiry. Unsupported or duplicate options fail
before HTTP; per-call key/header overrides are not accepted.

The operation signs a GET with GNAP authorization and no request body. Supply the
full resource URL; no path is appended or inferred. HTTPS ports and queries are
allowed, and HTTP requires explicit development opt-in on the client. Requests
are not cached, redirected or automatically retried, and failures never trigger
automatic token refresh. Public reads remain unsigned through `get_public/2`.

HTTP 200 returns `{:ok, %OpenPayments.Types.IncomingPaymentWithMethods{}}`.
Authenticated reads require the detailed response branch, including
`walletAddress` and typed `methods`, although the shared GET schema also permits
a public branch for unsigned reads. There is no fallback to public data in this
operation. This is stricter context selection than Node's shared response validator.

Following Node's authenticated payment check, a present `incomingAmount` must
share the `receivedAmount` asset code and scale. Schema or asset inconsistencies
return `kind: :decoding`, `code: "invalid_response"` and HTTP status 200; the field
path identifies the invalid data without echoing values. Errors use
`operation: :get_incoming_payment` and otherwise retain configuration, validation,
signing, HTTP or transport kinds. Amount values, timestamps, the requested URL and
token metadata are not compared for equality with the returned resource.

Inspection hides shared secrets, metadata and extensions; explicit map/JSON
exports include them. Listing uses `IncomingPayment.list/4` below.
Live signed-provider testing remains pending.

## Creating incoming payments

Use the wallet's discovered resource-server base URL and an authenticated client
with an access token authorized to create incoming payments:

```elixir
{:ok, amount} = OpenPayments.Types.Amount.new("2500", wallet.asset_code, wallet.asset_scale)

request = %OpenPayments.Types.CreateIncomingPayment{
  wallet_address: wallet.id,
  incoming_amount: amount,
  metadata: %{"externalRef" => "invoice-1"}
}

{:ok, payment} =
  OpenPayments.IncomingPayment.create(client, wallet.resource_server, request,
    access_token: issued_token
  )

payment.id
payment.methods
```

The payload also accepts a string-keyed protocol map. Typed payloads and nested
amounts are revalidated before HTTP. `walletAddress` is required; optional amount,
expiry and metadata follow the strict creation payload described below. Omitted
values stay omitted, and empty metadata is retained. No wallet discovery request
is added and payment pointers are not converted inside the payload. The server
enforces wallet asset compatibility and grant permissions.

The SDK appends `/incoming-payments` to the resource-server base, preserves tenant
paths and reuses an existing trailing slash. Supply a base URL rather than a
collection or individual payment URL. Queries, including an empty `?`, are
rejected before HTTP, as are user-info and fragments. HTTPS ports are accepted;
HTTP requires explicit development opt-in. Compared with Node's direct string
concatenation, trailing slashes are handled explicitly and query-bearing bases
are rejected to prevent appending the collection path into a query.

The POST signs the exact JSON bytes and GNAP authorization. `access_token` uses
the same string/typed token and strict option rules as authenticated reads.
HTTP 201 returns `{:ok, %OpenPayments.Types.IncomingPaymentWithMethods{}}`.
Following Node's creation checks, received funds must be numerically zero
(including leading-zero decimal strings), `completed` must be false, and a present
incoming amount must share the received amount's asset code and scale. Invalid
success responses return `kind: :decoding`, `code: "invalid_response"` and status
201. Errors carry `operation: :create_incoming_payment` and safe field paths.
No request/response identity, amount or expiry equality check is added.

Creation does not follow redirects, refresh tokens or retry automatically.
A timeout or dropped connection can occur after the server creates a payment;
the caller decides how to reconcile that outcome. Inspection hides returned ILP
shared secrets; explicit map/JSON exports include them. Live signed-provider
testing remains pending.

## Completing incoming payments

Mark an incoming payment complete with an authenticated client and a token
authorized to complete it:

```elixir
{:ok, completed_payment} =
  OpenPayments.IncomingPayment.complete(client, payment.id,
    access_token: issued_token
  )

completed_payment.completed # true
```

Supply the full payment URL. The SDK appends `/complete`, preserving its path and
reusing a trailing slash. As with collection creation, queries (including an empty
`?`), user-info and fragments are rejected before HTTP. HTTPS ports are supported;
HTTP requires explicit development opt-in. The operation sends a signed POST with
GNAP authorization and no body or content headers, matching Node. The required
`access_token` option accepts the same raw string or typed `AccessToken` as reads
and creation; other or duplicate options are invalid.

HTTP 200 returns `{:ok, %OpenPayments.Types.IncomingPayment{}}`. Following Node's
completion checks, `completed` must be true and a present incoming amount must
share the received amount's asset code and scale. Partial and zero receipts are
accepted: completion does not require the full incoming amount to have arrived.
The server checks permissions, expiry and completion eligibility. The SDK does
not compare returned identity or timestamps with local state.

The response uses detailed payment fields without payment methods. Unknown
top-level fields, including `methods` and `authServer`, are rejected; arbitrary
metadata and permitted nested amount extensions remain allowed. This interprets
the pinned endpoint's `additionalProperties: false` over the combined detailed
fields. Its literal placement beside a reference to an `allOf` schema would
reject even the bundled example, because `additionalProperties` only recognizes
properties declared in the same schema. See the
[JSON Schema explanation](https://json-schema.org/understanding-json-schema/reference/object#extending-closed-schemas).
The SDK applies the combined-field restriction explicitly; the standalone detailed
codec continues preserving extensions. Node's completion postconditions are
matched, while its dereferencing/validator behavior for this schema edge has not
been executed here. PHP and Go expose a with-methods result for completion; this
SDK follows the pinned response shape and Node's detailed return type.

Invalid success data returns `kind: :decoding`, `code: "invalid_response"`, status
200 and safe field paths; errors carry `operation: :complete_incoming_payment`.
Failures do not trigger automatic retries, redirects, token refresh or readback.
A timeout can follow server-side completion; the caller decides how to reconcile
the result. Local tests cover create → complete → read with fresh state. Live
signed-provider testing remains pending.

## Listing incoming payments

Fetch one page with the discovered resource-server base URL, the wallet ID to
filter by, and an authenticated client/token authorized to list its payments:

```elixir
{:ok, page} =
  OpenPayments.IncomingPayment.list(client, wallet.resource_server, wallet.id,
    access_token: issued_token,
    pagination: %OpenPayments.Types.Pagination{first: 25}
  )

page.result
page.pagination.has_next_page
page.pagination.end_cursor
```

`access_token` is required and accepts a raw token string or typed `AccessToken`.
Optional `pagination` accepts a typed `Pagination` or a string-keyed protocol map,
such as `%{"last" => 25, "cursor" => cursor}`. Typed values are revalidated before
HTTP. Omit `pagination`, or pass an empty struct/map, to leave count and cursor
defaults to the server. Explicit nil, duplicate options, unsupported options and
per-call key/header overrides are invalid.

Call `list/4` again to fetch another page. For forward traversal, use `first` and
the returned `end_cursor`; for backward traversal, use `last` and `start_cursor`.
The SDK returns the server's flags/cursors without assuming they are present or
consistent with result counts. It does not traverse pages automatically, follow
extension links, cache responses, refresh tokens, follow redirects or retry.
Each explicit call may use a fresh token and independent wallet/pagination data.

The wallet filter is a required UTF-8 string, matching the pinned query schema.
Use the discovered wallet ID for ordinary requests. This filter does not apply
wallet-discovery URI rules, resolve payment pointers or substitute client identity.
Schema-valid strings, including an empty string, are encoded and sent explicitly;
the server checks their meaning and access permissions. This differs from Node's
generic truthy-value query filter, which silently omits an empty wallet string.

The SDK appends `/incoming-payments` to the resource-server base, preserving tenant
paths and reusing a trailing slash. Base queries (including an empty `?`), user-info
and fragments are rejected. HTTPS ports are supported; HTTP requires development
opt-in. The request signs the final encoded query target with GNAP authorization,
no body and no content headers. Form encoding matches Node's `URLSearchParams`,
including space as `+`, literal plus as `%2B`, `~` as `%7E`, and literal `*`.
Keys use a stable wallet-address-first order with sorted pagination fields; source
cursor/filter strings are encoded once without decoding their percent sequences.

HTTP 200 returns `{:ok, %OpenPayments.Types.IncomingPaymentPaginationResult{}}`.
Every item's incoming amount, when present, must match its received amount's
asset code and scale, following Node. Schema or consistency failures return
`kind: :decoding`, `code: "invalid_response"`, status 200 and safe indexed fields
such as `result[1].incoming_amount`. Errors carry `operation: :list_incoming_payments`.
The typed page contract requires pagination/result and the documented detailed
item fields; methods are excluded. Other amount/time/identity/page-size comparisons
are not inferred. Explicit exports include cursors, metadata and wrapper extensions;
inspection omits the page payload. Live signed-provider testing remains pending.

## Reading quotes

Read a quote using an authenticated client and an access token authorized to
read that resource:

```elixir
{:ok, quote} =
  OpenPayments.Quote.get(client, quote_url,
    access_token: issued_token
  )

quote.debit_amount
quote.receive_amount
```

Supply the complete quote URL. No path is appended or inferred; opaque paths,
queries and nondefault HTTPS ports are preserved under the existing request URL
rules. HTTP requires explicit development opt-in. The operation signs a GET with
GNAP authorization, no body and no content headers. There is no wallet, JWKS or
receiver lookup, caching, redirect, retry or automatic token refresh.

The required `access_token` option accepts an opaque token string or typed
`Types.AccessToken`. Typed tokens are revalidated and token68 header rules apply;
typed continuation credentials and unsupported/duplicate options are rejected.
Per-call key/header overrides are invalid. The server checks permissions, expiry
and key binding; the SDK does not infer authorization from token metadata.

HTTP 200 returns `{:ok, %OpenPayments.Types.Quote{}}` with both typed amounts.
Following Node's quote read, only response shape is validated: different assets,
zero values and the schema's plain string expiry remain permitted. No FX/fee,
value-order, clock or request/response identity comparison is added. Strict
fields and the documented standalone-example discrepancies follow the quote
codec below. Schema failures return `kind: :decoding`, `code: "invalid_response"`,
status 200 and safe paths such as `receive_amount.asset_scale`. Errors carry
`operation: :get_quote`; HTTP and transport failures retain their own kinds.

Inspection omits wallet, receiver, amounts and expiry; explicit map/JSON exports
include them. Creation uses `Quote.create/4` below. Live signed-provider testing
remains pending.

## Creating quotes

Create a quote using the sender wallet's resource-server base URL and an
authenticated client/token authorized to create quotes:

```elixir
request = %OpenPayments.Types.CreateQuote{
  wallet_address: wallet.id,
  receiver: incoming_payment.id,
  method: "ilp"
}

{:ok, quote} =
  OpenPayments.Quote.create(client, wallet.resource_server, request,
    access_token: issued_token
  )

quote.debit_amount
quote.receive_amount
```

This example leaves the amount to the receiver's incoming amount. For other
variants, supply a typed `debit_amount` or `receive_amount`, never both.
The payload also accepts a string-keyed protocol map. All payloads and nested
typed amounts are validated before HTTP. The server checks that an amountless
receiver supplies an amount, relevant asset compatibility and permissions. The
SDK makes no wallet/receiver lookup or amount inference, and applies no defaults.
A schema-valid payload can still receive HTTP 400 if no receiver amount is available.

The SDK appends `/quotes` to the resource-server base, preserving tenant paths
and reusing an existing trailing slash. Supply a base URL, rather than a collection
or quote URL. Base queries, including an empty `?`, user-info and fragments are
rejected. HTTPS ports are accepted; HTTP requires explicit development opt-in.
These path rules match incoming-payment collection creation and handle trailing
slashes explicitly, unlike Node's direct string concatenation.

The POST signs the exact JSON bytes and GNAP authorization. The required
`access_token` option uses the same string/typed token and strict option rules as
reads. HTTP 201 returns `{:ok, %OpenPayments.Types.Quote{}}`; other success statuses
are decoding errors, following the pinned create operation's status contract.
The strict response codec is shared with reads. Following Node, no extra FX,
fee, amount-order, positivity, local-expiry or request/response equality rule is
added. Schema failures return `kind: :decoding`, `code: "invalid_response"`, status
201 and safe field paths. Errors carry `operation: :create_quote`.

Creation does not send an outgoing payment, follow redirects, retry, refresh
tokens, cache or automatically read back the resource. A timeout or dropped
connection may occur after quote creation; the caller decides how to reconcile
the outcome. Use `Quote.get/3` explicitly to read a returned quote ID. Inspection
omits wallet/receiver/amount/expiry data; explicit exports include it. Live
signed-provider testing remains pending.

## Reading an outgoing payment

Use the authenticated client, the complete resource URL and a per-call token:

```elixir
{:ok, payment} =
  OpenPayments.OutgoingPayment.get(client, outgoing_payment_url,
    access_token: "issued-access-token"
  )

payment.debit_amount
payment.receive_amount
payment.sent_amount
```

The token may be a raw string or `OpenPayments.Types.AccessToken`. Typed tokens
are revalidated before their value is used; continuation credentials cannot
substitute. The call accepts only one `access_token` option. The server checks
permissions, expiry and key binding; the SDK does not infer them from token
metadata or store tokens on the client.

Sends one signed bodyless GNAP GET to the complete URL. Paths and queries remain
opaque, no path is appended and no related wallet/quote/receiver is fetched.
Nondefault HTTPS ports are supported; HTTP requires client opt-in. Request-target
and token68 rules apply. HTTP 200 returns `Types.OutgoingPayment`; other success
statuses are rejected. All errors carry `operation: :get_outgoing_payment`.

After schema validation, the SDK applies Node's outgoing-payment checks:

- Debit and sent amounts must use the same asset code and scale.
- Sent value cannot exceed debit value, compared numerically with exact integers.
- Identical debit/sent value strings cannot accompany `failed: true`.

The last rule deliberately follows Node's original-string comparison: `"0005"`
and `"5"` are numerically equal but are distinct strings for that failure check.
Their spelling is preserved. Receive assets may differ, and omitted `failed`
remains nil. No positivity, completion-state, fee/FX or response/request identity
rule is inferred.

Schema and consistency errors return `kind: :decoding`, `code: "invalid_response"`,
status 200 and safe paths such as `sent_amount` or `sent_amount.value`. Inspection
hides amounts, metadata and related references; explicit exports include them.
The call makes no payment and does not cache, poll, refresh tokens, follow
redirects or retry after HTTP/transport failures. Live signed-provider testing
remains pending. Use `OutgoingPayment.get_grant_spent_amounts/3` below for
standalone grant spending.

## Creating an outgoing payment

Use either a quote-based or direct incoming-payment request with an authenticated
client and a per-call token:

```elixir
request = %OpenPayments.Types.CreateOutgoingPayment{
  wallet_address: wallet.id,
  quote_id: quote.id,
  metadata: %{"externalRef" => "INV-12876"}
}

{:ok, payment} =
  OpenPayments.OutgoingPayment.create(client, wallet.resource_server, request,
    access_token: "issued-access-token"
  )

payment.sent_amount
payment.grant_spent_debit_amount
payment.grant_spent_receive_amount
```

A direct request instead supplies `incoming_payment` and a typed `debit_amount`.
String-keyed protocol maps are also accepted. Both forms are validated before
HTTP; mixed/incomplete forms, explicit nulls and undeclared request fields are
rejected. See `Types.CreateOutgoingPayment` below for both payload examples. The
server checks quote validity, wallet asset compatibility, permissions and key
binding. No related resource is fetched and no amount is inferred.

The SDK appends `/outgoing-payments` to the resource-server base, preserving tenant
paths and reusing a trailing slash. Base queries, including an empty query marker,
are rejected. The same raw/typed token, strict per-call option and URL policies
as `OutgoingPayment.get/3` apply. One GNAP POST signs the exact encoded JSON bytes,
target and authorization.

HTTP 201 returns `Types.OutgoingPaymentWithSpentAmounts`, with optional typed
grant spent amounts and permitted JSON extensions. The same debit/sent asset,
numeric cap and original-string failure checks used by reads apply here. A
creation response can already reflect sent funds or a failure; no zero-sent,
failed-false, request/response identity or amount equality rule is added. Grant
spent amounts are preserved without comparing them to this payment or a local
budget. HTTP 200 and other unexpected success statuses are rejected.

All errors carry `operation: :create_outgoing_payment`; invalid success data
returns `kind: :decoding`, `code: "invalid_response"`, status 201 and safe field
paths. Inspection hides amounts, related references, metadata and extensions;
explicit exports include them.

Creating the resource authorizes payment processing by the server. The SDK makes
no second send request and does not retry, follow redirects, refresh a token,
poll or read back automatically. A timeout, dropped connection or invalid response
may occur after the server has created or started the payment. The caller must
decide how to reconcile that outcome before another creation attempt. Use
`OutgoingPayment.get/3` explicitly to read a returned resource ID; reads return
the separate detailed type. Live signed-provider testing remains pending.

## Listing outgoing payments

Use the authenticated client, resource-server base, wallet filter and per-call
token. Pagination is optional and accepts either a typed struct or protocol map:

```elixir
{:ok, page} =
  OpenPayments.OutgoingPayment.list(client, wallet.resource_server, wallet.id,
    access_token: "issued-access-token",
    pagination: %OpenPayments.Types.Pagination{first: 25}
  )

page.result
page.pagination.has_next_page
page.pagination.end_cursor
```

The SDK signs one bodyless GNAP GET to the base's `/outgoing-payments` collection,
preserving tenant paths and reusing a trailing slash. Base queries are rejected.
It shares incoming-payment listing's strict token/options, pagination validation
and Node-compatible form encoding: wallet-address first, then sorted pagination
keys, with the whole query encoded before signing. Counts/cursors are sent only
when supplied. Duplicate/unsupported options and explicit nil pagination are
invalid. Raw and typed issued access tokens are accepted; server permissions,
expiry and key binding remain server checks.

The wallet filter follows the pinned required-string query schema, without URI
validation, pointer resolution or substitution of client identity. Every UTF-8
string, including empty, is sent. The SDK preserves an empty wallet-address query
value, unlike Node's truthy-value omission. Usually supply the discovered wallet
ID; the server decides filter meaning and permissions.

HTTP 200 returns `Types.OutgoingPaymentPaginationResult`, with typed page metadata
and detailed outgoing payments. Each item receives the same ordered Node asset,
numeric cap and original-string failure checks as reads. Invalid schema or
consistency data returns decoding/invalid_response/status200 with safe indexed
paths such as `result[1].sent_amount`. All errors carry
`operation: :list_outgoing_payments`. Spent amounts belong to creation responses
and are not accepted as list item fields.

For a next page, explicitly call with `first` and the returned end cursor; for a
previous page, call with `last` and the start cursor. The SDK does not traverse,
follow returned links, infer ordering or page counts, compare filter/result wallet
identities, cache, retry, redirect or refresh tokens. Empty pages, duplicate
items and independent page metadata are retained. Inspection hides payloads;
explicit exports include cursors, references, amounts, metadata and extensions.
Live signed-provider testing remains pending.

## Outgoing-payment response data

`OpenPayments.Types.OutgoingPayment` models the detailed read/list response:

```elixir
{:ok, payment} = OpenPayments.Types.OutgoingPayment.from_map(%{
  "id" => "https://resource.example.com/outgoing-payments/payment-1",
  "walletAddress" => "https://wallet.example.com/alice",
  "receiver" => "https://receiver.example.com/incoming-payments/payment-1",
  "debitAmount" => %{"value" => "2500", "assetCode" => "USD", "assetScale" => 2},
  "receiveAmount" => %{"value" => "2198", "assetCode" => "EUR", "assetScale" => 2},
  "sentAmount" => %{"value" => "1205", "assetCode" => "USD", "assetScale" => 2},
  "failed" => false,
  "createdAt" => "2026-11-18T09:20:50Z"
})

payment.debit_amount
payment.receive_amount
payment.sent_amount
:ok = OpenPayments.Types.OutgoingPayment.validate(payment)
```

ID, wallet, receiver, all three amounts and creation time are required, without
defaults. Optional `quoteId`, `failed` and JSON-object metadata become `quote_id`,
`failed` and `metadata`. Omission becomes nil and is omitted on export; explicit
null is invalid. An explicit `false` and empty metadata object are preserved.
The schema's `failed: false` default does not insert a value when absent. This
follows its required-field list; Node's generated TypeScript type instead marks
`failed` as required because of the default.

ID, wallet and quote fields use absolute-URI data validation; receiver uses the
shared HTTP(S) incoming-payment URI pattern. Spelling is retained, without
payment-pointer resolution or request-target restrictions. Creation time uses
RFC 3339, preserving offsets and precision. Amount decimal spelling, permitted
nested amount extensions and JSON metadata are retained. Additional top-level
fields, including `updatedAt`, aliases and grant spent amounts, are rejected.
The creation response uses `OpenPayments.Types.OutgoingPaymentWithSpentAmounts`
below.

The official read/list examples round-trip unchanged. One standalone schema
example omits required `receiveAmount` and has a receiver outside the declared
pattern; tests reject it without repairing the bundled specification.

This codec does not compare sent/debit assets, amount values or failure status,
infer completion, enforce positivity, or calculate fees/exchange rates. Node's
additional payment consistency checks run in `OutgoingPayment.get/3`, separately
from this type. The type makes no requests. `validate/1` checks modified
structs and all nested amounts; `to_map/1` and JSON encoding export without
validation. Inspection shows only ID, failure status and creation time. Explicit
exports include wallet, receiver, quote, amounts and metadata; errors contain
safe paths such as `sent_amount.value`, without rejected data or unknown names.

## Outgoing-payment creation request data

`OpenPayments.Types.CreateOutgoingPayment` models both creation request forms:

```elixir
from_quote = %OpenPayments.Types.CreateOutgoingPayment{
  wallet_address: "https://wallet.example.com/alice",
  quote_id: "https://resource.example.com/quotes/quote-1"
}

{:ok, amount} = OpenPayments.Types.Amount.from_map(%{
  "value" => "2500", "assetCode" => "USD", "assetScale" => 2
})

from_incoming = %OpenPayments.Types.CreateOutgoingPayment{
  wallet_address: "https://wallet.example.com/alice",
  incoming_payment: "https://receiver.example.com/incoming-payments/payment-1",
  debit_amount: amount,
  metadata: %{"externalRef" => "INV-12876"}
}

:ok = OpenPayments.Types.CreateOutgoingPayment.validate(from_quote)
:ok = OpenPayments.Types.CreateOutgoingPayment.validate(from_incoming)
```

Supply `walletAddress` and either `quoteId`, or both `incomingPayment` and
`debitAmount` in protocol maps passed to `from_map/1`. These forms are mutually
exclusive, matching the pinned `oneOf` branches and Node's creation argument
union. Missing references/amounts and mixed forms are rejected. Map field presence
selects the form: adding an inactive field with null is invalid. Typed nil means
omission; a direct incoming-payment request still requires its debit amount.

All three URI fields use absolute-URI data validation and retain their spelling.
The request's `incomingPayment` has no incoming-payment path pattern in the pinned
schema, unlike response `receiver` fields. This codec does not resolve payment
pointers, impose request-target policies on URI data, fetch related resources or
infer amounts. The server checks quote validity, authorization and debit-asset
compatibility with the sending wallet. Zero amounts remain schema-valid; no
positivity, fee or exchange-rate rule is added here.

Optional metadata must be a JSON object; omission becomes nil and empty objects
are retained. Explicit nulls and undeclared top-level fields, including response
fields and snake_case JSON aliases, are rejected. Typed debit amounts preserve
decimal spelling and permitted nested extensions. `validate/1` revalidates the
form, fields and nested amount after manual edits. `to_map/1` and JSON encoding
export without validation, defaults or lookups.

Inspection hides all payload fields. Explicit exports include wallet, quote or
incoming-payment references, amount and metadata; errors contain safe paths such
as `debit_amount.value`, without rejected values or unknown names. This type makes
no requests or payments. Use `OutgoingPayment.create/4` to create a payment and
`OutgoingPayment.get/3` to read an existing one.

## Outgoing-payment creation response data

`OpenPayments.Types.OutgoingPaymentWithSpentAmounts` models the HTTP 201 creation
response. It has the same flat detail fields as `Types.OutgoingPayment`, plus
optional typed `grant_spent_debit_amount` and `grant_spent_receive_amount`:

```elixir
{:ok, payment} = OpenPayments.Types.OutgoingPaymentWithSpentAmounts.from_map(%{
  "id" => "https://resource.example.com/outgoing-payments/payment-1",
  "walletAddress" => "https://wallet.example.com/alice",
  "receiver" => "https://receiver.example.com/incoming-payments/payment-1",
  "debitAmount" => %{"value" => "2500", "assetCode" => "USD", "assetScale" => 2},
  "receiveAmount" => %{"value" => "2198", "assetCode" => "EUR", "assetScale" => 2},
  "sentAmount" => %{"value" => "0", "assetCode" => "USD", "assetScale" => 2},
  "grantSpentDebitAmount" => %{"value" => "7500", "assetCode" => "USD", "assetScale" => 2},
  "failed" => false,
  "createdAt" => "2026-11-18T09:20:50Z"
})

payment.grant_spent_debit_amount
payment.grant_spent_receive_amount # nil when omitted
:ok = OpenPayments.Types.OutgoingPaymentWithSpentAmounts.validate(payment)
```

Either, both or neither spent amount may appear. Omitted values become nil and
are omitted on export; explicit null is invalid. These fields describe spending
under the current grant and need not equal this payment's amounts. This differs
from the separate grant-spent endpoint, whose fields are required and nullable.

Shared payment fields use the same validation and spelling preservation as the
read/list codec, including omission versus explicit false, optional quote URI and
JSON-object metadata. The creation-response schema permits additional JSON fields,
which remain in `extensions`; the read/list schema forbids them. For example,
an undeclared `updatedAt` is retained as uninterpreted extension data here.
Extensions cannot override declared protocol fields, even after manual edits.

`validate/1` revalidates shared fields, all typed amounts and extensions;
`to_map/1` and JSON encoding export protocol data without validation. Inspection
shows only ID, failure status and creation time; explicit exports include all
amounts, wallet, receiver, quote, metadata and extensions. Errors retain safe
paths such as `grant_spent_debit_amount.value`, without rejected data or unknown
names. The codec does not compare grant limits, assets, values or failure status,
track grant spending, or make requests/payments. `OutgoingPayment.create/4` returns
this type; `OutgoingPayment.get/3` reads existing payments into the separate
detailed type.

## Reading outgoing-grant spent amounts

Use the authenticated client, resource-server base and current per-call token:

```elixir
{:ok, spent} =
  OpenPayments.OutgoingPayment.get_grant_spent_amounts(client, wallet.resource_server,
    access_token: "issued-access-token"
  )

spent.spent_receive_amount
spent.spent_debit_amount
```

The SDK appends `/outgoing-payment-grant` to the base, preserving tenant paths and
reusing a trailing slash. Base queries, including an empty marker, are rejected.
It sends one signed bodyless GNAP GET, without a wallet filter, grant ID or
pagination. The same raw/typed token, strict per-call option and request URL rules
as `OutgoingPayment.get/3` apply. Use the resource-server base from discovery;
the token's management URL does not determine this endpoint.

HTTP 200 returns `Types.OutgoingPaymentGrantSpentAmounts`. Both amount fields
are required, each independently typed `Amount` or nil for explicit JSON null.
Permitted JSON extensions and decimal spelling are retained. The server selects
the grant and current recurring interval associated with the token. The SDK does
not replace null with zero, infer grant existence or remaining funds, compare
assets/values, compute interval boundaries or enforce monotonic totals. Spending
can decrease between calls, for example when the server reports a new interval.

All errors carry `operation: :get_outgoing_payment_grant`. Invalid success data
returns decoding/invalid_response/status200 with safe paths such as
`spent_debit_amount.value`; other success statuses are rejected. Inspection hides
payloads, while explicit exports include amounts, extensions and required nulls.

Calls do not fetch related resources, cache, poll, refresh tokens, follow
redirects or retry. Supply the latest token after any explicit rotation and make
each subsequent read explicitly. This call creates no payment and tracks no grant
state. Live signed-provider testing remains pending.

## Outgoing-grant spent-amount data

`OpenPayments.Types.OutgoingPaymentGrantSpentAmounts` models the standalone
grant-spent endpoint's response:

```elixir
{:ok, spent} = OpenPayments.Types.OutgoingPaymentGrantSpentAmounts.from_map(%{
  "spentReceiveAmount" => nil,
  "spentDebitAmount" => %{"value" => "2500", "assetCode" => "USD", "assetScale" => 2}
})

spent.spent_receive_amount # nil represents explicit JSON null
spent.spent_debit_amount
:ok = OpenPayments.Types.OutgoingPaymentGrantSpentAmounts.validate(spent)
```

Both protocol fields are required, matching the pinned schema and Node's response
type. Each independently accepts a typed `Amount` or null; missing fields are
invalid. In typed structs both fields must be supplied, and nil means explicit
null. Both fields are always exported, including nulls. This differs from the
optional, nonnullable `grantSpentReceiveAmount` and `grantSpentDebitAmount` on
outgoing-payment creation responses.

Null remains distinct from a zero-valued amount. The codec does not infer grant
existence, budget, interval boundaries or remaining funds, compare assets/values,
or replace null with zero. For a recurring grant the server reports the current
interval's spending for the presented token. No grant state is tracked locally.

Amount decimal spelling, asset data and permitted nested extensions are retained.
Additional JSON fields at the response root remain uninterpreted `extensions`;
they cannot override the two declared fields. `validate/1` revalidates nullable
typed children and extensions. `to_map/1` and JSON encoding export without
validation and retain required nulls.

Inspection hides the entire payload. Explicit exports include amounts and
extensions; errors retain safe paths such as `spent_debit_amount.value`, without
rejected values or unknown names. This type makes no requests or payments. The
signed `OutgoingPayment.get_grant_spent_amounts/3` operation returns this type.

## Quote response data

`OpenPayments.Types.Quote` models the strict quote response used by GET and create:

```elixir
{:ok, quote} = OpenPayments.Types.Quote.from_map(%{
  "id" => "https://resource.example.com/quotes/quote-1",
  "walletAddress" => "https://wallet.example.com/alice",
  "receiver" => "https://receiver.example.com/incoming-payments/payment-1",
  "debitAmount" => %{"value" => "2500", "assetCode" => "USD", "assetScale" => 2},
  "receiveAmount" => %{"value" => "2198", "assetCode" => "EUR", "assetScale" => 2},
  "method" => "ilp",
  "createdAt" => "2026-11-18T09:20:50Z"
})

quote.debit_amount
quote.receive_amount
```

Required fields are `id`, `walletAddress`, `receiver`, `debitAmount`, `receiveAmount`,
`method` and `createdAt`. Both amounts become typed `Amount` structs. The response
requires both amounts, unlike creation-request variants. The current method is
the string `"ilp"`; no method or amount defaults are supplied.

ID and wallet fields use the schema's absolute-URI data format. Receiver follows
the HTTP(S) incoming-payment URI pattern, preserving its spelling. These data
fields do not use discovery/request-target restrictions or resolve payment pointers.
`createdAt` is an RFC 3339 timestamp. Optional `expiresAt` is a plain string in the
pinned schema, without a date-time format; it is preserved without timestamp or
clock validation. Omission becomes nil and is omitted on export; explicit null
and nonstring expiry values are invalid. This differs from the reviewed Rust
model's timestamp type for expiry and follows the pinned schema/Node string type.

Additional top-level fields, including `sentAmount`, metadata and JSON aliases,
are rejected. Permitted nested amount extensions are retained. The bundled
standalone quote examples include undeclared `sentAmount`, and one also omits
required `receiveAmount`; tests reject them explicitly. The valid GET/create
response examples pass unchanged. The SDK does not repair the bundled source or
silently drop incompatible fields.

Debit and receive assets may differ. No exchange-rate, fee, amount-order,
positivity or time-consistency rule is inferred. `validate/1` revalidates modified
structs and both nested amounts; `to_map/1` and JSON encoding export protocol data
without validating. Inspection shows only ID, method and creation time; explicit
exports include wallet, receiver, amounts and expiry. Errors retain safe paths
such as `receive_amount.asset_scale`, without rejected values or unknown names.
This type makes no requests or payments. `Quote.get/3` and `Quote.create/4` return
it after signed requests. Creation payloads use `Types.CreateQuote` below.

## Quote creation request data

`OpenPayments.Types.CreateQuote` models all three creation payload variants:

```elixir
{:ok, amount} = OpenPayments.Types.Amount.new("2500", wallet.asset_code, wallet.asset_scale)

request = %OpenPayments.Types.CreateQuote{
  wallet_address: wallet.id,
  receiver: incoming_payment.id,
  method: "ilp",
  debit_amount: amount
}

:ok = OpenPayments.Types.CreateQuote.validate(request)
```

Required fields are `wallet_address`, `receiver` and the explicit method `"ilp"`.
Use `debit_amount` for a fixed-debit quote, `receive_amount` for a fixed-receive
quote, or omit both to infer the amount from the receiver's incoming payment.
The server must check that an amountless receiver has an incoming amount; this
codec makes no lookup or inference from the URL. Both amounts together are
invalid, matching the shared specification's three closed `oneOf` branches and
Node's `CreateQuoteArgs` union.

`from_map/1` uses protocol fields `walletAddress`, `receiver`, `method`,
`debitAmount` and `receiveAmount`. Omitted amounts become nil and are omitted on
export; typed nil means omission, while explicit JSON null is invalid. Each
present amount is a typed `Amount`, with its decimal spelling and permitted
extensions retained. Top-level extras, metadata, response-only fields and
snake-case JSON aliases are rejected. No method or amount defaults are supplied.

The wallet uses the schema's absolute-URI data format and the receiver uses the
HTTP(S) incoming-payment URI pattern, preserving spelling without discovery
restrictions or payment-pointer conversion. Wallet/receiver asset compatibility,
permissions and receiver-amount availability need server context. The codec
does not require positive amounts or calculate exchange rates and fees.

Call `validate/1` after constructing or modifying a struct; it revalidates the
variant and nested amount. `to_map/1` and JSON encoding export protocol fields
without validating. Inspection shows only the method; explicit exports include
wallet, receiver and amount data. Errors retain safe paths such as
`debit_amount.value` without rejected values or unknown names. This type makes
no HTTP requests. Use `Quote.create/4` to create a quote and `Quote.get/3` to read it.

## Pagination query arguments

`OpenPayments.Types.Pagination` models the optional query arguments shared by
payment-list operations:

```elixir
pagination = %OpenPayments.Types.Pagination{first: 25, cursor: "opaque-cursor"}
:ok = OpenPayments.Types.Pagination.validate(pagination)

OpenPayments.Types.Pagination.to_map(pagination)
# => %{"first" => 25, "cursor" => "opaque-cursor"}
```

`from_map/1` accepts only the string keys `first`, `last` and `cursor`. Counts must
be integers from 1 through 100; numeric strings, floats and out-of-range values
are invalid. At most one of `first` and `last` may be supplied, matching Node's
forward/backward pagination union. This exclusivity is an SDK rule beyond the
shared specification's separate parameter constraints.

All fields are optional. `%Pagination{}` or an empty map selects no local page
size or direction default; the server decides its defaults. A cursor may be used
alone. Omitted map fields and typed nil values mean omission; explicit null in a
map is invalid. A present cursor must be a nonempty UTF-8 string, with its spelling
preserved without trimming, decoding or UUID/URL/encoding checks. The wallet filter,
resource-server URL and credentials are separate list-operation inputs.

Call `validate/1` after constructing or modifying a struct. `to_map/1` and JSON
encoding export integer counts and raw cursors without validating or percent
encoding. Inspection shows only counts; explicit exports include cursors, and
errors retain safe field paths without rejected values. This type makes no
requests or automatic page traversal. Incoming-payment pages use
`Types.IncomingPaymentPaginationResult` and `Types.OutgoingPaymentPaginationResult`
below. Pass these arguments through the
`pagination` option on `IncomingPayment.list/4` or `OutgoingPayment.list/4`.

## Pagination metadata

`OpenPayments.Types.PageInfo` models the shared `page-info` schema used by
incoming- and outgoing-payment lists:

```elixir
{:ok, page_info} = OpenPayments.Types.PageInfo.from_map(%{
  "hasNextPage" => true,
  "hasPreviousPage" => false,
  "startCursor" => "opaque-start",
  "endCursor" => "opaque-end"
})

page_info.has_next_page
page_info.end_cursor
```

Both flags are required booleans, with no defaults. Cursors are optional nonempty
UTF-8 strings. Missing cursors become nil and are omitted on export; explicit
JSON null and empty strings are rejected. Extra fields and snake-case JSON aliases
are invalid. Cursor spelling is preserved without UUID, URL or encoding rules.
Either cursor may appear independently, and page flags do not imply that a cursor
must exist. This type does not compare cursors with result items or infer ordering.

Use `validate/1` after modifying a struct. `to_map/1` and JSON encoding export the
protocol fields without validating. Inspection exposes only the flags; explicit
exports include cursors. Errors retain safe field paths without rejected values.
This type makes no requests or automatic page traversal. Query arguments use
`Types.Pagination` above; incoming- and outgoing-payment pages use the result types below.
Listing uses `IncomingPayment.list/4` or `OutgoingPayment.list/4`.

## Outgoing-payment page data

`OpenPayments.Types.OutgoingPaymentPaginationResult` decodes a page into typed
`PageInfo` metadata and an ordered list of detailed `OutgoingPayment` structs:

```elixir
{:ok, page} = OpenPayments.Types.OutgoingPaymentPaginationResult.from_map(%{
  "pagination" => %{"hasNextPage" => false, "hasPreviousPage" => false},
  "result" => []
})

page.pagination.has_next_page
page.result
:ok = OpenPayments.Types.OutgoingPaymentPaginationResult.validate(page)
```

Both wrapper fields are required, following Node's `PaginationResult<T>` contract.
The pinned response declares these properties without marking them required; the
SDK deliberately rejects missing/null fields rather than supplying defaults.
Empty results are valid, and item order and duplicates are preserved.

Each result item uses the strict detailed outgoing-payment schema, with three
typed amounts and optional quote, failure status and metadata. Unknown item fields,
including grant spent amounts and `updatedAt`, are rejected. Creation responses
with spent amounts use their separate type. Permitted nested amount extensions
and JSON metadata are retained; additional JSON fields on the page wrapper remain
in `extensions`. Wrapper extensions cannot override `pagination` or `result`.

The codec does not compare flags or cursors with item IDs, counts or ordering.
It retains schema-valid asset, amount and failure-state combinations; Node's
additional payment consistency checks belong to the HTTP operations. Missing
`failed` stays nil. No wallet identity, completion or grant-spending inference
is performed, and no requests or automatic page traversal occur. The HTTP
operation `OutgoingPayment.list/4` uses this type and applies per-item Node
consistency checks separately.

`validate/1` revalidates typed metadata, each detailed payment and wrapper
extensions; protocol maps or other response structs cannot replace typed children.
Errors retain safe paths such as `result[1].sent_amount.value` and
`pagination.end_cursor`, without rejected values or unknown names. Inspection
hides the entire page payload. Explicit map/JSON exports include cursors,
references, amounts, metadata and extensions without validating.

## Incoming-payment page data

`OpenPayments.Types.IncomingPaymentPaginationResult` decodes a page into typed
`PageInfo` metadata and an ordered list of detailed `IncomingPayment` structs:

```elixir
{:ok, page} = OpenPayments.Types.IncomingPaymentPaginationResult.from_map(%{
  "pagination" => %{"hasNextPage" => false, "hasPreviousPage" => false},
  "result" => []
})

page.pagination.has_next_page
page.result
```

Both `pagination` and `result` are required and cannot be null. Empty result lists
are valid. Requiring both fields matches Node's public `PaginationResult` type;
the pinned list response schema declares the fields without a `required` array,
so this SDK contract is explicitly stricter. Missing fields are never defaulted.

Items follow the combined detailed-field restriction used by completion:
`methods`, `authServer` and other unknown item fields are rejected. This is the
same documented interpretation of `additionalProperties: false` beside an
`allOf` reference; the standalone detailed codec still preserves extensions.
Metadata and permitted nested amount extensions remain arbitrary JSON. The page
wrapper itself preserves extra JSON fields in `extensions`, as its schema permits.

Order and duplicates are preserved. Completed and incomplete items are valid;
the codec does not compare assets, amounts, timestamps, page flags/cursors, item
counts or IDs. Resource operations apply payment consistency checks separately.
Errors use safe indexed paths such as `result[1].received_amount.value` or
`pagination.end_cursor`, without retaining rejected values or unknown field names.

`validate/1` revalidates typed metadata, every typed item and extension data after
manual changes. `to_map/1` and JSON encoding export protocol fields without
validation. Inspection hides the full payload; explicit exports include cursors,
metadata and wrapper extensions. This type makes no requests or automatic page
traversal. `IncomingPayment.list/4` uses this type and applies per-item asset
consistency checks.

## Detailed incoming-payment data

`OpenPayments.Types.IncomingPayment.from_map/1` decodes the detailed
`incoming-payment` schema used by listing and completion:

```elixir
{:ok, payment} = OpenPayments.Types.IncomingPayment.from_map(%{
  "id" => "https://wallet.example.com/incoming-payments/payment-1",
  "walletAddress" => "https://wallet.example.com/alice",
  "completed" => false,
  "receivedAmount" => %{"value" => "0", "assetCode" => "USD", "assetScale" => 2},
  "createdAt" => "2026-11-18T09:20:50Z",
  "metadata" => %{"externalRef" => "invoice-1"}
})

payment.wallet_address
payment.received_amount.value
```

Required fields are `id`, `walletAddress`, `completed`, `receivedAmount` and
`createdAt`. The model does not fill the schema's `completed` default: one bundled
standalone example omits that required field and is explicitly tested as invalid.
All valid list/completion examples round trip unchanged.

Amounts become typed `Amount` structs. Optional `incomingAmount`, `expiresAt` and
JSON-object `metadata` become nil when omitted; explicit null is invalid. Empty
metadata is retained as `{}`. URI and RFC 3339 timestamp spelling, offsets and
fractional precision are preserved. JSON metadata and permitted standalone-schema
extensions round trip without interpreting their application data.

`validate/1` revalidates manually modified structs and nested amounts. `to_map/1`
and JSON encoding retain protocol field names. Inspection omits amounts, metadata
and extension values; explicit exports include them. Errors expose safe field
paths such as `incoming_amount.value`. This codec does not compare asset identities,
amount values or timestamps; Node-style payment consistency checks belong to the
resource operations.

Payment methods are not declared by this detailed schema, so any `methods` field
is retained as an uninterpreted extension. Use `Types.IncomingPaymentWithMethods`
for the authenticated read/create schema, which additionally requires typed
payment methods. `IncomingPayment.get/3` and `IncomingPayment.create/4` use that
variant; `IncomingPayment.complete/3` and items in `IncomingPayment.list/4` return
the detailed type above.

## Incoming-payment data with payment methods

`OpenPayments.Types.IncomingPaymentWithMethods.from_map/1` decodes the
`incoming-payment-with-access-token` response schema used by create and
authenticated reads. Fields remain flat on the struct, including `wallet_address`,
typed amounts, optional metadata and a required `methods` list of typed
`ILPPaymentMethod` structs. Detail validation is shared with `Types.IncomingPayment`.

The methods array may be empty, but omission and explicit null are invalid.
Complete protocol method objects must be unique; their order is preserved.
Malformed entries use indexed paths such as `methods[1].shared_secret` without
retaining rejected values. The current schema supports ILP methods with strict
method fields. `authServer` is not required and is preserved as extension data if
supplied, along with other permitted JSON fields.

`validate/1` revalidates details, typed methods, uniqueness and extensions after
manual changes. `to_map/1` and JSON encoding include shared secrets, metadata and
extensions; inspection omits those values. URI/timestamp spelling and optional
field rules follow the detailed type. The codec makes no requests, connects to
no payment method and performs no asset/amount/time consistency checks.
`Types.CreateIncomingPayment` models the create payload. `IncomingPayment.get/3`
and `IncomingPayment.create/4` return this response type. Completion returns the
detailed type without methods, as do items in incoming-payment list results.

## Incoming-payment create request data

`OpenPayments.Types.CreateIncomingPayment` models the strict
`create-incoming-payment-request` payload:

```elixir
{:ok, amount} = OpenPayments.Types.Amount.new("2500", "USD", 2)
request = %OpenPayments.Types.CreateIncomingPayment{
  wallet_address: "https://wallet.example.com/alice",
  incoming_amount: amount,
  metadata: %{"externalRef" => "invoice-1"}
}

:ok = OpenPayments.Types.CreateIncomingPayment.validate(request)
```

`from_map/1` accepts protocol JSON fields: required `walletAddress` and optional
`incomingAmount`, `expiresAt` and object `metadata`. Amounts become typed structs.
Omitted optionals become nil and are omitted on export; explicit null is invalid.
Extra top-level fields, response-only fields and snake-case wire aliases are
rejected. Metadata may contain arbitrary JSON fields, including an empty object;
permitted nested amount extensions are preserved.

The wallet follows the schema's absolute-URI format, with no payment-pointer
resolution or discovery request. RFC 3339 expiry and URI spelling are preserved;
no positive-amount or future-expiry rule is inferred. The request description
requires the amount's asset to match the wallet's asset; checking that relationship
needs wallet/operation context and is outside this standalone codec.

Use `validate/1` after manual changes. `to_map/1` and JSON encoding export protocol
fields without validating. Inspection exposes only expiry metadata; errors retain
safe paths such as `incoming_amount.asset_scale` without rejected values. The type
makes no requests. Pass the payload to `IncomingPayment.create/4` to create a payment.

## ILP payment methods

`OpenPayments.Types.ILPPaymentMethod.from_map/1` decodes an incoming payment's
`{"type":"ilp","ilpAddress":...,"sharedSecret":...}` method into a struct with
`type`, `ilp_address` and `shared_secret` fields. It validates the shared schema's
ILP address syntax and 1023-character limit, nonempty unpadded base64url secret
alphabet, and prohibition on additional fields. It does not impose a decoded
secret length or establish a STREAM connection.

Inspection omits the shared secret; `to_map/1` and JSON encoding explicitly include
it for protocol use. Treat exported maps and JSON as sensitive. Use `validate/1`
after manually constructing or modifying a struct. `IncomingPayment.get/3` and
`IncomingPayment.create/4` return typed methods; completion returns detailed data
without methods, as do items in incoming-payment list results.

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
no JSON encoder; the seed remains in process memory. Authenticated operations
use these keys with the request-signing pipeline described below.

`OpenPayments.Key.key_id/1` reads the configured identifier. `Key.sign/2` signs
exact binary data and returns raw Ed25519 signature bytes; it does not construct
an HTTP request or send one.

## Development

```sh
mix deps.get
mix check
mix dialyzer
```

After dependencies are installed, `mix test` runs without internet access,
credentials, a database, or an external payment server. External integration tests
are excluded by default.

## Testnet interoperability checks

Run public discovery against a testnet wallet URL or payment pointer:

```sh
export OPEN_PAYMENTS_INTEGRATION_WALLET_ADDRESS='$wallet.example.com/alice'
mix test test/integration/discovery_test.exs --include integration
```

These two checks use real HTTPS requests for wallet information and its JWKS.
They need no private key or access token. Provider URLs come from configuration
and discovery; no hostnames, tenant paths or auth/resource ports are assumed.
The default `mix test` and CI suite exclude all `:integration` tests.

For a signed read, register an Ed25519 public key with the provider and obtain
an issued access token bound to that key with permission to read the selected
resource. Keep the matching unencrypted PKCS#8 PEM private key and the token in
local files outside the checkout. The token file contains only the token value,
with an optional final newline, without a `GNAP`/`Bearer` prefix or JSON wrapper.
Do not use a continuation token or token-management credential.

```sh
export OPEN_PAYMENTS_INTEGRATION_PRIVATE_KEY_FILE='/absolute/path/client-key.pem'
export OPEN_PAYMENTS_INTEGRATION_KEY_ID='provider-registered-key-id'
export OPEN_PAYMENTS_INTEGRATION_ACCESS_TOKEN_FILE='/absolute/path/access-token.txt'
export OPEN_PAYMENTS_INTEGRATION_READ_KIND='incoming'
export OPEN_PAYMENTS_INTEGRATION_RESOURCE_URL='https://resource.example.com/tenant/incoming-payments/existing-id'
mix test test/integration/signed_read_test.exs --include integration
```

`READ_KIND` accepts `incoming`, `quote`, `outgoing` or `grant_spent`. The first
three require the complete existing resource URL. `grant_spent` instead uses the
configured wallet's discovered `resourceServer` and needs no `RESOURCE_URL`;
the token must belong to a grant on that server. Run the check again for each
resource kind and its appropriate token. The configured wallet also identifies
the signing client. The check confirms the local key's ID and public material
appear in that wallet's JWKS before sending the signed read.

Explicitly selected checks fail when configuration is missing or credentials
are rejected. They do not silently skip, follow redirects or automatically retry.
Diagnostics report the operation, error kind and HTTP status without dumping
provider payloads, tokens, key contents or local credential paths. No dotenv
loader or browser automation is used. Provider-specific registration and consent
remain outside the SDK; see [Open Payments client keys](https://openpayments.dev/identity/client-keys/).
The sibling [Go integration suite](https://github.com/interledger/open-payments-go/tree/bedf1cb20940b296ca4a953383fa26488b27b313/test/integration)
also documents a testnet target and its account setup requirements.

These checks only issue GET requests. Successful discovery verifies public
response compatibility; a successful signed read additionally verifies that
provider's acceptance of the configured signature and credential for that
operation. Grant issuance, browser consent, signed request bodies, mutations and
funded settlement require separate live acceptance and are not established by
these checks. The offline complete-flow tests below cover protocol composition
with a simulator.

## Archive consumer verification

Build and verify the package in a separate temporary Mix project:

```sh
elixir scripts/check_package.exs
```

The script builds a local Hex archive, checks its file layout and unpacks only its
contents into the consumer's dependency directory. It resolves runtime dependencies
from the declared constraints with a fresh consumer lockfile and clean production
and test builds. It starts the production application and runs seven smoke tests
for bundled specifications/checksums, dependency isolation, public operations,
consolidated JSON encoders, OTP signing, unsigned discovery and signed requests.
The standalone fixture lives under `scripts/package_consumer/`; the SDK's source
checkout, dependency/build directories and lockfile are not copied into it.

This check is separate from the SDK test suite and runs in the CI runtime matrix.
Dependency installation may need internet access. With all selected package
versions already in the Hex cache, use:

```sh
elixir scripts/check_package.exs --offline
```

The consumer tests use a local adapter with no external provider requests.
Temporary archives, dependencies and build files are removed after the check.

## Complete simulated payment flows

Run the acceptance scenarios independently or as part of the default test suite:

```sh
mix test test/open_payments/payment_flow_test.exs
```

The two normal scenarios use quote-based and direct incoming-payment creation.
Each composes the public APIs through wallet/JWKS discovery, immediate and
interactive grants, independent callback-hash verification, incoming-payment
creation/read/public read, quote creation/read, token rotation, outgoing-payment
creation/read/list, grant spending, incoming completion/list, revocation and grant
cancellation. Each checks an exact 24-request trace covering all 17 pinned HTTP
operations and the separate unsigned incoming-payment read variant. Stale and
revoked tokens are rejected by the simulator. Tests run concurrently with isolated
server state.

The local server independently verifies signed requests against a fixed RFC 8032
public key using received method, target, authorization and exact body bytes. It
checks that public reads remain unsigned. Callback hashes are constructed without
the SDK hash helper; application orchestration only continues after verification.
A separate scenario rejects a mismatched callback before any continuation.

Two failure scenarios record a payment server-side, then drop the connection or
return an invalid creation response. They verify that the SDK does not issue a
second POST; the test application explicitly lists payments and reads grant
spending to reconcile the result.

These are offline protocol-composition tests using loopback HTTP and simulated
state. They perform no real settlement, browser consent or external provider
interoperability check. The server uses the documented Node signing profile;
passing these tests does not establish final-GNAP-profile or live ASE compatibility.

## Compatibility

The SDK supports Elixir 1.17 and later on compatible OTP versions. CI checks
Elixir 1.17 / OTP 26, Elixir 1.19 / OTP 28 and Elixir 1.20 / OTP 29. It implements
all 17 HTTP operations in the bundled Open Payments 1.5.0 specification.

The primary behavioral reference is
[Node SDK 7.4.0](https://github.com/interledger/open-payments-node/tree/8391a1c9e33ee157d918f753f7c06d7ce3e2fd80/packages/open-payments).
Elixir APIs return typed snake_case structs and result tuples. Protocol JSON names
and schema-specific omission/null rules are preserved; operation sections above
document validation and URL-handling differences.

Requests require HTTPS by default and have no automatic retries or redirects.
The [signing profile](#signing-dependency) follows the reviewed Node implementation
and differs from the final GNAP profile. Public testnet discovery has been verified;
live signed requests, consent and funded payments remain unverified here.

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
The transport sends the same bytes used for the digest and signature.

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
public client and wallet discovery, incoming-payment operations, quote operations
and outgoing-payment create/read/list and grant-spent operations.

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
