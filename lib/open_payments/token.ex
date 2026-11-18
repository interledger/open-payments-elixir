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
  @revoke_operation :revoke_access_token

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

  @doc """
  Revokes an issued access token using its management URI and current value.

  Pass a typed `AccessToken` and the authenticated client holding its bound
  signing key. Sends one signed DELETE with GNAP authorization, no request body
  and no appended path. Continuation credentials cannot replace the token.

  HTTP 204 returns `:ok` without JSON parsing or content decoding. Other success
  statuses are unexpected-status decoding errors. Failures carry operation
  `:revoke_access_token`, and the usual request URL/header policies apply.

  Use the latest token after rotation. The authorization server checks key
  binding and determines revocation's effect; the SDK does not store or remove
  tokens, mutate the client/input, assess elapsed expiry or track grant state.
  Redirects and automatic retries are disabled, including after ambiguous
  transport failures. Grant cancellation uses `OpenPayments.Grant.cancel/2`.
  """
  @spec revoke(Client.t(), AccessToken.t()) :: :ok | {:error, Error.t()}
  def revoke(client, token) do
    with {:ok, client} <- Client.validate(client),
         {:ok, _public_key} <- Client.signing_public_jwk(client),
         :ok <- validate_token(token),
         {:ok, response} <-
           Client.request_signed(client, :delete, token.manage, access_token: token.value),
         :ok <- JSON.expect_no_content(response, [204], @revoke_operation) do
      :ok
    else
      {:error, error} -> {:error, %{error | operation: @revoke_operation}}
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
