defmodule OpenPayments.Types.CreateIncomingPayment do
  @moduledoc """
  The JSON payload for creating an incoming payment.

  Follows `create-incoming-payment-request`: required absolute-URI wallet_address,
  optional typed incoming_amount, RFC 3339 expires_at and JSON-object metadata.
  Omitted optional fields become nil and are omitted on export; explicit JSON
  nulls and additional top-level fields are invalid. Empty metadata is retained.

  URI/timestamp spelling and amount data are preserved. This codec does not
  resolve payment pointers, fetch a wallet, compare wallet assets, require a
  positive amount or compare expiry with the current time. Wallet-asset matching
  and other operation-level checks need context beyond this payload.

  Inspection exposes only expiry metadata. Explicit map/JSON exports include the
  wallet, amount and metadata values. Errors retain safe field paths without
  rejected data. Validate modified structs with `validate/1`; `to_map/1` converts
  shape without validating it. This type makes no HTTP requests.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{Amount, Validation}

  @derive {Inspect, only: [:expires_at]}
  @enforce_keys [:wallet_address]
  defstruct [:wallet_address, :incoming_amount, :expires_at, :metadata]

  @wire_fields ~w(walletAddress incomingAmount expiresAt metadata)

  @type t :: %__MODULE__{
          wallet_address: String.t(),
          incoming_amount: Amount.t() | nil,
          expires_at: String.t() | nil,
          metadata: %{optional(String.t()) => term()} | nil
        }

  @doc "Decodes the strict creation payload and its optional typed amount."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    with {:ok, incoming} <- optional_amount(data) do
      request = %__MODULE__{
        wallet_address: data["walletAddress"],
        incoming_amount: incoming,
        expires_at: data["expiresAt"],
        metadata: data["metadata"]
      }

      extra_errors =
        if map_size(Map.drop(data, @wire_fields)) == 0,
          do: [],
          else: [
            issue(
              :create_incoming_payment,
              "must contain only walletAddress, incomingAmount, expiresAt and metadata"
            )
          ]

      case validate_fields(
             request,
             Map.has_key?(data, "expiresAt"),
             Map.has_key?(data, "metadata"),
             extra_errors
           ) do
        :ok -> {:ok, request}
        {:error, error} -> {:error, error}
      end
    end
  end

  def from_map(_data), do: invalid([issue(:create_incoming_payment, "must be a JSON object")])

  @doc "Revalidates typed payload fields, treating nil optional values as omitted."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = request),
    do: validate_fields(request, not is_nil(request.expires_at), not is_nil(request.metadata), [])

  @doc "Converts to protocol fields, including metadata, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = request) do
    fields = %{"walletAddress" => request.wallet_address}

    fields =
      if is_nil(request.incoming_amount),
        do: fields,
        else: Map.put(fields, "incomingAmount", Amount.to_map(request.incoming_amount))

    fields =
      if is_nil(request.expires_at),
        do: fields,
        else: Map.put(fields, "expiresAt", request.expires_at)

    if is_nil(request.metadata), do: fields, else: Map.put(fields, "metadata", request.metadata)
  end

  defp optional_amount(data) do
    if Map.has_key?(data, "incomingAmount"),
      do: decode_amount(data["incomingAmount"]),
      else: {:ok, nil}
  end

  defp decode_amount(value) do
    case Amount.from_map(value) do
      {:ok, amount} -> {:ok, amount}
      {:error, error} -> invalid(prefix(error.validation_errors))
    end
  end

  defp validate_fields(request, expires_present?, metadata_present?, extra_errors) do
    checks = [
      {Validation.absolute_uri?(request.wallet_address), :wallet_address,
       "must be an absolute URI"},
      {not expires_present? or Validation.date_time?(request.expires_at), :expires_at,
       "must be an RFC 3339 timestamp when present"},
      {not metadata_present? or Validation.extensions?(request.metadata, []), :metadata,
       "must be a JSON object with string keys when present"}
    ]

    errors =
      Enum.flat_map(checks, fn
        {true, _field, _message} -> []
        {false, field, message} -> [issue(field, message)]
      end)

    case errors ++ amount_errors(request.incoming_amount) ++ extra_errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  defp amount_errors(nil), do: []

  defp amount_errors(%Amount{} = amount) do
    case Amount.validate(amount) do
      :ok -> []
      {:error, error} -> prefix(error.validation_errors)
    end
  end

  defp amount_errors(_amount),
    do: [issue(:incoming_amount, "must be an Amount struct when present")]

  defp prefix(errors) do
    Enum.map(errors, fn %{field: field} = error ->
      %{
        error
        | field: if(field == :amount, do: :incoming_amount, else: "incoming_amount.#{field}")
      }
    end)
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments incoming-payment creation request",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.CreateIncomingPayment do
  def encode(request, opts) do
    request |> OpenPayments.Types.CreateIncomingPayment.to_map() |> Jason.Encode.map(opts)
  end
end
