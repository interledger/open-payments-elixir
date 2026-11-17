defmodule OpenPayments.Types.PINWorkingKey do
  @moduledoc """
  Encrypted PIN working-key data carried in card authorization payloads.

  The pinned schema requires string fields `key`, `kvc` and `iv` and forbids
  additional fields. This codec validates JSON shape without imposing hex/length
  constraints, checking key values, decrypting material or encrypting a PIN block.

  Inspection omits all fields. Explicit `to_map/1` and JSON encoding include the
  sensitive protocol values. Errors identify fields without retaining values.
  Validate manually constructed or modified structs with `validate/1`;
  `to_map/1` converts shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.Validation

  @derive {Inspect, only: []}
  @enforce_keys [:key, :kvc, :iv]
  defstruct [:key, :kvc, :iv]

  @wire_fields ~w(key kvc iv)
  @fields ~w(key kvc iv)a

  @type t :: %__MODULE__{key: String.t(), kvc: String.t(), iv: String.t()}

  @doc "Decodes and validates the encrypted PIN working-key JSON object."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    pwk = %__MODULE__{key: data["key"], kvc: data["kvc"], iv: data["iv"]}

    extra_errors =
      if map_size(Map.drop(data, @wire_fields)) == 0,
        do: [],
        else: [issue(:pin_working_key, "must contain only key, kvc and iv")]

    case validate_fields(pwk, extra_errors) do
      :ok -> {:ok, pwk}
      {:error, error} -> {:error, error}
    end
  end

  def from_map(_data), do: invalid([issue(:pin_working_key, "must be a JSON object")])

  @doc "Validates the typed fields without performing cryptographic operations."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = pwk), do: validate_fields(pwk, [])

  @doc "Converts to protocol fields, including encrypted key data, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = pwk), do: %{"key" => pwk.key, "kvc" => pwk.kvc, "iv" => pwk.iv}

  defp validate_fields(pwk, extra_errors) do
    errors =
      Enum.flat_map(@fields, fn field ->
        if Validation.string?(Map.fetch!(pwk, field)),
          do: [],
          else: [issue(field, "must be a string")]
      end)

    case errors ++ extra_errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments PIN working-key data",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.PINWorkingKey do
  def encode(pwk, opts) do
    pwk |> OpenPayments.Types.PINWorkingKey.to_map() |> Jason.Encode.map(opts)
  end
end
