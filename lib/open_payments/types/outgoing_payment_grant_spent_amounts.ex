defmodule OpenPayments.Types.OutgoingPaymentGrantSpentAmounts do
  @moduledoc """
  Spent amounts for the current outgoing-payment grant or recurring interval.

  Both spent_receive_amount and spent_debit_amount are required. Each is a typed
  `Amount` or nil for explicit JSON null, matching the pinned grant-spent endpoint
  and Node's response type. Missing map fields are invalid. Unlike optional spent
  fields on creation responses, nil here is always exported as null.

  Permitted additional JSON fields remain in extensions. Amount decimal spelling,
  asset data and nested extensions are preserved. The codec does not replace null
  with zero, infer grant existence or budget, compare assets/values, interpret
  recurring intervals, track spending or make requests/payments. The server
  determines the grant and current interval associated with the presented token.

  Inspection hides all payload data. Explicit map/JSON exports include amounts
  and extensions; errors retain safe field paths without rejected data or unknown
  names. Validate modified structs with `validate/1`; `to_map/1` converts without
  validating.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{Amount, Validation}

  @derive {Inspect, only: []}
  @enforce_keys [:spent_receive_amount, :spent_debit_amount]
  defstruct [:spent_receive_amount, :spent_debit_amount, extensions: %{}]

  @wire_fields ~w(spentReceiveAmount spentDebitAmount)

  @type t :: %__MODULE__{
          spent_receive_amount: Amount.t() | nil,
          spent_debit_amount: Amount.t() | nil,
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Decodes both required amount-or-null fields and preserves JSON extensions."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    with {:ok, receive} <- amount(data, "spentReceiveAmount", :spent_receive_amount),
         {:ok, debit} <- amount(data, "spentDebitAmount", :spent_debit_amount) do
      response = %__MODULE__{
        spent_receive_amount: receive,
        spent_debit_amount: debit,
        extensions: Map.drop(data, @wire_fields)
      }

      case validate(response) do
        :ok -> {:ok, response}
        {:error, error} -> {:error, error}
      end
    end
  end

  def from_map(_data),
    do: invalid([issue(:outgoing_payment_grant_spent_amounts, "must be a JSON object")])

  @doc "Revalidates both nullable typed amounts and reserved-field-safe JSON extensions."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = response) do
    extension_errors =
      if Validation.extensions?(response.extensions, @wire_fields),
        do: [],
        else: [
          issue(
            :extensions,
            "must be a JSON object with string keys and no reserved spent-amount fields"
          )
        ]

    errors =
      amount_errors(response.spent_receive_amount, :spent_receive_amount) ++
        amount_errors(response.spent_debit_amount, :spent_debit_amount) ++ extension_errors

    case errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  @doc "Exports both protocol fields, including explicit nulls, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = response) do
    response.extensions
    |> Map.drop(@wire_fields)
    |> Map.merge(%{
      "spentReceiveAmount" => amount_map(response.spent_receive_amount),
      "spentDebitAmount" => amount_map(response.spent_debit_amount)
    })
  end

  defp amount(data, name, field) do
    case Map.fetch(data, name) do
      :error ->
        invalid([issue(field, "must be present as an amount or null")])

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} ->
        case Amount.from_map(value) do
          {:ok, amount} -> {:ok, amount}
          {:error, error} -> invalid(prefix(error.validation_errors, field))
        end
    end
  end

  defp amount_errors(nil, _field), do: []

  defp amount_errors(%Amount{} = amount, field) do
    case Amount.validate(amount) do
      :ok -> []
      {:error, error} -> prefix(error.validation_errors, field)
    end
  end

  defp amount_errors(_amount, field), do: [issue(field, "must be an Amount struct or nil")]

  defp prefix(errors, parent) do
    Enum.map(errors, fn %{field: field} = error ->
      %{error | field: if(field == :amount, do: parent, else: "#{parent}.#{field}")}
    end)
  end

  defp amount_map(nil), do: nil
  defp amount_map(amount), do: Amount.to_map(amount)
  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments outgoing-payment grant spent amounts",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.OutgoingPaymentGrantSpentAmounts do
  def encode(response, opts) do
    response
    |> OpenPayments.Types.OutgoingPaymentGrantSpentAmounts.to_map()
    |> Jason.Encode.map(opts)
  end
end
