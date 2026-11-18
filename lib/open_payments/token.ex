defmodule OpenPayments.Token do
  @moduledoc """
  Management operations for issued Open Payments access tokens.

  Operations use the token's management URI and value with the authenticated
  client's signing key. URLs are opaque; no provider path is inferred or appended.
  HTTPS is required unless HTTP was explicitly enabled on the client. Tokens
  remain per-call data; redirects and automatic retries are disabled.
  """

  alias OpenPayments.{Client, Error}
  alias OpenPayments.Response.JSON
  alias OpenPayments.Types.{AccessToken, TokenRotationResponse}

  @operation :rotate_access_token

  @doc """
  Rotates an issued access token using its management URI and current value.

  Pass a typed `AccessToken` and an authenticated client holding its bound signing
  key. Sends one signed POST with GNAP authorization and no request body, matching
  Node's rotation request. Continuation credentials cannot replace the token.

  HTTP 200 returns a typed `TokenRotationResponse`, preserving the `access_token`
  wrapper and permitted JSON extensions. Use its new token and management URI
  for subsequent calls. Existing request URL/header policies apply, and errors
  carry `:rotate_access_token`.

  The authorization server determines token invalidation and key binding. The SDK
  does not store tokens, mutate the client/input, assess elapsed expiry, compare
  old/new access, automatically retry rotation or rotate the signing key.
  """
  @spec rotate(Client.t(), AccessToken.t()) ::
          {:ok, TokenRotationResponse.t()} | {:error, Error.t()}
  def rotate(client, token) do
    with {:ok, client} <- Client.validate(client),
         {:ok, _public_key} <- Client.signing_public_jwk(client),
         :ok <- validate_token(token),
         {:ok, response} <-
           Client.request_signed(client, :post, token.manage, access_token: token.value),
         {:ok, data} <- JSON.decode(response, [200], @operation),
         {:ok, rotated} <- decode(data, response.status) do
      {:ok, rotated}
    else
      {:error, error} -> {:error, %{error | operation: @operation}}
    end
  end

  defp validate_token(%AccessToken{} = token), do: AccessToken.validate(token)

  defp validate_token(_token),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments managed token",
         validation_errors: [%{field: :access_token, message: "must be an AccessToken struct"}]
       }}

  defp decode(data, status) do
    case TokenRotationResponse.from_map(data) do
      {:ok, rotated} ->
        {:ok, rotated}

      {:error, error} ->
        {:error,
         %{
           error
           | kind: :decoding,
             status: status,
             code: "invalid_response",
             description: "Invalid Open Payments token rotation response"
         }}
    end
  end
end
