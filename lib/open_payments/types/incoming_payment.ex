defmodule OpenPayments.Types.IncomingPayment do
  @moduledoc """
  Detailed incoming-payment response data used by listing and completion.

  Follows the pinned `incoming-payment` schema: required id, completed,
  received_amount, created_at and wallet_address; optional incoming_amount,
  expires_at and JSON-object metadata. Omitted optional values become nil;
  explicit nulls are invalid. The schema's completed default does not replace its
  required-field rule. Amounts become typed `Amount` structs and permitted extra
  JSON fields are retained in `extensions`.

  URI fields and RFC 3339 timestamps keep their spelling, offsets and precision.
  This codec does not compare assets, amount values, timestamps or current time;
  operation-level payment consistency checks are separate. Payment methods are
  not declared by this detailed schema and remain uninterpreted extensions here.
  The create/authenticated-read schema additionally requires payment methods.

  Inspection omits amounts, metadata and extensions. Explicit map/JSON exports
  contain all protocol data, including any sensitive extension values. The type
  makes no requests. Validate modified structs with `validate/1`; `to_map/1`
  converts shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{Amount, Validation}

  @derive {Inspect, only: [:id, :completed, :created_at, :expires_at, :wallet_address]}
  @enforce_keys [:id, :completed, :received_amount, :created_at, :wallet_address]
  defstruct [
    :id,
    :completed,
    :received_amount,
    :created_at,
    :wallet_address,
    :incoming_amount,
    :expires_at,
    :metadata,
    extensions: %{}
  ]

  @wire_fields ~w(id completed receivedAmount createdAt walletAddress incomingAmount expiresAt metadata)

  @type t :: %__MODULE__{
          id: String.t(),
          completed: boolean(),
          received_amount: Amount.t(),
          created_at: String.t(),
          wallet_address: String.t(),
          incoming_amount: Amount.t() | nil,
          expires_at: String.t() | nil,
          metadata: %{optional(String.t()) => term()} | nil,
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Decodes detailed incoming-payment data without filling schema defaults."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    with {:ok, received} <- amount(data["receivedAmount"], :received_amount, &Amount.from_map/1),
         {:ok, incoming} <- optional_amount(data) do
      payment = %__MODULE__{
        id: data["id"],
        completed: data["completed"],
        received_amount: received,
        created_at: data["createdAt"],
        wallet_address: data["walletAddress"],
        incoming_amount: incoming,
        expires_at: data["expiresAt"],
        metadata: data["metadata"],
        extensions: Map.drop(data, @wire_fields)
      }

      case validate_fields(
             payment,
             Map.has_key?(data, "expiresAt"),
             Map.has_key?(data, "metadata")
           ) do
        :ok -> {:ok, payment}
        {:error, error} -> {:error, error}
      end
    end
  end

  def from_map(_data), do: invalid([issue(:incoming_payment, "must be a JSON object")])

  @doc "Revalidates typed amounts and detail fields, treating nil optional values as omitted."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = payment),
    do: validate_fields(payment, not is_nil(payment.expires_at), not is_nil(payment.metadata))

  @doc "Converts to protocol fields, including metadata/extensions, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = payment) do
    fields = %{
      "id" => payment.id,
      "completed" => payment.completed,
      "receivedAmount" => Amount.to_map(payment.received_amount),
      "createdAt" => payment.created_at,
      "walletAddress" => payment.wallet_address
    }

    fields =
      if is_nil(payment.incoming_amount),
        do: fields,
        else: Map.put(fields, "incomingAmount", Amount.to_map(payment.incoming_amount))

    fields =
      if is_nil(payment.expires_at),
        do: fields,
        else: Map.put(fields, "expiresAt", payment.expires_at)

    fields =
      if is_nil(payment.metadata), do: fields, else: Map.put(fields, "metadata", payment.metadata)

    payment.extensions |> Map.drop(@wire_fields) |> Map.merge(fields)
  end

  defp optional_amount(data) do
    if Map.has_key?(data, "incomingAmount"),
      do: amount(data["incomingAmount"], :incoming_amount, &Amount.from_map/1),
      else: {:ok, nil}
  end

  defp validate_fields(payment, expires_present?, metadata_present?) do
    checks = [
      {Validation.absolute_uri?(payment.id), :id, "must be an absolute URI"},
      {is_boolean(payment.completed), :completed, "must be a boolean"},
      {Validation.date_time?(payment.created_at), :created_at, "must be an RFC 3339 timestamp"},
      {Validation.absolute_uri?(payment.wallet_address), :wallet_address,
       "must be an absolute URI"},
      {not expires_present? or Validation.date_time?(payment.expires_at), :expires_at,
       "must be an RFC 3339 timestamp when present"},
      {not metadata_present? or Validation.extensions?(payment.metadata, []), :metadata,
       "must be a JSON object with string keys when present"},
      {Validation.extensions?(payment.extensions, @wire_fields), :extensions,
       "must be a JSON object with string keys and no reserved payment fields"}
    ]

    errors =
      Enum.flat_map(checks, fn
        {true, _field, _message} -> []
        {false, field, message} -> [issue(field, message)]
      end)

    errors =
      errors ++
        amount_errors(payment.received_amount, :received_amount) ++
        if(is_nil(payment.incoming_amount),
          do: [],
          else: amount_errors(payment.incoming_amount, :incoming_amount)
        )

    case errors do
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
    case Amount.validate(amount) do
      :ok -> {:ok, amount}
      {:error, error} -> {:error, error}
    end
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
         description: "Invalid Open Payments incoming payment",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.IncomingPayment do
  def encode(payment, opts) do
    payment |> OpenPayments.Types.IncomingPayment.to_map() |> Jason.Encode.map(opts)
  end
end
