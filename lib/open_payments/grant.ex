defmodule OpenPayments.Grant do
  @moduledoc """
  Grant operations on an Open Payments authorization server.

  Grant initiation signs a POST without an access token, using the configured
  client's key and the SDK's documented Node signing profile. Supply the complete
  authorization-server URL; no path is appended or inferred. HTTPS is required
  unless HTTP was explicitly enabled on the client. Redirects and automatic
  retries are disabled, including after ambiguous transport failures.
  Continuation signs a POST with its per-call GNAP continuation credential and
  optional JSON body. Applications own callback verification and wait scheduling.
  Cancellation signs a DELETE using the same typed continuation data and returns
  `:ok` for HTTP 204, without interpreting a response body.
  """

  alias OpenPayments.{Client, Error}
  alias OpenPayments.Response.JSON

  alias OpenPayments.Types.{
    Continuation,
    GrantClient,
    GrantContinuationRequest,
    GrantContinuationResponse,
    GrantRequest,
    GrantResponse,
    JWK
  }

  @operation :request_grant
  @continue_operation :continue_grant
  @cancel_operation :cancel_grant
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

  @doc """
  Continues a grant once using a typed continuation URI and credential.

  Pass the `continue` object from the latest response and the authenticated client
  holding the same signing key used for initiation. No path is appended. The
  continuation credential is sent in `Authorization: GNAP ...` and covered by the
  signature; issued resource access-token structs cannot replace it.

  Omitted or nil payload sends no body. A typed `GrantContinuationRequest` or
  string-keyed JSON map sends a JSON body, including `{}` for an empty payload.
  The result is a `GrantContinuationResponse`; errors carry `:continue_grant`.

  The caller must honor the server's `wait` interval before calling and verify
  interaction callbacks before supplying their reference. This operation does
  not track receipt times, enforce waiting, verify callbacks, poll, retry or
  persist credentials. Use the returned continuation data for the next call,
  including any changed URI or credential. Tokens remain per-call data.
  """
  @spec continue(Client.t(), Continuation.t(), GrantContinuationRequest.t() | map() | nil) ::
          {:ok, GrantContinuationResponse.t()} | {:error, Error.t()}
  def continue(client, continuation, payload \\ nil) do
    with {:ok, client} <- Client.validate(client),
         {:ok, _public_key} <- Client.signing_public_jwk(client),
         :ok <- validate_continuation(continuation),
         {:ok, body_options} <- continuation_body(payload),
         {:ok, response} <-
           Client.request_signed(
             client,
             :post,
             continuation.uri,
             Keyword.put(body_options, :access_token, continuation.access_token.value)
           ),
         {:ok, data} <- JSON.decode(response, [200], @continue_operation),
         {:ok, grant} <- decode_continuation(data, response.status) do
      {:ok, grant}
    else
      {:error, error} -> {:error, %{error | operation: @continue_operation}}
    end
  end

  @doc """
  Cancels a grant using its latest typed continuation URI and credential.

  Use the authenticated client holding the same signing key as initiation.
  Sends one signed DELETE with `Authorization: GNAP ...`, no request body and
  no appended path. The credential must be a continuation token, not an issued
  resource access token. Request URL/header policies still apply.

  HTTP 204 returns `:ok` without parsing a response body. Other success statuses
  are unexpected-status decoding errors; HTTP and transport failures retain the
  operation `:cancel_grant`. Redirects and automatic retries are disabled.

  The call does not persist or invalidate local structs, revoke resource tokens
  through their management endpoint, verify callbacks, or track grant state.
  Tokens remain per-call data; the authorization server checks the key binding
  and determines the cancellation's effect.
  """
  @spec cancel(Client.t(), Continuation.t()) :: :ok | {:error, Error.t()}
  def cancel(client, continuation) do
    with {:ok, client} <- Client.validate(client),
         {:ok, _public_key} <- Client.signing_public_jwk(client),
         :ok <- validate_continuation(continuation),
         {:ok, response} <-
           Client.request_signed(client, :delete, continuation.uri,
             access_token: continuation.access_token.value
           ),
         :ok <- JSON.expect_no_content(response, [204], @cancel_operation) do
      :ok
    else
      {:error, error} -> {:error, %{error | operation: @cancel_operation}}
    end
  end

  defp validate_continuation(%Continuation{} = continuation),
    do: Continuation.validate(continuation)

  defp validate_continuation(_continuation),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments continuation data",
         validation_errors: [%{field: :continuation, message: "must be a Continuation struct"}]
       }}

  defp continuation_body(nil), do: {:ok, []}

  defp continuation_body(%GrantContinuationRequest{} = payload) do
    with :ok <- GrantContinuationRequest.validate(payload), do: {:ok, [json: payload]}
  end

  defp continuation_body(payload) do
    with {:ok, request} <- GrantContinuationRequest.from_map(payload), do: {:ok, [json: request]}
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

  defp decode_continuation(data, status) do
    case GrantContinuationResponse.from_map(data) do
      {:ok, grant} ->
        {:ok, grant}

      {:error, error} ->
        {:error,
         %{
           error
           | kind: :decoding,
             status: status,
             code: "invalid_response",
             description: "Invalid Open Payments grant continuation response"
         }}
    end
  end
end
