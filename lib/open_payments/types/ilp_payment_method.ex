defmodule OpenPayments.Types.ILPPaymentMethod do
  @moduledoc """
  ILP connection details returned in an incoming payment's `methods` array.

  `from_map/1` validates the pinned `ilp-payment-method` schema: type `ilp`, an
  ILP address of at most 1023 characters, a nonempty unpadded base64url-alphabet
  shared secret, and no additional fields. It does not decode the secret, impose
  a secret byte length, or establish a STREAM connection.

  Inspection omits `shared_secret`. Explicit `to_map/1` and JSON encoding include
  the secret because it is part of the protocol payload; treat those exports as
  sensitive. Errors identify fields without retaining rejected values.

  Struct literals can bypass validation. Call `validate/1` after constructing or
  modifying a struct; `to_map/1` converts its shape without validating it.
  """

  alias OpenPayments.Error

  @derive {Inspect, only: [:type, :ilp_address]}
  @enforce_keys [:type, :ilp_address, :shared_secret]
  defstruct [:type, :ilp_address, :shared_secret]

  @wire_fields ~w(type ilpAddress sharedSecret)

  @type t :: %__MODULE__{
          type: String.t(),
          ilp_address: String.t(),
          shared_secret: String.t()
        }

  @doc "Decodes and validates an ILP payment-method JSON object."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    method = %__MODULE__{
      type: Map.get(data, "type"),
      ilp_address: Map.get(data, "ilpAddress"),
      shared_secret: Map.get(data, "sharedSecret")
    }

    extra_errors =
      if map_size(Map.drop(data, @wire_fields)) == 0,
        do: [],
        else: [issue(:payment_method, "must contain only type, ilpAddress and sharedSecret")]

    case validate_fields(method, extra_errors) do
      :ok -> {:ok, method}
      {:error, error} -> {:error, error}
    end
  end

  def from_map(_data), do: invalid([issue(:payment_method, "must be a JSON object")])

  @doc "Validates a payment-method struct against the shared ILP schema."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = method), do: validate_fields(method, [])

  @doc "Converts to protocol fields, including the shared secret, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = method),
    do: %{
      "type" => method.type,
      "ilpAddress" => method.ilp_address,
      "sharedSecret" => method.shared_secret
    }

  defp validate_fields(method, extra_errors) do
    errors =
      Enum.flat_map(
        [
          {method.type == "ilp", :type, "must be ilp"},
          {address?(method.ilp_address), :ilp_address,
           "must be an ILP address of at most 1023 characters"},
          {secret?(method.shared_secret), :shared_secret,
           "must be a nonempty unpadded base64url string"}
        ],
        fn
          {true, _field, _message} -> []
          {false, field, message} -> [issue(field, message)]
        end
      )

    case errors ++ extra_errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  defp address?(value) when is_binary(value) and byte_size(value) <= 1023,
    do:
      Regex.match?(
        ~r/\A(g|private|example|peer|self|test[1-3]?|local)([.][a-zA-Z0-9_~-]+)+\z/,
        value
      )

  defp address?(_value), do: false

  defp secret?(value) when is_binary(value), do: Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value)
  defp secret?(_value), do: false

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments ILP payment method",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.ILPPaymentMethod do
  def encode(method, opts) do
    method |> OpenPayments.Types.ILPPaymentMethod.to_map() |> Jason.Encode.map(opts)
  end
end
