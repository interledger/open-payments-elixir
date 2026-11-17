defmodule OpenPayments.Types.AccessToken do
  @moduledoc """
  An issued resource access token returned by an authorization server.

  The pinned schema requires an opaque string `value`, an absolute-URI `manage`
  endpoint and an ordered typed `access` list. Optional `expires_in` is an integer;
  omission becomes nil and explicit JSON null is rejected. The schema declares no
  minimum or maximum for expiry integers. Additional object fields are forbidden.

  Values, management URI spelling and expiry metadata are preserved. This type
  checks response data without imposing the request header's token68 alphabet or
  HTTP target policy. It does not track elapsed time, issue management requests,
  rotate tokens or compare access to a grant request.

  Inspection exposes only expiry metadata. Explicit `to_map/1` and JSON encoding
  contain the token and any nested card payloads. Errors retain safe field paths.
  Validate manually constructed or modified structs with `validate/1`;
  `to_map/1` converts shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{Access, Validation}

  @derive {Inspect, only: [:expires_in]}
  @enforce_keys [:value, :manage, :access]
  defstruct [:value, :manage, :access, :expires_in]

  @wire_fields ~w(value manage access expires_in)

  @type t :: %__MODULE__{
          value: String.t(),
          manage: String.t(),
          access: Access.t(),
          expires_in: integer() | nil
        }

  @doc "Decodes an issued token and its typed access entries."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    with {:ok, access} <- Access.from_list(data["access"]) do
      token = %__MODULE__{
        value: data["value"],
        manage: data["manage"],
        access: access,
        expires_in: data["expires_in"]
      }

      extra_errors =
        if map_size(Map.drop(data, @wire_fields)) == 0,
          do: [],
          else: [issue(:access_token, "must contain only value, manage, access and expires_in")]

      case validate_fields(token, Map.has_key?(data, "expires_in"), extra_errors) do
        :ok -> {:ok, token}
        {:error, error} -> {:error, error}
      end
    end
  end

  def from_map(_data), do: invalid([issue(:access_token, "must be a JSON object")])

  @doc "Validates issued token fields and revalidates all typed access entries."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = token),
    do: validate_fields(token, not is_nil(token.expires_in), [])

  @doc "Converts to protocol fields, including token/card values, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = token) do
    fields = %{
      "value" => token.value,
      "manage" => token.manage,
      "access" => Access.to_list(token.access)
    }

    if is_nil(token.expires_in), do: fields, else: Map.put(fields, "expires_in", token.expires_in)
  end

  defp validate_fields(token, expires_present?, extra_errors) do
    errors =
      Enum.flat_map(
        [
          {Validation.string?(token.value), :value, "must be a string"},
          {Validation.absolute_uri?(token.manage), :manage, "must be an absolute URI"},
          {not expires_present? or is_integer(token.expires_in), :expires_in,
           "must be an integer when present"}
        ],
        fn
          {true, _field, _message} -> []
          {false, field, message} -> [issue(field, message)]
        end
      )

    access_errors =
      case Access.validate(token.access) do
        :ok -> []
        {:error, error} -> error.validation_errors
      end

    case errors ++ access_errors ++ extra_errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments access token",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.AccessToken do
  def encode(token, opts) do
    token |> OpenPayments.Types.AccessToken.to_map() |> Jason.Encode.map(opts)
  end
end
