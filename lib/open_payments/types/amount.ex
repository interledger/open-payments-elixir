defmodule OpenPayments.Types.Amount do
  @moduledoc """
  A monetary amount in the smallest units of its asset.

  `value` is a decimal string from `"0"` through `"18446744073709551615"`.
  `asset_scale` is an integer from 0 through 255. For example, a value of
  `"1000"` with asset code `"USD"` and scale `2` represents USD 10.00.

  `new/3` and `from_map/1` validate input without coercing numbers or changing
  asset codes. Additional JSON fields are retained in `extensions`, as permitted
  by the amount schema. JSON encoding uses the protocol's `assetCode` and
  `assetScale` field names.

  Struct literals can bypass constructor checks. Call `validate/1` before using
  a manually constructed or modified amount; `to_map/1` only converts its shape.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.Validation

  @enforce_keys [:value, :asset_code, :asset_scale]
  defstruct [:value, :asset_code, :asset_scale, extensions: %{}]

  @max_value "18446744073709551615"
  @wire_fields ~w(value assetCode assetScale)

  @type t :: %__MODULE__{
          value: String.t(),
          asset_code: String.t(),
          asset_scale: 0..255,
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Constructs and validates an amount, keeping the supplied decimal string."
  @spec new(String.t(), String.t(), integer()) :: {:ok, t()} | {:error, Error.t()}
  def new(value, asset_code, asset_scale) do
    checked(%__MODULE__{value: value, asset_code: asset_code, asset_scale: asset_scale})
  end

  @doc "Decodes a string-keyed JSON object and retains additional fields."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    checked(%__MODULE__{
      value: Map.get(data, "value"),
      asset_code: Map.get(data, "assetCode"),
      asset_scale: Map.get(data, "assetScale"),
      extensions: Map.drop(data, @wire_fields)
    })
  end

  def from_map(_data), do: invalid([issue(:amount, "must be a JSON object")])

  @doc "Checks a struct against the shared amount contract."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = amount) do
    errors =
      [
        {valid_value?(amount.value), :value, "must be an unsigned 64-bit decimal string"},
        {Validation.string?(amount.asset_code), :asset_code, "must be a string"},
        {Validation.asset_scale?(amount.asset_scale), :asset_scale,
         "must be an integer between 0 and 255"},
        {Validation.extensions?(amount.extensions, @wire_fields), :extensions,
         "must be a JSON object with string keys and no reserved amount fields"}
      ]
      |> Enum.flat_map(fn
        {true, _field, _message} -> []
        {false, field, message} -> [issue(field, message)]
      end)

    if errors == [], do: :ok, else: invalid(errors)
  end

  @doc "Converts an amount to its JSON field names without validating it."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = amount) do
    Map.merge(amount.extensions, %{
      "value" => amount.value,
      "assetCode" => amount.asset_code,
      "assetScale" => amount.asset_scale
    })
  end

  defp checked(amount) do
    case validate(amount) do
      :ok -> {:ok, amount}
      {:error, error} -> {:error, error}
    end
  end

  defp valid_value?(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9]+\z/, value) do
      significant = String.trim_leading(value, "0")

      byte_size(significant) < byte_size(@max_value) or
        (byte_size(significant) == byte_size(@max_value) and significant <= @max_value)
    else
      false
    end
  end

  defp valid_value?(_value), do: false

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors) do
    {:error,
     %Error{
       kind: :validation,
       description: "Invalid Open Payments amount",
       validation_errors: errors
     }}
  end
end

defimpl Jason.Encoder, for: OpenPayments.Types.Amount do
  def encode(amount, opts) do
    amount |> OpenPayments.Types.Amount.to_map() |> Jason.Encode.map(opts)
  end
end
