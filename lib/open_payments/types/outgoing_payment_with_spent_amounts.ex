defmodule OpenPayments.Types.OutgoingPaymentWithSpentAmounts do
  @moduledoc """
  An outgoing-payment creation response with optional grant spent amounts.

  Shares all declared detail fields and their validation with `OutgoingPayment`.
  Fields remain flat, and grant_spent_debit_amount and grant_spent_receive_amount
  become typed `Amount` structs when present. Either, both or neither may be
  supplied. Omission becomes nil and is omitted on export; explicit null is
  invalid. This differs from the separate grant-spent endpoint's nullable fields.

  The pinned creation-response schema permits additional JSON fields, retained
  in extensions. The read/list `OutgoingPayment` schema instead forbids extras.
  Unknown fields are not interpreted, including any updatedAt extension. Shared
  fields preserve URI/timestamp/decimal spelling, false failed and empty metadata
  without inserting defaults. All typed children are revalidated.

  No grant limit, asset, value, failure-state or time comparison is performed by
  this codec. Grant amounts need not match this payment's amounts: they describe
  spending under the current grant. Operation-level payment consistency checks
  are separate. This type makes no requests, tracks no grant state and makes no
  payments.

  Inspection exposes only id, failed and created_at. Explicit map/JSON exports
  include wallet, receiver, quote, all amounts, metadata and extensions. Errors
  retain safe field paths without rejected data or unknown field names. Validate
  modified structs with `validate/1`; `to_map/1` converts without validating.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{Amount, OutgoingPayment, Validation}

  @derive {Inspect, only: [:id, :failed, :created_at]}
  @enforce_keys [
    :id,
    :wallet_address,
    :receiver,
    :receive_amount,
    :debit_amount,
    :sent_amount,
    :created_at
  ]
  defstruct [
    :id,
    :wallet_address,
    :receiver,
    :receive_amount,
    :debit_amount,
    :sent_amount,
    :created_at,
    :quote_id,
    :failed,
    :metadata,
    :grant_spent_debit_amount,
    :grant_spent_receive_amount,
    extensions: %{}
  ]

  @detail_fields ~w(id wallet_address receiver receive_amount debit_amount sent_amount created_at quote_id failed metadata)a
  @detail_wire_fields ~w(id walletAddress receiver receiveAmount debitAmount sentAmount createdAt quoteId failed metadata)
  @wire_fields @detail_wire_fields ++ ~w(grantSpentDebitAmount grantSpentReceiveAmount)

  @type t :: %__MODULE__{
          id: String.t(),
          wallet_address: String.t(),
          receiver: String.t(),
          receive_amount: Amount.t(),
          debit_amount: Amount.t(),
          sent_amount: Amount.t(),
          created_at: String.t(),
          quote_id: String.t() | nil,
          failed: boolean() | nil,
          metadata: %{optional(String.t()) => term()} | nil,
          grant_spent_debit_amount: Amount.t() | nil,
          grant_spent_receive_amount: Amount.t() | nil,
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Decodes flat payment details, optional typed spent amounts and JSON extensions."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    with {:ok, details} <- OutgoingPayment.from_map(Map.take(data, @detail_wire_fields)),
         {:ok, debit} <- spent_amount(data, "grantSpentDebitAmount", :grant_spent_debit_amount),
         {:ok, receive} <-
           spent_amount(data, "grantSpentReceiveAmount", :grant_spent_receive_amount) do
      fields =
        details
        |> Map.from_struct()
        |> Map.merge(%{
          grant_spent_debit_amount: debit,
          grant_spent_receive_amount: receive,
          extensions: Map.drop(data, @wire_fields)
        })

      payment = struct!(__MODULE__, fields)

      case validate(payment) do
        :ok -> {:ok, payment}
        {:error, error} -> {:error, error}
      end
    else
      {:error, error} -> invalid(error.validation_errors)
    end
  end

  def from_map(_data),
    do: invalid([issue(:outgoing_payment_with_spent_amounts, "must be a JSON object")])

  @doc "Revalidates shared details, all typed amounts and reserved-field-safe extensions."
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
      result_errors(OutgoingPayment.validate(details(payment))) ++
        amount_errors(payment.grant_spent_debit_amount, :grant_spent_debit_amount) ++
        amount_errors(payment.grant_spent_receive_amount, :grant_spent_receive_amount) ++
        extension_errors

    case errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  @doc "Exports all protocol amounts, metadata and extensions without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = payment) do
    fields = payment |> details() |> OutgoingPayment.to_map()

    fields =
      Enum.reduce(
        [
          {"grantSpentDebitAmount", payment.grant_spent_debit_amount},
          {"grantSpentReceiveAmount", payment.grant_spent_receive_amount}
        ],
        fields,
        fn
          {_name, nil}, fields -> fields
          {name, amount}, fields -> Map.put(fields, name, Amount.to_map(amount))
        end
      )

    payment.extensions |> Map.drop(@wire_fields) |> Map.merge(fields)
  end

  defp details(payment),
    do: struct!(OutgoingPayment, Map.take(Map.from_struct(payment), @detail_fields))

  defp spent_amount(data, name, field) do
    if Map.has_key?(data, name) do
      case Amount.from_map(data[name]) do
        {:ok, amount} -> {:ok, amount}
        {:error, error} -> invalid(prefix(error.validation_errors, field))
      end
    else
      {:ok, nil}
    end
  end

  defp amount_errors(nil, _field), do: []

  defp amount_errors(%Amount{} = amount, field),
    do: amount |> Amount.validate() |> result_errors() |> prefix(field)

  defp amount_errors(_amount, field),
    do: [issue(field, "must be an Amount struct when present")]

  defp prefix(errors, parent) do
    Enum.map(errors, fn %{field: field} = error ->
      %{error | field: if(field == :amount, do: parent, else: "#{parent}.#{field}")}
    end)
  end

  defp result_errors(:ok), do: []
  defp result_errors({:error, error}), do: error.validation_errors
  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments outgoing payment with spent amounts",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.OutgoingPaymentWithSpentAmounts do
  def encode(payment, opts) do
    payment
    |> OpenPayments.Types.OutgoingPaymentWithSpentAmounts.to_map()
    |> Jason.Encode.map(opts)
  end
end
