defmodule OpenPayments.Types.IncomingPaymentWithMethods do
  @moduledoc """
  Detailed incoming-payment data with the payment methods required by create and
  authenticated read responses.

  Follows `incoming-payment-with-access-token`: all `IncomingPayment` detail
  fields plus required unique `methods`, decoded as typed `ILPPaymentMethod`
  structs. Empty arrays are allowed. Fields remain flat on this struct; detail
  validation is shared with `IncomingPayment`. Method uniqueness compares complete
  protocol objects, preserving entry order.

  Optional fields distinguish omission from explicit null, and permitted JSON
  extensions are retained. `authServer` is not required by this schema and remains
  extension data if supplied. URI/timestamp spelling is preserved without asset,
  amount or chronological comparisons. Operation-level checks are separate.

  Inspection omits methods, amounts, metadata and extensions. Explicit map/JSON
  exports include ILP shared secrets and all protocol data. Errors retain safe
  field/index paths. This codec makes no requests or STREAM connections.
  Validate modified structs with `validate/1`; `to_map/1` converts shape without
  validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{Amount, ILPPaymentMethod, IncomingPayment, Validation}

  @derive {Inspect, only: [:id, :completed, :created_at, :expires_at, :wallet_address]}
  @enforce_keys [:id, :completed, :received_amount, :created_at, :wallet_address, :methods]
  defstruct [
    :id,
    :completed,
    :received_amount,
    :created_at,
    :wallet_address,
    :methods,
    :incoming_amount,
    :expires_at,
    :metadata,
    extensions: %{}
  ]

  @detail_fields ~w(id completed received_amount created_at wallet_address incoming_amount expires_at metadata)a
  @wire_fields ~w(id completed receivedAmount createdAt walletAddress methods incomingAmount expiresAt metadata)

  @type t :: %__MODULE__{
          id: String.t(),
          completed: boolean(),
          received_amount: Amount.t(),
          created_at: String.t(),
          wallet_address: String.t(),
          methods: [ILPPaymentMethod.t()],
          incoming_amount: Amount.t() | nil,
          expires_at: String.t() | nil,
          metadata: %{optional(String.t()) => term()} | nil,
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Decodes the detailed payment and its required array of typed payment methods."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    with {:ok, details} <- IncomingPayment.from_map(Map.delete(data, "methods")),
         {:ok, methods} <- methods(data["methods"], &ILPPaymentMethod.from_map/1) do
      {:ok, struct!(__MODULE__, Map.put(Map.from_struct(details), :methods, methods))}
    else
      {:error, error} -> invalid(error.validation_errors)
    end
  end

  def from_map(_data),
    do: invalid([issue(:incoming_payment_with_methods, "must be a JSON object")])

  @doc "Revalidates all detail fields, typed methods, uniqueness and extension data."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = payment) do
    extension_errors =
      if Validation.extensions?(payment.extensions, @wire_fields),
        do: [],
        else: [
          issue(
            :extensions,
            "must be a JSON object with string keys and no reserved payment fields"
          )
        ]

    errors =
      result_errors(IncomingPayment.validate(details(payment))) ++
        result_errors(methods(payment.methods, &validate_method/1)) ++ extension_errors

    case errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  @doc "Converts to protocol fields, including method secrets, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = payment) do
    fields =
      payment
      |> details()
      |> IncomingPayment.to_map()
      |> Map.put("methods", Enum.map(payment.methods, &ILPPaymentMethod.to_map/1))

    payment.extensions |> Map.drop(@wire_fields) |> Map.merge(fields)
  end

  # Share detail validation/encoding while validating the complete extension set
  # here, where methods is a reserved protocol field rather than an extension.
  defp details(payment),
    do: struct!(IncomingPayment, Map.take(Map.from_struct(payment), @detail_fields))

  defp methods(values, decoder) when is_list(values) do
    {converted, errors} =
      values
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn
        {value, index}, {converted, errors} ->
          case decoder.(value) do
            {:ok, method} -> {[method | converted], errors}
            {:error, error} -> {converted, errors ++ prefix(error.validation_errors, index)}
          end
      end)

    wire_methods = Enum.map(converted, &ILPPaymentMethod.to_map/1)

    errors =
      if length(Enum.uniq(wire_methods)) == length(wire_methods),
        do: errors,
        else: errors ++ [issue(:methods, "must contain unique payment methods")]

    case errors do
      [] -> {:ok, Enum.reverse(converted)}
      errors -> invalid(errors)
    end
  end

  defp methods(_values, _decoder), do: invalid([issue(:methods, "must be an array")])

  defp validate_method(%ILPPaymentMethod{} = method) do
    case ILPPaymentMethod.validate(method) do
      :ok -> {:ok, method}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_method(_method),
    do: invalid([issue(:payment_method, "must be an ILPPaymentMethod struct")])

  defp prefix(errors, index) do
    Enum.map(errors, fn %{field: field} = error ->
      %{
        error
        | field:
            if(field == :payment_method,
              do: "methods[#{index}]",
              else: "methods[#{index}].#{field}"
            )
      }
    end)
  end

  defp result_errors(:ok), do: []
  defp result_errors({:ok, _value}), do: []
  defp result_errors({:error, error}), do: error.validation_errors
  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments incoming payment with methods",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.IncomingPaymentWithMethods do
  def encode(payment, opts) do
    payment |> OpenPayments.Types.IncomingPaymentWithMethods.to_map() |> Jason.Encode.map(opts)
  end
end
