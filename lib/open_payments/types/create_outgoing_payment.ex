defmodule OpenPayments.Types.CreateOutgoingPayment do
  @moduledoc """
  The strict payload for creating an outgoing payment using either supported form.

  Supply wallet_address with quote_id, or with incoming_payment and a typed
  debit_amount. These forms are mutually exclusive and no amountless direct form
  is allowed, matching the pinned oneOf branches and Node's creation argument
  union. Optional metadata is a JSON object; empty objects are retained.

  Map input uses protocol JSON names and permits no additional fields. Variant
  selection uses field presence, so explicit null cannot silently select another
  form. In typed structs nil means omission. Explicit map nulls are invalid.
  URI fields use absolute-URI data validation; incoming_payment does not use the
  response receiver's incoming-payment path pattern. URI and decimal spelling,
  permitted nested amount extensions and metadata are preserved.

  This codec does not resolve payment pointers, fetch a quote/wallet/receiver,
  infer amounts, compare wallet assets, require positive values, calculate fees
  or exchange rates, or apply network request-target policies to URI data. The
  server needs context to check quote validity, wallet-asset compatibility and
  authorization. This type makes no requests or payments.

  Inspection omits payload fields. Explicit map/JSON exports include wallet,
  quote/incoming-payment references, amounts and metadata. Errors retain safe
  field paths without rejected values or unknown names. Validate constructed or
  modified structs with `validate/1`; `to_map/1` converts without validating.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{Amount, Validation}

  @derive {Inspect, only: []}
  @enforce_keys [:wallet_address]
  defstruct [:wallet_address, :quote_id, :incoming_payment, :debit_amount, :metadata]

  @wire_fields ~w(walletAddress quoteId incomingPayment debitAmount metadata)

  @type t :: %__MODULE__{
          wallet_address: String.t(),
          quote_id: String.t() | nil,
          incoming_payment: String.t() | nil,
          debit_amount: Amount.t() | nil,
          metadata: %{optional(String.t()) => term()} | nil
        }

  @doc "Decodes a strict quote-based or incoming-payment-based creation request."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    with {:ok, form} <-
           variant(
             Map.has_key?(data, "quoteId"),
             Map.has_key?(data, "incomingPayment"),
             Map.has_key?(data, "debitAmount")
           ),
         {:ok, debit} <- decode_amount(data) do
      request = %__MODULE__{
        wallet_address: data["walletAddress"],
        quote_id: data["quoteId"],
        incoming_payment: data["incomingPayment"],
        debit_amount: debit,
        metadata: data["metadata"]
      }

      extra_errors =
        if map_size(Map.drop(data, @wire_fields)) == 0,
          do: [],
          else: [
            issue(:create_outgoing_payment, "must contain only declared outgoing creation fields")
          ]

      case validate_fields(request, form, Map.has_key?(data, "metadata"), extra_errors) do
        :ok -> {:ok, request}
        {:error, error} -> {:error, error}
      end
    end
  end

  def from_map(_data), do: invalid([issue(:create_outgoing_payment, "must be a JSON object")])

  @doc "Revalidates the typed variant, references, nested amount and metadata."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = request) do
    with {:ok, form} <-
           variant(
             not is_nil(request.quote_id),
             not is_nil(request.incoming_payment),
             not is_nil(request.debit_amount)
           ) do
      validate_fields(request, form, not is_nil(request.metadata), [])
    end
  end

  @doc "Exports protocol payload fields without validation, defaults or lookups."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = request) do
    fields =
      Enum.reduce(
        [
          {"quoteId", request.quote_id},
          {"incomingPayment", request.incoming_payment},
          {"metadata", request.metadata}
        ],
        %{"walletAddress" => request.wallet_address},
        fn
          {_name, nil}, fields -> fields
          {name, value}, fields -> Map.put(fields, name, value)
        end
      )

    if is_nil(request.debit_amount),
      do: fields,
      else: Map.put(fields, "debitAmount", Amount.to_map(request.debit_amount))
  end

  defp variant(true, false, false), do: {:ok, :quote}
  defp variant(false, true, true), do: {:ok, :incoming}

  defp variant(_quote, _incoming, _debit),
    do:
      invalid([
        issue(
          :create_outgoing_payment,
          "must supply either quoteId or both incomingPayment and debitAmount"
        )
      ])

  defp validate_fields(request, form, metadata_present?, extra_errors) do
    checks = [
      {Validation.absolute_uri?(request.wallet_address), :wallet_address,
       "must be an absolute URI"},
      {form != :quote or Validation.absolute_uri?(request.quote_id), :quote_id,
       "must be an absolute URI"},
      {form != :incoming or Validation.absolute_uri?(request.incoming_payment), :incoming_payment,
       "must be an absolute URI"},
      {not metadata_present? or Validation.extensions?(request.metadata, []), :metadata,
       "must be a JSON object with string keys when present"}
    ]

    errors =
      Enum.flat_map(checks, fn
        {true, _field, _message} -> []
        {false, field, message} -> [issue(field, message)]
      end)

    case errors ++ amount_errors(request.debit_amount) ++ extra_errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  defp decode_amount(data) do
    case Map.fetch(data, "debitAmount") do
      :error ->
        {:ok, nil}

      {:ok, value} ->
        case Amount.from_map(value) do
          {:ok, amount} -> {:ok, amount}
          {:error, error} -> invalid(prefix(error.validation_errors))
        end
    end
  end

  defp amount_errors(nil), do: []

  defp amount_errors(%Amount{} = amount) do
    case Amount.validate(amount) do
      :ok -> []
      {:error, error} -> prefix(error.validation_errors)
    end
  end

  defp amount_errors(_amount), do: [issue(:debit_amount, "must be an Amount struct")]

  defp prefix(errors) do
    Enum.map(errors, fn %{field: field} = error ->
      %{error | field: if(field == :amount, do: :debit_amount, else: "debit_amount.#{field}")}
    end)
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments outgoing-payment creation request",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.CreateOutgoingPayment do
  def encode(request, opts) do
    request |> OpenPayments.Types.CreateOutgoingPayment.to_map() |> Jason.Encode.map(opts)
  end
end
