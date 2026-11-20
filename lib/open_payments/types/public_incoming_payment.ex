defmodule OpenPayments.Types.PublicIncomingPayment do
  @moduledoc """
  An incoming payment returned without an access token.

  Accepts the pinned `incoming-payment-without-access-token` schema and the
  minimal public shape used by the Node SDK and deployed servers: `authServer`
  with optional `receivedAmount`. Minimal responses leave detail fields nil.
  If any detail field is present, the complete pinned response is required,
  including unique payment methods. Amounts and ILP methods become typed structs.
  Omitted optional fields become nil; explicit nulls are invalid. Additional JSON
  fields are preserved in `extensions`.

  URI fields and RFC 3339 timestamps remain strings with their original spelling,
  offsets and fractional precision. Timestamp validation checks calendar/clock
  bounds; leap-second notation must fall in the final UTC minute of a month,
  without consulting a historical leap-second table. It does not compare expiration to creation or
  current time. Schema validation does not compare amounts or asset identities.

  Inspection omits payment methods and extensions. Explicit map/JSON exports
  include ILP shared secrets and must be treated as sensitive. This type makes
  no requests. Validate manually constructed or modified structs with `validate/1`;
  `to_map/1` converts their shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{Amount, ILPPaymentMethod, Validation}

  @derive {Inspect, only: [:id, :completed, :created_at, :expires_at, :auth_server]}
  @enforce_keys [:auth_server]
  defstruct [
    :id,
    :completed,
    :received_amount,
    :created_at,
    :methods,
    :auth_server,
    :incoming_amount,
    :expires_at,
    extensions: %{}
  ]

  @wire_fields ~w(id completed receivedAmount createdAt methods authServer incomingAmount expiresAt)
  @detail_fields ~w(id completed createdAt methods incomingAmount expiresAt)

  @type t :: %__MODULE__{
          id: String.t() | nil,
          completed: boolean() | nil,
          received_amount: Amount.t() | nil,
          created_at: String.t() | nil,
          methods: [ILPPaymentMethod.t()] | nil,
          auth_server: String.t(),
          incoming_amount: Amount.t() | nil,
          expires_at: String.t() | nil,
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Decodes a full pinned response or minimal public authorization information."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    if Enum.any?(@detail_fields, &Map.has_key?(data, &1)),
      do: from_full_map(data),
      else: from_minimal_map(data)
  end

  def from_map(_data), do: invalid([issue(:public_incoming_payment, "must be a JSON object")])

  @doc "Validates a full or minimal struct, treating nil optional fields as omitted."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = payment) do
    if minimal?(payment),
      do: validate_minimal(payment),
      else: validate_fields(payment, not is_nil(payment.expires_at))
  end

  @doc "Converts supplied protocol fields, including method secrets, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = payment) do
    if minimal?(payment), do: minimal_map(payment), else: full_map(payment)
  end

  defp from_full_map(data) do
    with {:ok, received} <- amount(data["receivedAmount"], :received_amount, &Amount.from_map/1),
         {:ok, incoming} <- incoming_amount(data),
         {:ok, methods} <- methods(data["methods"], &ILPPaymentMethod.from_map/1) do
      payment = %__MODULE__{
        id: data["id"],
        completed: data["completed"],
        received_amount: received,
        created_at: data["createdAt"],
        methods: methods,
        auth_server: data["authServer"],
        incoming_amount: incoming,
        expires_at: data["expiresAt"],
        extensions: Map.drop(data, @wire_fields)
      }

      case validate_fields(payment, Map.has_key?(data, "expiresAt")) do
        :ok -> {:ok, payment}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp from_minimal_map(data) do
    received =
      if Map.has_key?(data, "receivedAmount"),
        do: amount(data["receivedAmount"], :received_amount, &Amount.from_map/1),
        else: {:ok, nil}

    with {:ok, received} <- received do
      payment = %__MODULE__{
        auth_server: data["authServer"],
        received_amount: received,
        extensions: Map.drop(data, @wire_fields)
      }

      case validate_minimal(payment) do
        :ok -> {:ok, payment}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp minimal?(payment),
    do:
      Enum.all?(
        [:id, :completed, :created_at, :methods, :incoming_amount, :expires_at],
        &is_nil(Map.fetch!(payment, &1))
      )

  defp validate_minimal(payment) do
    errors =
      if Validation.absolute_uri?(payment.auth_server),
        do: [],
        else: [issue(:auth_server, "must be an absolute URI")]

    errors =
      if Validation.extensions?(payment.extensions, @wire_fields),
        do: errors,
        else:
          errors ++
            [
              issue(
                :extensions,
                "must be a JSON object with string keys and no reserved payment fields"
              )
            ]

    errors =
      if is_nil(payment.received_amount),
        do: errors,
        else:
          errors ++
            result_errors(amount(payment.received_amount, :received_amount, &validate_amount/1))

    case errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  defp minimal_map(payment) do
    fields = %{"authServer" => payment.auth_server}

    fields =
      if is_nil(payment.received_amount),
        do: fields,
        else: Map.put(fields, "receivedAmount", Amount.to_map(payment.received_amount))

    payment.extensions |> Map.drop(@wire_fields) |> Map.merge(fields)
  end

  defp full_map(payment) do
    fields = %{
      "id" => payment.id,
      "completed" => payment.completed,
      "receivedAmount" => Amount.to_map(payment.received_amount),
      "createdAt" => payment.created_at,
      "methods" => Enum.map(payment.methods, &ILPPaymentMethod.to_map/1),
      "authServer" => payment.auth_server
    }

    fields =
      if is_nil(payment.incoming_amount),
        do: fields,
        else: Map.put(fields, "incomingAmount", Amount.to_map(payment.incoming_amount))

    fields =
      if is_nil(payment.expires_at),
        do: fields,
        else: Map.put(fields, "expiresAt", payment.expires_at)

    payment.extensions |> Map.drop(@wire_fields) |> Map.merge(fields)
  end

  defp incoming_amount(data) do
    if Map.has_key?(data, "incomingAmount"),
      do: amount(data["incomingAmount"], :incoming_amount, &Amount.from_map/1),
      else: {:ok, nil}
  end

  defp validate_fields(payment, expires_present?) do
    errors =
      Enum.flat_map(
        [
          {Validation.absolute_uri?(payment.id), :id, "must be an absolute URI"},
          {is_boolean(payment.completed), :completed, "must be a boolean"},
          {Validation.date_time?(payment.created_at), :created_at,
           "must be an RFC 3339 timestamp"},
          {Validation.absolute_uri?(payment.auth_server), :auth_server,
           "must be an absolute URI"},
          {not expires_present? or Validation.date_time?(payment.expires_at), :expires_at,
           "must be an RFC 3339 timestamp when present"},
          {Validation.extensions?(payment.extensions, @wire_fields), :extensions,
           "must be a JSON object with string keys and no reserved payment fields"}
        ],
        fn
          {true, _field, _message} -> []
          {false, field, message} -> [issue(field, message)]
        end
      )

    nested_errors =
      result_errors(amount(payment.received_amount, :received_amount, &validate_amount/1)) ++
        result_errors(methods(payment.methods, &validate_method/1)) ++
        if(is_nil(payment.incoming_amount),
          do: [],
          else:
            result_errors(amount(payment.incoming_amount, :incoming_amount, &validate_amount/1))
        )

    case errors ++ nested_errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  defp amount(value, field, decoder) do
    case decoder.(value) do
      {:ok, amount} -> {:ok, amount}
      {:error, error} -> invalid(prefix(error.validation_errors, field, :amount))
    end
  end

  defp validate_amount(%Amount{} = amount), do: validated(amount, Amount.validate(amount))
  defp validate_amount(_value), do: invalid([issue(:amount, "must be an Amount struct")])

  defp validate_method(%ILPPaymentMethod{} = method),
    do: validated(method, ILPPaymentMethod.validate(method))

  defp validate_method(_value),
    do: invalid([issue(:payment_method, "must be an ILPPaymentMethod struct")])

  defp validated(value, :ok), do: {:ok, value}
  defp validated(_value, {:error, error}), do: {:error, error}

  defp methods(values, decoder) when is_list(values) do
    {converted, errors} =
      values
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {value, index}, {converted, errors} ->
        case decoder.(value) do
          {:ok, method} ->
            {[method | converted], errors}

          {:error, error} ->
            {converted,
             errors ++ prefix(error.validation_errors, "methods[#{index}]", :payment_method)}
        end
      end)

    errors =
      if length(Enum.uniq(values)) == length(values),
        do: errors,
        else: errors ++ [issue(:methods, "must contain unique payment methods")]

    case errors do
      [] -> {:ok, Enum.reverse(converted)}
      errors -> invalid(errors)
    end
  end

  defp methods(_values, _decoder), do: invalid([issue(:methods, "must be an array")])

  defp prefix(errors, parent, root) do
    Enum.map(errors, fn %{field: field} = error ->
      %{error | field: if(field == root, do: parent, else: "#{parent}.#{field}")}
    end)
  end

  defp result_errors({:ok, _value}), do: []
  defp result_errors({:error, error}), do: error.validation_errors
  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments public incoming payment",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.PublicIncomingPayment do
  def encode(payment, opts) do
    payment |> OpenPayments.Types.PublicIncomingPayment.to_map() |> Jason.Encode.map(opts)
  end
end
