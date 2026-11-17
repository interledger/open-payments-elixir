defmodule OpenPayments.Types.AccessTokenRequest do
  @moduledoc """
  Resource access requested through a grant request's `access_token` field.

  Required `access` is an ordered list of typed access entries, validated by
  `OpenPayments.Types.Access`. The pinned schema permits additional JSON fields,
  which are retained in `extensions`. Empty access arrays remain valid.

  Inspection omits all values because access can contain card authorization data.
  Explicit map/JSON export includes the protocol payload. This type does not
  issue, store or manage access tokens. Validate manually modified structs with
  `validate/1`; `to_map/1` converts shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{Access, Validation}

  @derive {Inspect, only: []}
  @enforce_keys [:access]
  defstruct [:access, extensions: %{}]

  @type t :: %__MODULE__{access: Access.t(), extensions: %{optional(String.t()) => term()}}

  @doc "Decodes the requested access array and preserves permitted extension fields."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    with {:ok, access} <- Access.from_list(data["access"]) do
      request = %__MODULE__{access: access, extensions: Map.drop(data, ["access"])}

      case validate(request) do
        :ok -> {:ok, request}
        {:error, error} -> {:error, error}
      end
    end
  end

  def from_map(_data), do: invalid([issue(:access_token_request, "must be a JSON object")])

  @doc "Revalidates typed access entries, array constraints and extension fields."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = request) do
    access_errors =
      case Access.validate(request.access) do
        :ok -> []
        {:error, error} -> error.validation_errors
      end

    extension_errors =
      if Validation.extensions?(request.extensions, ["access"]),
        do: [],
        else: [
          issue(
            :extensions,
            "must be a JSON object with string keys and no reserved access field"
          )
        ]

    case access_errors ++ extension_errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  @doc "Converts to grant protocol fields, including card payloads, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = request) do
    request.extensions
    |> Map.drop(["access"])
    |> Map.put("access", Access.to_list(request.access))
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments access-token request",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.AccessTokenRequest do
  def encode(request, opts) do
    request |> OpenPayments.Types.AccessTokenRequest.to_map() |> Jason.Encode.map(opts)
  end
end
