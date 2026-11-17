defmodule OpenPayments.Types.GrantRequest do
  @moduledoc """
  A complete grant initiation request with typed client, access, interaction and
  subject data.

  A client identity is required. The pinned `anyOf` contract allows an access-token
  request, or a subject request with interaction, or both. Subject information
  alongside an access-token request does not itself require interaction.
  Directed JWK identity cannot be combined with an explicit `interact` field,
  following the specification's non-interactive restriction.

  Omitted optional fields become nil; explicit JSON nulls are rejected.
  Additional JSON fields are retained in `extensions` at the root and nested
  access-token-request level. Known wire names and nested string/object forms are
  preserved. All nested models and access entries are revalidated by `validate/1`.

  Inspection omits payload values. Explicit map/JSON exports contain nonces,
  subject identifiers and any card data. This type does not fetch keys, match a
  directed JWK to a configured signing key, sign or send a request, or verify a
  callback. `to_map/1` converts shape without validating it.
  """

  alias OpenPayments.Error

  alias OpenPayments.Types.{
    AccessTokenRequest,
    GrantClient,
    InteractionRequest,
    Subject,
    Validation
  }

  @derive {Inspect, only: []}
  @enforce_keys [:client]
  defstruct [:client, :access_token, :interact, :subject, extensions: %{}]

  @wire_fields ~w(client access_token interact subject)

  @type t :: %__MODULE__{
          client: GrantClient.t(),
          access_token: AccessTokenRequest.t() | nil,
          interact: InteractionRequest.t() | nil,
          subject: Subject.t() | nil,
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Decodes a complete grant request and validates its nested models and variant."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    with {:ok, client} <- nested(GrantClient.from_value(data["client"]), :client, :client),
         {:ok, token} <- optional(data, :access_token, AccessTokenRequest, :access_token_request),
         {:ok, interact} <- optional(data, :interact, InteractionRequest, :interaction_request),
         {:ok, subject} <- optional(data, :subject, Subject, :subject) do
      request = %__MODULE__{
        client: client,
        access_token: token,
        interact: interact,
        subject: subject,
        extensions: Map.drop(data, @wire_fields)
      }

      case validate(request) do
        :ok -> {:ok, request}
        {:error, error} -> {:error, error}
      end
    end
  end

  def from_map(_data), do: invalid([issue(:grant_request, "must be a JSON object")])

  @doc "Revalidates typed nested fields, request variants and extension rules."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = request) do
    extension_errors =
      if Validation.extensions?(request.extensions, @wire_fields),
        do: [],
        else: [
          issue(
            :extensions,
            "must be a JSON object with string keys and no reserved grant fields"
          )
        ]

    errors =
      client_errors(request.client) ++
        token_errors(request.access_token) ++
        interaction_errors(request.interact) ++
        subject_errors(request.subject) ++
        variant_errors(request) ++ directed_errors(request) ++ extension_errors

    case errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  @doc "Converts to a complete protocol request, including sensitive fields, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = request) do
    fields =
      %{"client" => GrantClient.to_value(request.client)}
      |> put_optional("access_token", request.access_token, &AccessTokenRequest.to_map/1)
      |> put_optional("interact", request.interact, &InteractionRequest.to_map/1)
      |> put_optional("subject", request.subject, &Subject.to_map/1)

    request.extensions |> Map.drop(@wire_fields) |> Map.merge(fields)
  end

  defp optional(data, field, decoder, root) do
    case Map.fetch(data, Atom.to_string(field)) do
      :error -> {:ok, nil}
      {:ok, value} -> nested(decoder.from_map(value), field, root)
    end
  end

  defp nested({:ok, value}, _parent, _root), do: {:ok, value}

  defp nested({:error, error}, parent, root),
    do: invalid(prefix(error.validation_errors, parent, root))

  defp client_errors(%GrantClient{} = client),
    do: errors(GrantClient.validate(client), :client, :client)

  defp client_errors(_client), do: [issue(:client, "must be a GrantClient struct")]

  defp token_errors(nil), do: []

  defp token_errors(%AccessTokenRequest{} = token),
    do: errors(AccessTokenRequest.validate(token), :access_token, :access_token_request)

  defp token_errors(_token),
    do: [issue(:access_token, "must be an AccessTokenRequest struct when present")]

  defp interaction_errors(nil), do: []

  defp interaction_errors(%InteractionRequest{} = interact),
    do: errors(InteractionRequest.validate(interact), :interact, :interaction_request)

  defp interaction_errors(_interact),
    do: [issue(:interact, "must be an InteractionRequest struct when present")]

  defp subject_errors(nil), do: []

  defp subject_errors(%Subject{} = subject),
    do: errors(Subject.validate(subject), :subject, :subject)

  defp subject_errors(_subject), do: [issue(:subject, "must be a Subject struct when present")]

  defp variant_errors(request) do
    cond do
      not is_nil(request.access_token) ->
        []

      is_nil(request.subject) ->
        [issue(:grant_request, "must request access_token or subject")]

      is_nil(request.interact) ->
        [issue(:interact, "must be provided for a subject-only request")]

      true ->
        []
    end
  end

  defp directed_errors(%__MODULE__{
         client: %GrantClient{kind: :directed_identity},
         interact: interact
       })
       when not is_nil(interact),
       do: [issue(:interact, "must be omitted for directed JWK identity")]

  defp directed_errors(_request), do: []

  defp errors(:ok, _parent, _root), do: []
  defp errors({:error, error}, parent, root), do: prefix(error.validation_errors, parent, root)

  defp prefix(errors, parent, root) do
    Enum.map(errors, fn %{field: field} = error ->
      %{error | field: if(field == root, do: parent, else: "#{parent}.#{field}")}
    end)
  end

  defp put_optional(fields, _field, nil, _encoder), do: fields
  defp put_optional(fields, field, value, encoder), do: Map.put(fields, field, encoder.(value))
  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments grant request",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.GrantRequest do
  def encode(request, opts) do
    request |> OpenPayments.Types.GrantRequest.to_map() |> Jason.Encode.map(opts)
  end
end
