defmodule OpenPayments.Grant do
  @moduledoc """
  Grant operations on an Open Payments authorization server.

  Grant initiation signs a POST without an access token, using the configured
  client's key and the SDK's documented Node signing profile. Supply the complete
  authorization-server URL; no path is appended or inferred. HTTPS is required
  unless HTTP was explicitly enabled on the client. Redirects and automatic
  retries are disabled, including after ambiguous transport failures.
  """

  alias OpenPayments.{Client, Error}
  alias OpenPayments.Response.JSON
  alias OpenPayments.Types.{GrantClient, GrantRequest, GrantResponse, JWK}

  @operation :request_grant
  @key_fields ~w(kid alg kty crv x)

  @doc """
  Requests a grant using an authenticated client and a complete authorization URL.

  Accepts a typed `GrantRequest` or a string-keyed protocol map. A map with no
  `client` field receives the configured wallet URI string, matching Node's
  default client identification. Explicit identities and their wire forms are
  preserved; explicit null is invalid. Typed requests must already be complete.

  Directed JWK identity must match the configured signing key's canonical public
  JWK fields and key ID. Wallet identities are sent as supplied; the authorization
  server verifies their key registration. No wallet or JWKS lookup is performed.

  Returns a typed initial `GrantResponse` or an error with operation
  `:request_grant`. This call does not open consent URLs, verify callbacks, poll,
  continue/cancel grants or compare granted access with requested access.
  """
  @spec request(Client.t(), String.t(), GrantRequest.t() | map()) ::
          {:ok, GrantResponse.t()} | {:error, Error.t()}
  def request(client, url, payload) do
    with {:ok, client} <- Client.validate(client),
         {:ok, public_key} <- Client.signing_public_jwk(client),
         {:ok, grant} <- prepare_payload(payload, client),
         :ok <- match_identity(grant.client, public_key),
         {:ok, response} <- Client.request_signed(client, :post, url, json: grant),
         {:ok, data} <- JSON.decode(response, [200], @operation),
         {:ok, grant_response} <- decode(data, response.status) do
      {:ok, grant_response}
    else
      {:error, error} -> {:error, %{error | operation: @operation}}
    end
  end

  defp prepare_payload(%GrantRequest{} = grant, _client) do
    with :ok <- GrantRequest.validate(grant), do: {:ok, grant}
  end

  defp prepare_payload(data, client) when is_map(data) and not is_struct(data) do
    data |> Map.put_new("client", Client.wallet_address(client)) |> GrantRequest.from_map()
  end

  defp prepare_payload(_payload, _client),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments grant request",
         validation_errors: [
           %{field: :grant_request, message: "must be a GrantRequest struct or JSON object"}
         ]
       }}

  defp match_identity(%GrantClient{kind: :directed_identity, jwk: jwk}, public_key) do
    if Map.take(JWK.to_map(jwk), @key_fields) == Map.take(JWK.to_map(public_key), @key_fields),
      do: :ok,
      else:
        {:error,
         %Error{
           kind: :validation,
           description: "Invalid Open Payments directed grant identity",
           validation_errors: [
             %{field: "client.jwk", message: "must match the configured signing key and key ID"}
           ]
         }}
  end

  defp match_identity(_identity, _public_key), do: :ok

  defp decode(data, status) do
    case GrantResponse.from_map(data) do
      {:ok, grant} ->
        {:ok, grant}

      {:error, error} ->
        {:error,
         %{
           error
           | kind: :decoding,
             status: status,
             code: "invalid_response",
             description: "Invalid Open Payments initial grant response"
         }}
    end
  end
end
