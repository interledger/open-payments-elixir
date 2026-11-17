defmodule OpenPayments.Types.Continuation do
  @moduledoc """
  Continuation data returned in a grant response's `continue` field.

  Required `access_token` becomes a typed `ContinuationToken`; required `uri`
  follows the schema's absolute-URI format and keeps its spelling. Optional `wait`
  retains integer seconds as supplied, with no minimum or maximum declared by the
  pinned schema. Omission becomes nil; explicit JSON null is invalid. Additional
  JSON fields are retained in `extensions` at both object levels.

  This type decodes response data without sleeping, polling, signing or making
  requests. Timing and outgoing URL/header policy belong to continuation use.
  Inspection exposes only wait metadata. Explicit map/JSON exports include the
  continuation credential. Validate modified structs with `validate/1`;
  `to_map/1` converts shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{ContinuationToken, Validation}

  @derive {Inspect, only: [:wait]}
  @enforce_keys [:access_token, :uri]
  defstruct [:access_token, :uri, :wait, extensions: %{}]

  @wire_fields ~w(access_token uri wait)

  @type t :: %__MODULE__{
          access_token: ContinuationToken.t(),
          uri: String.t(),
          wait: integer() | nil,
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Decodes a continuation URI, credential and optional wait metadata."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    with {:ok, token} <- decode_token(data["access_token"]) do
      continuation = %__MODULE__{
        access_token: token,
        uri: data["uri"],
        wait: data["wait"],
        extensions: Map.drop(data, @wire_fields)
      }

      case validate_fields(continuation, Map.has_key?(data, "wait")) do
        :ok -> {:ok, continuation}
        {:error, error} -> {:error, error}
      end
    end
  end

  def from_map(_data), do: invalid([issue(:continuation, "must be a JSON object")])

  @doc "Revalidates typed continuation data, treating nil wait as omitted."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = continuation),
    do: validate_fields(continuation, not is_nil(continuation.wait))

  @doc "Converts to protocol fields, including the continuation token, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = continuation) do
    fields = %{
      "access_token" => ContinuationToken.to_map(continuation.access_token),
      "uri" => continuation.uri
    }

    fields =
      if is_nil(continuation.wait), do: fields, else: Map.put(fields, "wait", continuation.wait)

    continuation.extensions |> Map.drop(@wire_fields) |> Map.merge(fields)
  end

  defp decode_token(value) do
    case ContinuationToken.from_map(value) do
      {:ok, token} -> {:ok, token}
      {:error, error} -> invalid(prefix(error.validation_errors))
    end
  end

  defp validate_fields(continuation, wait_present?) do
    errors =
      Enum.flat_map(
        [
          {Validation.absolute_uri?(continuation.uri), :uri, "must be an absolute URI"},
          {not wait_present? or is_integer(continuation.wait), :wait,
           "must be an integer when present"},
          {Validation.extensions?(continuation.extensions, @wire_fields), :extensions,
           "must be a JSON object with string keys and no reserved continuation fields"}
        ],
        fn
          {true, _field, _message} -> []
          {false, field, message} -> [issue(field, message)]
        end
      )

    case errors ++ token_errors(continuation.access_token) do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  defp token_errors(%ContinuationToken{} = token) do
    case ContinuationToken.validate(token) do
      :ok -> []
      {:error, error} -> prefix(error.validation_errors)
    end
  end

  defp token_errors(_token), do: [issue(:access_token, "must be a ContinuationToken struct")]

  defp prefix(errors) do
    Enum.map(errors, fn %{field: field} = error ->
      %{
        error
        | field:
            if(field == :continuation_token, do: :access_token, else: "access_token.#{field}")
      }
    end)
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments continuation data",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.Continuation do
  def encode(continuation, opts) do
    continuation |> OpenPayments.Types.Continuation.to_map() |> Jason.Encode.map(opts)
  end
end
