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
