defmodule OpenPayments.Types.GrantClient do
  @moduledoc """
  A grant request's client identity, preserving all three protocol forms.

  `from_value/1` accepts a wallet-address string, a `walletAddress` object, or a
  directed-identity `jwk` object. Object forms support optional typed `display`
  information and forbid extra fields. Wallet and JWK identities are mutually
  exclusive. The string form is deprecated by the pinned specification but remains
  supported without silently converting it to an object.

  Wallet values follow the schema's absolute-URI format without normalization or
  payment-pointer resolution. Directed identity contains a public `Types.JWK`;
  it does not import a private signing key. This type does not fetch wallet keys,
  check that a JWK matches the signing key, or decide whether a grant is interactive.
  Directed identity's non-interactive restriction belongs to grant-request validation.

  Inspection omits JWK/display data. `to_value/1` and JSON encoding preserve wire
  shape and public JWK metadata. Validate manually modified structs with `validate/1`;
  encoding converts shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{ClientDisplay, JWK, Validation}

  @derive {Inspect, only: [:kind, :wallet_address]}
  @enforce_keys [:kind]
  defstruct [:kind, :wallet_address, :jwk, :display]

  @type t :: %__MODULE__{
          kind: :wallet_string | :wallet_address | :directed_identity,
          wallet_address: String.t() | nil,
          jwk: JWK.t() | nil,
          display: ClientDisplay.t() | nil
        }

  @doc "Decodes a protocol client string or object into a validated identity."
  @spec from_value(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_value(value) when is_binary(value),
    do: checked(%__MODULE__{kind: :wallet_string, wallet_address: value})

  def from_value(data) when is_map(data) and not is_struct(data) do
    with {:ok, kind} <- object_kind(data),
         :ok <- allowed_fields(data, kind),
         {:ok, jwk} <- decode_jwk(data, kind),
         {:ok, display} <- decode_display(data) do
      checked(%__MODULE__{
        kind: kind,
        wallet_address: data["walletAddress"],
        jwk: jwk,
        display: display
      })
    end
  end

  def from_value(_value),
    do: invalid([issue(:client, "must be a wallet URI string or identity object")])

  @doc "Checks the identity form and typed nested fields without performing HTTP."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = client) do
    case identity_errors(client) do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  @doc "Converts to the original protocol string/object shape without validating."
  @spec to_value(t()) :: String.t() | map()
  def to_value(%__MODULE__{kind: :wallet_string, wallet_address: wallet}), do: wallet

  def to_value(%__MODULE__{kind: :wallet_address} = client),
    do: with_display(%{"walletAddress" => client.wallet_address}, client.display)

  def to_value(%__MODULE__{kind: :directed_identity} = client),
    do: with_display(%{"jwk" => JWK.to_map(client.jwk)}, client.display)

  defp checked(client) do
    case validate(client) do
      :ok -> {:ok, client}
      {:error, error} -> {:error, error}
    end
  end

  defp object_kind(data) do
    case {Map.has_key?(data, "walletAddress"), Map.has_key?(data, "jwk")} do
      {true, false} -> {:ok, :wallet_address}
      {false, true} -> {:ok, :directed_identity}
      _other -> invalid([issue(:client, "must contain exactly one of walletAddress or jwk")])
    end
  end

  defp allowed_fields(data, kind) do
    identity_field = if kind == :wallet_address, do: "walletAddress", else: "jwk"

    if map_size(Map.drop(data, [identity_field, "display"])) == 0,
      do: :ok,
      else: invalid([issue(:client, "must contain only its identity field and optional display")])
  end

  defp decode_jwk(data, :directed_identity), do: nested(JWK.from_map(data["jwk"]), :jwk, :jwk)
  defp decode_jwk(_data, :wallet_address), do: {:ok, nil}

  defp decode_display(data) do
    case Map.fetch(data, "display") do
      :error -> {:ok, nil}
      {:ok, value} -> nested(ClientDisplay.from_map(value), :display, :client_display)
    end
  end

  defp identity_errors(%__MODULE__{kind: :wallet_string} = client) do
    wallet_errors(client.wallet_address) ++
      absent(client.jwk, :jwk) ++ absent(client.display, :display)
  end

  defp identity_errors(%__MODULE__{kind: :wallet_address} = client) do
    wallet_errors(client.wallet_address) ++
      absent(client.jwk, :jwk) ++ display_errors(client.display)
  end

  defp identity_errors(%__MODULE__{kind: :directed_identity} = client) do
    absent(client.wallet_address, :wallet_address) ++
      key_errors(client.jwk) ++ display_errors(client.display)
  end

  defp identity_errors(_client),
    do: [issue(:kind, "must be wallet_string, wallet_address or directed_identity")]

  defp wallet_errors(value) do
    if Validation.absolute_uri?(value),
      do: [],
      else: [issue(:wallet_address, "must be an absolute URI")]
  end

  defp key_errors(%JWK{} = jwk), do: prefix_errors(JWK.validate(jwk), :jwk, :jwk)
  defp key_errors(_value), do: [issue(:jwk, "must be a public JWK struct")]

  defp display_errors(nil), do: []

  defp display_errors(%ClientDisplay{} = display),
    do: prefix_errors(ClientDisplay.validate(display), :display, :client_display)

  defp display_errors(_value),
    do: [issue(:display, "must be a ClientDisplay struct when present")]

  defp absent(nil, _field), do: []
  defp absent(_value, field), do: [issue(field, "must be omitted for this identity form")]

  defp nested({:ok, value}, _parent, _root), do: {:ok, value}

  defp nested({:error, error}, parent, root),
    do: invalid(prefix(error.validation_errors, parent, root))

  defp prefix_errors(:ok, _parent, _root), do: []

  defp prefix_errors({:error, error}, parent, root),
    do: prefix(error.validation_errors, parent, root)

  defp prefix(errors, parent, root) do
    Enum.map(errors, fn %{field: field} = error ->
      %{error | field: if(field == root, do: parent, else: "#{parent}.#{field}")}
    end)
  end

  defp with_display(fields, nil), do: fields

  defp with_display(fields, display),
    do: Map.put(fields, "display", ClientDisplay.to_map(display))

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments grant client identity",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.GrantClient do
  def encode(client, opts) do
    client |> OpenPayments.Types.GrantClient.to_value() |> Jason.Encoder.encode(opts)
  end
end
