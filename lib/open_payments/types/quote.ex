defmodule OpenPayments.Types.Quote do
  @moduledoc """
  Quoted amounts for an outgoing payment, with typed debit and receive amounts.

  Follows the pinned quote schema: required absolute-URI id and wallet_address,
  HTTP(S) incoming-payment receiver, debit_amount and receive_amount, method ilp
  and RFC 3339 created_at. Optional expires_at is a string: the schema declares no
  date-time format for it, so this codec preserves it without parsing or comparing
  it with the current time. Omission becomes nil; explicit null is invalid.

  Additional top-level fields are forbidden, including sentAmount, which appears
  in inconsistent standalone schema examples. Both response amounts are required;
  one such example also omits receiveAmount. Valid GET/create operation examples
  satisfy the declared schema without repair. Permitted amount extensions remain
  intact, and URI, timestamp and decimal spelling are preserved.

  Debit and receive amounts may use different assets. This codec does not compare
  amounts, infer exchange rates or fees, enforce positivity or elapsed expiry,
  fetch wallet/receiver data, sign requests or create payments. Creation-request
  amount variants are separate from this response type.

  Inspection exposes only id, method and created_at. Explicit map/JSON exports
  include wallet, receiver, amounts and expiry data. Errors contain safe field
  paths without rejected values or unknown field names. Validate modified structs
  with `validate/1`; `to_map/1` converts without validating.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{Amount, Validation}

  @derive {Inspect, only: [:id, :method, :created_at]}
  @enforce_keys [
    :id,
    :wallet_address,
    :receiver,
    :debit_amount,
    :receive_amount,
    :method,
    :created_at
  ]
  defstruct [
    :id,
    :wallet_address,
    :receiver,
    :debit_amount,
    :receive_amount,
    :method,
    :created_at,
    :expires_at
  ]

  @wire_fields ~w(id walletAddress receiver debitAmount receiveAmount method createdAt expiresAt)

  @type t :: %__MODULE__{
          id: String.t(),
          wallet_address: String.t(),
          receiver: String.t(),
          debit_amount: Amount.t(),
          receive_amount: Amount.t(),
          method: String.t(),
          created_at: String.t(),
          expires_at: String.t() | nil
        }

  @doc "Decodes strict quote response data and both required typed amounts."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    with {:ok, debit} <- amount(data["debitAmount"], :debit_amount, &Amount.from_map/1),
         {:ok, receive} <- amount(data["receiveAmount"], :receive_amount, &Amount.from_map/1) do
      quote = %__MODULE__{
        id: data["id"],
        wallet_address: data["walletAddress"],
        receiver: data["receiver"],
        debit_amount: debit,
        receive_amount: receive,
        method: data["method"],
        created_at: data["createdAt"],
        expires_at: data["expiresAt"]
      }

      extra_errors =
        if map_size(Map.drop(data, @wire_fields)) == 0,
          do: [],
          else: [issue(:quote, "must contain only declared quote response fields")]

      case validate_fields(quote, Map.has_key?(data, "expiresAt"), extra_errors) do
        :ok -> {:ok, quote}
        {:error, error} -> {:error, error}
      end
    end
  end

  def from_map(_data), do: invalid([issue(:quote, "must be a JSON object")])

  @doc "Revalidates fields and typed amounts, treating nil expiry as omitted."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = quote),
    do: validate_fields(quote, not is_nil(quote.expires_at), [])

  @doc "Exports protocol fields, including wallet/receiver/amount data, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = quote) do
    fields = %{
      "id" => quote.id,
      "walletAddress" => quote.wallet_address,
      "receiver" => quote.receiver,
      "debitAmount" => Amount.to_map(quote.debit_amount),
      "receiveAmount" => Amount.to_map(quote.receive_amount),
      "method" => quote.method,
      "createdAt" => quote.created_at
    }

    if is_nil(quote.expires_at), do: fields, else: Map.put(fields, "expiresAt", quote.expires_at)
  end

  defp validate_fields(quote, expiry_present?, extra_errors) do
    checks = [
      {Validation.absolute_uri?(quote.id), :id, "must be an absolute URI"},
      {Validation.absolute_uri?(quote.wallet_address), :wallet_address,
       "must be an absolute URI"},
      {Validation.incoming_payment_uri?(quote.receiver), :receiver,
       "must be an HTTP(S) incoming-payment URI"},
      {quote.method == "ilp", :method, "must be ilp"},
      {Validation.date_time?(quote.created_at), :created_at, "must be an RFC 3339 timestamp"},
      {not expiry_present? or Validation.string?(quote.expires_at), :expires_at,
       "must be a string when present"}
    ]

    errors =
      Enum.flat_map(checks, fn
        {true, _field, _message} -> []
        {false, field, message} -> [issue(field, message)]
      end)

    case errors ++
           amount_errors(quote.debit_amount, :debit_amount) ++
           amount_errors(quote.receive_amount, :receive_amount) ++ extra_errors do
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
         description: "Invalid Open Payments quote",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.Quote do
  def encode(quote, opts) do
    quote |> OpenPayments.Types.Quote.to_map() |> Jason.Encode.map(opts)
  end
end
