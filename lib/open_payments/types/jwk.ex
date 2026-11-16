defmodule OpenPayments.Types.JWK do
  @moduledoc """
  An Ed25519 public JSON Web Key used by Open Payments.

  `from_map/1` validates the shared schema's required fields and enum values.
  An omitted `use` becomes nil; an explicit null is invalid. Additional JSON
  metadata is preserved in `extensions`.

  This public type rejects the private `d` parameter and excludes it from export,
  including when a struct is manually modified. Its inspection omits extensions.
  Private-key import belongs to the signing utilities.

  Validation checks the schema's nonempty base64url alphabet for `x`. It does not
  establish that the value decodes to a usable 32-byte Ed25519 key. Cryptographic
  key validation and key selection are separate from decoding response data.

  Struct literals can bypass validation. Call `validate/1` after constructing or
  modifying a struct; `to_map/1` converts its shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.Validation

  @derive {Inspect, only: [:kid, :alg, :kty, :crv, :x, :use]}
  @enforce_keys [:kid, :alg, :kty, :crv, :x]
  defstruct [:kid, :alg, :kty, :crv, :x, :use, extensions: %{}]

  @wire_fields ~w(kid alg kty crv x use)

  @type t :: %__MODULE__{
          kid: String.t(),
          alg: String.t(),
          kty: String.t(),
          crv: String.t(),
          x: String.t(),
          use: String.t() | nil,
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Decodes and validates a public JWK JSON object."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    key = %__MODULE__{
      kid: Map.get(data, "kid"),
      alg: Map.get(data, "alg"),
      kty: Map.get(data, "kty"),
      crv: Map.get(data, "crv"),
      x: Map.get(data, "x"),
      use: Map.get(data, "use"),
      extensions: Map.drop(data, @wire_fields)
    }

    case validate_fields(key, Map.has_key?(data, "use")) do
      :ok -> {:ok, key}
      {:error, error} -> {:error, error}
    end
  end

  def from_map(_data), do: invalid([issue(:jwk, "must be a JSON object")])

  @doc "Validates a public JWK struct, treating nil use as omitted."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = key), do: validate_fields(key, not is_nil(key.use))

  @doc "Converts a public JWK to JSON fields, excluding private key material."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = key) do
    fields = %{
      "kid" => key.kid,
      "alg" => key.alg,
      "kty" => key.kty,
      "crv" => key.crv,
      "x" => key.x
    }

    fields = if is_nil(key.use), do: fields, else: Map.put(fields, "use", key.use)

    key.extensions |> Map.drop(["d", :d | @wire_fields]) |> Map.merge(fields)
  end

  defp validate_fields(key, use_present?) do
    errors =
      [
        {Validation.string?(key.kid), :kid, "must be a string"},
        {key.alg == "EdDSA", :alg, "must be EdDSA"},
        {key.kty == "OKP", :kty, "must be OKP"},
        {key.crv == "Ed25519", :crv, "must be Ed25519"},
        {public_value?(key.x), :x, "must be a nonempty unpadded base64url string"},
        {not use_present? or key.use == "sig", :use, "must be sig when present"},
        {not private_parameter?(key.extensions), :d, "must not be present in a public JWK"},
        {Validation.extensions?(key.extensions, @wire_fields), :extensions,
         "must be a JSON object with string keys and no reserved JWK fields"}
      ]
      |> Enum.flat_map(fn
        {true, _field, _message} -> []
        {false, field, message} -> [issue(field, message)]
      end)

    if errors == [], do: :ok, else: invalid(errors)
  end

  defp public_value?(value) when is_binary(value), do: Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value)
  defp public_value?(_value), do: false

  defp private_parameter?(extensions) when is_map(extensions) do
    Map.has_key?(extensions, "d") or Map.has_key?(extensions, :d)
  end

  defp private_parameter?(_extensions), do: false

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors) do
    {:error,
     %Error{
       kind: :validation,
       description: "Invalid Open Payments public JWK",
       validation_errors: errors
     }}
  end
end

defimpl Jason.Encoder, for: OpenPayments.Types.JWK do
  def encode(key, opts) do
    key |> OpenPayments.Types.JWK.to_map() |> Jason.Encode.map(opts)
  end
end
