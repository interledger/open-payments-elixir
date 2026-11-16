defmodule OpenPayments.Types.JWKS do
  @moduledoc """
  A public JSON Web Key Set returned by a wallet address server.

  The shared schema requires a `keys` array and forbids other top-level fields.
  Each entry is decoded to an `OpenPayments.Types.JWK`. Empty arrays and repeated
  key IDs are permitted by the schema; selecting a usable key is a separate step.
  Validation errors include array indexes, such as `keys[0].x`.

  Struct literals can bypass validation. Call `validate/1` after constructing or
  modifying a struct; `to_map/1` only converts its shape.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.JWK

  @enforce_keys [:keys]
  defstruct [:keys]

  @type t :: %__MODULE__{keys: [JWK.t()]}

  @doc "Decodes and validates a public JWKS JSON object."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    extra_errors =
      if map_size(Map.drop(data, ["keys"])) == 0,
        do: [],
        else: [issue(:jwks, "must contain only the keys field")]

    {keys, errors} = convert_keys(Map.get(data, "keys"), &JWK.from_map/1)

    case extra_errors ++ errors do
      [] -> {:ok, %__MODULE__{keys: keys}}
      errors -> invalid(errors)
    end
  end

  def from_map(_data), do: invalid([issue(:jwks, "must be a JSON object")])

  @doc "Validates a JWKS struct and every contained JWK struct."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{keys: keys}) do
    case convert_keys(keys, &validate_key/1) do
      {_keys, []} -> :ok
      {_keys, errors} -> invalid(errors)
    end
  end

  @doc "Converts a public JWKS to its JSON representation without validating it."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{keys: keys}), do: %{"keys" => Enum.map(keys, &JWK.to_map/1)}

  defp validate_key(%JWK{} = key) do
    case JWK.validate(key) do
      :ok -> {:ok, key}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_key(_key) do
    {:error, %Error{validation_errors: [issue(:jwk, "must be a JWK struct")]}}
  end

  defp convert_keys(keys, converter) when is_list(keys) do
    {converted, errors} =
      keys
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {key, index}, {converted, errors} ->
        case converter.(key) do
          {:ok, key} -> {[key | converted], errors}
          {:error, error} -> {converted, [indexed_issues(error, index) | errors]}
        end
      end)

    {Enum.reverse(converted), errors |> Enum.reverse() |> List.flatten()}
  end

  defp convert_keys(_keys, _converter), do: {[], [issue(:keys, "must be an array")]}

  defp indexed_issues(error, index) do
    Enum.map(error.validation_errors, fn %{field: field} = error ->
      path = if field == :jwk, do: "keys[#{index}]", else: "keys[#{index}].#{field}"
      %{error | field: path}
    end)
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors) do
    {:error,
     %Error{
       kind: :validation,
       description: "Invalid Open Payments public JWKS",
       validation_errors: errors
     }}
  end
end

defimpl Jason.Encoder, for: OpenPayments.Types.JWKS do
  def encode(key_set, opts) do
    key_set |> OpenPayments.Types.JWKS.to_map() |> Jason.Encode.map(opts)
  end
end
