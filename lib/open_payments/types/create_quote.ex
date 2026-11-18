defmodule OpenPayments.Types.CreateQuote do
  @moduledoc """
  The strict payload for creating a quote using one of three amount variants.

  Required wallet_address is absolute-URI data, receiver follows the shared
  HTTP(S) incoming-payment URI pattern, and method must be the string ilp.
  Supply a typed debit_amount, a typed receive_amount, or neither for a quote
  whose amount can be inferred from the receiver. Both amounts are forbidden,
  matching the pinned oneOf branches and Node's CreateQuoteArgs union.

  Map input uses protocol JSON names with no additional fields. Omitted amounts
  become nil and are omitted on export; explicit nulls are invalid. Typed nil
  amounts mean omission. Neither variant is defaulted and no amount is generated.
  Permitted nested amount extensions and URI/decimal spelling are preserved.

  The server must check that an amountless receiver has an incoming amount and
  enforce wallet/receiver asset compatibility and other operation permissions.
  This codec does not fetch those resources, resolve payment pointers, impose
  network request-target policies on URI data, require positive amounts, compare
  assets or calculate exchange rates/fees. Quote responses require both amounts
  and use the separate `Quote` type.

  Inspection exposes only method. Explicit map/JSON exports include wallet,
  receiver and amount data. Errors retain safe field paths without rejected
  values or unknown names. Validate manually constructed or modified structs
  with `validate/1`; `to_map/1` converts without validating. No HTTP requests occur.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{Amount, Validation}

  @derive {Inspect, only: [:method]}
  @enforce_keys [:wallet_address, :receiver, :method]
  defstruct [:wallet_address, :receiver, :method, :debit_amount, :receive_amount]

  @wire_fields ~w(walletAddress receiver method debitAmount receiveAmount)

  @type t :: %__MODULE__{
          wallet_address: String.t(),
          receiver: String.t(),
          method: String.t(),
          debit_amount: Amount.t() | nil,
          receive_amount: Amount.t() | nil
        }

  @doc "Decodes a receiver-inferred, fixed-debit or fixed-receive quote request."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    with :ok <-
           exclusive(
             not Map.has_key?(data, "debitAmount") or not Map.has_key?(data, "receiveAmount")
           ),
         {:ok, debit} <- optional_amount(data, "debitAmount", :debit_amount),
         {:ok, receive} <- optional_amount(data, "receiveAmount", :receive_amount) do
      request = %__MODULE__{
        wallet_address: data["walletAddress"],
        receiver: data["receiver"],
        method: data["method"],
        debit_amount: debit,
        receive_amount: receive
      }

      extra_errors =
        if map_size(Map.drop(data, @wire_fields)) == 0,
          do: [],
          else: [issue(:create_quote, "must contain only declared quote creation fields")]

      case validate_fields(request, extra_errors) do
        :ok -> {:ok, request}
        {:error, error} -> {:error, error}
      end
    end
  end

  def from_map(_data), do: invalid([issue(:create_quote, "must be a JSON object")])

  @doc "Revalidates the typed request, its amount variant and any nested amount."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = request), do: validate_fields(request, [])

  @doc "Exports protocol fields and present amounts without validating or adding defaults."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = request) do
    %{
      "walletAddress" => request.wallet_address,
      "receiver" => request.receiver,
      "method" => request.method
    }
    |> put_amount("debitAmount", request.debit_amount)
    |> put_amount("receiveAmount", request.receive_amount)
  end

  defp validate_fields(request, extra_errors) do
    checks = [
      {Validation.absolute_uri?(request.wallet_address), :wallet_address,
       "must be an absolute URI"},
      {Validation.incoming_payment_uri?(request.receiver), :receiver,
       "must be an HTTP(S) incoming-payment URI"},
      {request.method == "ilp", :method, "must be ilp"},
      {is_nil(request.debit_amount) or is_nil(request.receive_amount), :create_quote,
       "debitAmount and receiveAmount are mutually exclusive"}
    ]

    errors =
      Enum.flat_map(checks, fn
        {true, _field, _message} -> []
        {false, field, message} -> [issue(field, message)]
      end)

    case errors ++
           amount_errors(request.debit_amount, :debit_amount) ++
           amount_errors(request.receive_amount, :receive_amount) ++ extra_errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  defp optional_amount(data, name, field) do
    case Map.fetch(data, name) do
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

  defp amount_errors(_amount, field), do: [issue(field, "must be an Amount struct when present")]

  defp exclusive(true), do: :ok

  defp exclusive(false),
    do: invalid([issue(:create_quote, "debitAmount and receiveAmount are mutually exclusive")])

  defp prefix(errors, parent) do
    Enum.map(errors, fn %{field: field} = error ->
      %{error | field: if(field == :amount, do: parent, else: "#{parent}.#{field}")}
    end)
  end

  defp put_amount(fields, _field, nil), do: fields
  defp put_amount(fields, field, amount), do: Map.put(fields, field, Amount.to_map(amount))
  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments quote creation request",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.CreateQuote do
  def encode(request, opts) do
    request |> OpenPayments.Types.CreateQuote.to_map() |> Jason.Encode.map(opts)
  end
end
