defmodule OpenPayments.Types.ContinuationToken do
  @moduledoc """
  The credential in a grant response's `continue.access_token` field.

  The pinned schema requires a string `value` and permits additional JSON data,
  retained in `extensions`. Value spelling is preserved without applying the
  outgoing request header's token68 validation. This credential is typed separately
  from issued resource access tokens and makes no network requests.

  Inspection omits values and extensions. Explicit map/JSON exports include the
  token. Errors retain safe field names. Validate manually modified structs with
  `validate/1`; `to_map/1` converts shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.Validation

  @derive {Inspect, only: []}
  @enforce_keys [:value]
  defstruct [:value, extensions: %{}]

  @type t :: %__MODULE__{value: String.t(), extensions: %{optional(String.t()) => term()}}

  @doc "Decodes a continuation credential and preserves permitted extension data."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    token = %__MODULE__{value: data["value"], extensions: Map.drop(data, ["value"])}

    case validate(token) do
      :ok -> {:ok, token}
      {:error, error} -> {:error, error}
    end
  end

  def from_map(_data), do: invalid([issue(:continuation_token, "must be a JSON object")])

  @doc "Validates token and JSON extension fields without retaining values in errors."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = token) do
    errors =
      Enum.flat_map(
        [
          {Validation.string?(token.value), :value, "must be a string"},
          {Validation.extensions?(token.extensions, ["value"]), :extensions,
           "must be a JSON object with string keys and no reserved token value field"}
        ],
        fn
          {true, _field, _message} -> []
          {false, field, message} -> [issue(field, message)]
        end
      )

    case errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  @doc "Converts to protocol fields, including the token value, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = token),
    do: token.extensions |> Map.drop(["value"]) |> Map.put("value", token.value)

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments continuation token",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.ContinuationToken do
  def encode(token, opts) do
    token |> OpenPayments.Types.ContinuationToken.to_map() |> Jason.Encode.map(opts)
  end
end
