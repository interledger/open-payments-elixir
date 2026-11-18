defmodule OpenPayments.Types.TokenRotationResponse do
  @moduledoc """
  The response to rotating an issued access token.

  Required `access_token` becomes an `AccessToken`; permitted additional JSON
  fields remain in `extensions`. The wrapper is retained, matching the wire
  response and Node's rotate result. All nested access entries are validated.

  Inspection omits payload values; explicit map/JSON exports include the token
  and any card results. This codec does not update a client, persist a token,
  assess expiry or compare old/new access. Validate modified structs with
  `validate/1`; `to_map/1` converts shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{AccessToken, Validation}

  @derive {Inspect, only: []}
  @enforce_keys [:access_token]
  defstruct [:access_token, extensions: %{}]

  @wire_fields ["access_token"]

  @type t :: %__MODULE__{
          access_token: AccessToken.t(),
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Decodes the issued token wrapper and preserves permitted JSON extensions."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    case AccessToken.from_map(data["access_token"]) do
      {:ok, token} ->
        response = %__MODULE__{access_token: token, extensions: Map.drop(data, @wire_fields)}

        case validate(response) do
          :ok -> {:ok, response}
          {:error, error} -> {:error, error}
        end

      {:error, error} ->
        invalid(prefix(error.validation_errors))
    end
  end

  def from_map(_data), do: invalid([issue(:token_rotation_response, "must be a JSON object")])

  @doc "Revalidates the issued token and JSON extension data."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = response) do
    extension_errors =
      if Validation.extensions?(response.extensions, @wire_fields),
        do: [],
        else: [
          issue(
            :extensions,
            "must be a JSON object with string keys and no reserved token response fields"
          )
        ]

    case token_errors(response.access_token) ++ extension_errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  @doc "Converts to protocol fields, including token/card values, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = response),
    do:
      response.extensions
      |> Map.drop(@wire_fields)
      |> Map.put("access_token", AccessToken.to_map(response.access_token))

  defp token_errors(%AccessToken{} = token) do
    case AccessToken.validate(token) do
      :ok -> []
      {:error, error} -> prefix(error.validation_errors)
    end
  end

  defp token_errors(_token), do: [issue(:access_token, "must be an AccessToken struct")]

  defp prefix(errors) do
    Enum.map(errors, fn %{field: field} = error ->
      %{
        error
        | field: if(field == :access_token, do: :access_token, else: "access_token.#{field}")
      }
    end)
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments token rotation response",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.TokenRotationResponse do
  def encode(response, opts) do
    response |> OpenPayments.Types.TokenRotationResponse.to_map() |> Jason.Encode.map(opts)
  end
end
