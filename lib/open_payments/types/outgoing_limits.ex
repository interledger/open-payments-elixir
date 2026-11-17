defmodule OpenPayments.Types.OutgoingLimits do
  @moduledoc """
  Limits under which a grant can authorize outgoing payments.

  Supports no amount, a typed `debit_amount`, or a typed `receive_amount`.
  Debit and receive amounts are mutually exclusive, matching Node's grant-request
  validation in addition to the permissive schema branches. Optional `receiver`
  follows the schema's URI format and HTTP(S) incoming-payment URL pattern.
  Optional `interval` is a string: its ISO 8601 description supplies no pattern
  or format validator, so this codec preserves it without parsing recurrence.

  Omitted fields become nil; explicit JSON nulls are rejected. Empty limits are
  allowed. Additional JSON fields are retained in `extensions`. URI/interval
  spelling and amount strings are preserved. No network requests, budget tracking
  or interval calculations occur. Inspection omits amounts and extension metadata.

  Struct literals can bypass validation. Call `validate/1` after constructing or
  modifying a struct; `to_map/1` converts its shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{Amount, Validation}

  @derive {Inspect, only: [:receiver, :interval]}
  defstruct [:receiver, :interval, :debit_amount, :receive_amount, extensions: %{}]

  @wire_fields ~w(receiver interval debitAmount receiveAmount)

  @type t :: %__MODULE__{
          receiver: String.t() | nil,
          interval: String.t() | nil,
          debit_amount: Amount.t() | nil,
          receive_amount: Amount.t() | nil,
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Decodes limits with at most one amount, keeping permitted JSON extensions."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    with :ok <-
           exclusive(
             not Map.has_key?(data, "debitAmount") or not Map.has_key?(data, "receiveAmount")
           ),
         {:ok, debit} <- decode_amount(data, "debitAmount", :debit_amount),
         {:ok, receive} <- decode_amount(data, "receiveAmount", :receive_amount) do
      limits = %__MODULE__{
        receiver: data["receiver"],
        interval: data["interval"],
        debit_amount: debit,
        receive_amount: receive,
        extensions: Map.drop(data, @wire_fields)
      }

      case validate_fields(limits, Map.has_key?(data, "receiver"), Map.has_key?(data, "interval")) do
        :ok -> {:ok, limits}
        {:error, error} -> {:error, error}
      end
    end
  end

  def from_map(_data), do: invalid([issue(:limits, "must be a JSON object")])

  @doc "Validates a struct, treating nil fields as omitted."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = limits),
    do: validate_fields(limits, not is_nil(limits.receiver), not is_nil(limits.interval))

  @doc "Converts to protocol fields, omitting nil values, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = limits) do
    fields =
      %{}
      |> put_optional("receiver", limits.receiver)
      |> put_optional("interval", limits.interval)
      |> put_amount("debitAmount", limits.debit_amount)
      |> put_amount("receiveAmount", limits.receive_amount)

    limits.extensions |> Map.drop(@wire_fields) |> Map.merge(fields)
  end

  defp validate_fields(limits, receiver_present?, interval_present?) do
    errors =
      Enum.flat_map(
        [
          {not receiver_present? or Validation.incoming_payment_uri?(limits.receiver), :receiver,
           "must be an HTTP(S) incoming-payment URI when present"},
          {not interval_present? or Validation.string?(limits.interval), :interval,
           "must be a string when present"},
          {is_nil(limits.debit_amount) or is_nil(limits.receive_amount), :limits,
           "debitAmount and receiveAmount are mutually exclusive"},
          {Validation.extensions?(limits.extensions, @wire_fields), :extensions,
           "must be a JSON object with string keys and no reserved limit fields"}
        ],
        fn
          {true, _field, _message} -> []
          {false, field, message} -> [issue(field, message)]
        end
      )

    errors =
      errors ++
        amount_errors(limits.debit_amount, :debit_amount) ++
        amount_errors(limits.receive_amount, :receive_amount)

    case errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  defp exclusive(true), do: :ok

  defp exclusive(false),
    do: invalid([issue(:limits, "debitAmount and receiveAmount are mutually exclusive")])

  defp decode_amount(data, wire_field, field) do
    case Map.fetch(data, wire_field) do
      :error ->
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

  defp amount_errors(_value, field), do: [issue(field, "must be an Amount struct when present")]

  defp prefix(errors, parent) do
    Enum.map(errors, fn %{field: field} = error ->
      %{error | field: if(field == :amount, do: parent, else: "#{parent}.#{field}")}
    end)
  end

  defp put_optional(fields, _field, nil), do: fields
  defp put_optional(fields, field, value), do: Map.put(fields, field, value)
  defp put_amount(fields, _field, nil), do: fields
  defp put_amount(fields, field, amount), do: Map.put(fields, field, Amount.to_map(amount))
  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments outgoing-payment limits",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.OutgoingLimits do
  def encode(limits, opts) do
    limits |> OpenPayments.Types.OutgoingLimits.to_map() |> Jason.Encode.map(opts)
  end
end
