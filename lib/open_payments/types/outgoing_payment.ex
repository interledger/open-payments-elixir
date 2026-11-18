defmodule OpenPayments.Types.OutgoingPayment do
  @moduledoc """
  Detailed outgoing-payment response data used by reads and listing.

  Follows the pinned outgoing-payment schema: required absolute-URI id and
  wallet_address, HTTP(S) incoming-payment receiver, typed receive_amount,
  debit_amount and sent_amount, and RFC 3339 created_at. Optional quote_id is an
  absolute URI, failed is a boolean and metadata is a JSON object. Omission
  becomes nil and is omitted on export; explicit null is invalid. The schema's
  failed default does not insert a value: false remains distinct from omission.

  Additional top-level fields are forbidden, including updatedAt and grant spent
  amounts. Creation responses with spent amounts use a separate schema. Permitted
  nested amount extensions, metadata, URI spelling, timestamp precision and
  decimal spelling are preserved. An inconsistent standalone example omits
  receiveAmount and has an invalid receiver; it is rejected without repair.

  This codec does not compare assets or values, interpret failed as completion,
  enforce positivity, infer fees or exchange rates, fetch related resources or
  make payments. Node's operation-level payment consistency checks are separate
  from this data model.

  Inspection exposes only id, failed and created_at. Explicit map/JSON exports
  include wallet, receiver, quote, amounts and metadata. Errors contain safe field
  paths without rejected data or unknown field names. Validate modified structs
  with `validate/1`; `to_map/1` converts without validating.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{Amount, Validation}

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
    :metadata
  ]

  @wire_fields ~w(id walletAddress receiver receiveAmount debitAmount sentAmount createdAt quoteId failed metadata)

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
          metadata: %{optional(String.t()) => term()} | nil
        }

  @doc "Decodes strict outgoing-payment data and its three required typed amounts."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    with {:ok, receive} <- amount(data["receiveAmount"], :receive_amount, &Amount.from_map/1),
         {:ok, debit} <- amount(data["debitAmount"], :debit_amount, &Amount.from_map/1),
         {:ok, sent} <- amount(data["sentAmount"], :sent_amount, &Amount.from_map/1) do
      payment = %__MODULE__{
        id: data["id"],
        wallet_address: data["walletAddress"],
        receiver: data["receiver"],
        receive_amount: receive,
        debit_amount: debit,
        sent_amount: sent,
        created_at: data["createdAt"],
        quote_id: data["quoteId"],
        failed: data["failed"],
        metadata: data["metadata"]
      }

      extra_errors =
        if map_size(Map.drop(data, @wire_fields)) == 0,
          do: [],
          else: [issue(:outgoing_payment, "must contain only declared outgoing-payment fields")]

      case validate_fields(payment, Map.keys(data), extra_errors) do
        :ok -> {:ok, payment}
        {:error, error} -> {:error, error}
      end
    end
  end

  def from_map(_data), do: invalid([issue(:outgoing_payment, "must be a JSON object")])

  @doc "Revalidates fields and typed amounts, treating nil optional fields as omitted."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = payment) do
    present =
      for {name, value} <- [
            {"quoteId", payment.quote_id},
            {"failed", payment.failed},
            {"metadata", payment.metadata}
          ],
          not is_nil(value),
          do: name

    validate_fields(payment, present, [])
  end

  @doc "Exports protocol fields, including metadata and amounts, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = payment) do
    fields = %{
      "id" => payment.id,
      "walletAddress" => payment.wallet_address,
      "receiver" => payment.receiver,
      "receiveAmount" => Amount.to_map(payment.receive_amount),
      "debitAmount" => Amount.to_map(payment.debit_amount),
      "sentAmount" => Amount.to_map(payment.sent_amount),
      "createdAt" => payment.created_at
    }

    Enum.reduce(
      [{"quoteId", payment.quote_id}, {"failed", payment.failed}, {"metadata", payment.metadata}],
      fields,
      fn
        {_name, nil}, fields -> fields
        {name, value}, fields -> Map.put(fields, name, value)
      end
    )
  end

  defp validate_fields(payment, present, extra_errors) do
    checks = [
      {Validation.absolute_uri?(payment.id), :id, "must be an absolute URI"},
      {Validation.absolute_uri?(payment.wallet_address), :wallet_address,
       "must be an absolute URI"},
      {Validation.incoming_payment_uri?(payment.receiver), :receiver,
       "must be an HTTP(S) incoming-payment URI"},
      {Validation.date_time?(payment.created_at), :created_at, "must be an RFC 3339 timestamp"},
      {"quoteId" not in present or Validation.absolute_uri?(payment.quote_id), :quote_id,
       "must be an absolute URI when present"},
      {"failed" not in present or is_boolean(payment.failed), :failed,
       "must be a boolean when present"},
      {"metadata" not in present or Validation.extensions?(payment.metadata, []), :metadata,
       "must be a JSON object with string keys when present"}
    ]

    errors =
      Enum.flat_map(checks, fn
        {true, _field, _message} -> []
        {false, field, message} -> [issue(field, message)]
      end)

    case errors ++
           amount_errors(payment.receive_amount, :receive_amount) ++
           amount_errors(payment.debit_amount, :debit_amount) ++
           amount_errors(payment.sent_amount, :sent_amount) ++ extra_errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  defp amount_errors(value, field) do
    case amount(value, field, &validate_amount/1) do
      {:ok, _amount} -> []
      {:error, error} -> error.validation_errors
    end
  end

  defp amount(value, field, decoder) do
    case decoder.(value) do
      {:ok, amount} -> {:ok, amount}
      {:error, error} -> invalid(prefix(error.validation_errors, field))
    end
  end

  defp validate_amount(%Amount{} = amount) do
    with :ok <- Amount.validate(amount), do: {:ok, amount}
  end

  defp validate_amount(_amount), do: invalid([issue(:amount, "must be an Amount struct")])

  defp prefix(errors, parent) do
    Enum.map(errors, fn %{field: field} = error ->
      %{error | field: if(field == :amount, do: parent, else: "#{parent}.#{field}")}
    end)
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments outgoing payment",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.OutgoingPayment do
  def encode(payment, opts) do
    payment |> OpenPayments.Types.OutgoingPayment.to_map() |> Jason.Encode.map(opts)
  end
end
