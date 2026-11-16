# Open Payments Elixir

An Elixir client for the Open Payments wallet address, authorization, and resource
server APIs. Supports Elixir 1.17 and later on compatible Erlang/OTP versions.

The package is under development and has not been published.
Its package/application name is `open_payments_elixir`; Elixir modules use the
`OpenPayments` namespace.

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
policies belongs to the HTTP client, which is still being implemented.

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
The Open Payments request-signing profile and HTTP pipeline are still being built.

## License

Apache-2.0. See the `LICENSE` file.
