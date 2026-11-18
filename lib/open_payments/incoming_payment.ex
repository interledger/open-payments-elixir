defmodule OpenPayments.IncomingPayment do
  @moduledoc """
  Incoming-payment operations on an Open Payments resource server.

  Public reads use an unsigned GET to a complete incoming-payment URL and validate
  the current public response schema. Resource URLs are opaque: their paths and
  queries are not inferred from wallet addresses or provider-specific layouts.
  HTTPS is required unless HTTP was explicitly enabled on the client. Redirects
  and automatic retries are disabled.

  Authenticated reads use a signed GET with a required per-call access token and
  return detailed data with typed payment methods and consistent amount assets.
  """

  alias OpenPayments.{Client, Error}
  alias OpenPayments.Response.JSON
  alias OpenPayments.Types.{AccessToken, IncomingPaymentWithMethods, PublicIncomingPayment}

  @operation :get_public_incoming_payment
  @get_operation :get_incoming_payment

  @doc """
  Fetches authenticated incoming-payment details using a signed GET.

  Supply the complete resource URL, an authenticated client and the required
  per-call `access_token` option as an opaque string or typed `AccessToken`.
  Typed tokens are revalidated before using their value; opaque token permissions,
  expiry and key binding remain the server's responsibility. Other options and
  typed continuation credentials are rejected. Request URL/token68 rules apply.

  Success requires HTTP 200 and the detailed response with typed payment methods.
  When incoming_amount is present, its asset code/scale must match received_amount,
  following Node's authenticated incoming-payment validation. Invalid schemas or
  inconsistent response assets return decoding/invalid_response with safe fields;
  errors carry `:get_incoming_payment` and applicable status.

  No path is appended, no identity/amount/expiry equality with the requested URL
  or token metadata is inferred, and no state is cached. This call does not create
  or complete a payment. Explicit exports include ILP shared secrets; inspection
  omits them. Public reads remain available separately through `get_public/2`.
  """
  @spec get(Client.t(), String.t(), [{:access_token, String.t() | AccessToken.t()}]) ::
          {:ok, IncomingPaymentWithMethods.t()} | {:error, Error.t()}
  def get(client, url, opts) do
    with {:ok, client} <- Client.validate(client),
         {:ok, _public_key} <- Client.signing_public_jwk(client),
         {:ok, token} <- Client.resource_access_token(opts),
         {:ok, response} <- Client.request_signed(client, :get, url, access_token: token),
         {:ok, data} <- JSON.decode(response, [200], @get_operation),
         {:ok, payment} <- decode_authenticated(data, response.status) do
      {:ok, payment}
    else
      {:error, error} -> {:error, %{error | operation: @get_operation}}
    end
  end

  @doc """
  Fetches public incoming-payment details without signing or an access token.

  Accepts a full resource URL, including a nondefault HTTPS port or query if
  needed. Payment pointers identify wallets and are not resource URLs. Success
  returns a `PublicIncomingPayment` struct; errors carry the operation
  `:get_public_incoming_payment` and applicable status or validation paths.

  This read does not complete or create a payment, connect to STREAM, select a
  payment method, or cache the response. Explicit JSON exports of returned methods
  contain ILP shared secrets; inspection omits them.
  """
  @spec get_public(Client.t(), String.t()) ::
          {:ok, PublicIncomingPayment.t()} | {:error, Error.t()}
  def get_public(client, url) do
    with {:ok, client} <- Client.validate(client),
         {:ok, response} <- Client.request(client, :get, url),
         {:ok, data} <- JSON.decode(response, [200], @operation),
         {:ok, payment} <- decode(data, response.status) do
      {:ok, payment}
    else
      {:error, error} -> {:error, %{error | operation: @operation}}
    end
  end

  defp decode(data, status) do
    case PublicIncomingPayment.from_map(data) do
      {:ok, payment} ->
        {:ok, payment}

      {:error, error} ->
        {:error,
         %{
           error
           | kind: :decoding,
             status: status,
             code: "invalid_response",
             description: "Invalid Open Payments public incoming-payment response"
         }}
    end
  end

  defp decode_authenticated(data, status) do
    with {:ok, payment} <- IncomingPaymentWithMethods.from_map(data),
         :ok <- validate_assets(payment) do
      {:ok, payment}
    else
      {:error, error} ->
        {:error,
         %{
           error
           | kind: :decoding,
             status: status,
             code: "invalid_response",
             description: "Invalid Open Payments authenticated incoming-payment response"
         }}
    end
  end

  defp validate_assets(%IncomingPaymentWithMethods{incoming_amount: nil}), do: :ok

  defp validate_assets(%IncomingPaymentWithMethods{
         incoming_amount: incoming,
         received_amount: received
       }) do
    if incoming.asset_code == received.asset_code and incoming.asset_scale == received.asset_scale,
      do: :ok,
      else:
        {:error,
         %Error{
           kind: :validation,
           validation_errors: [
             %{
               field: :incoming_amount,
               message: "must use the same asset code and scale as received_amount"
             }
           ]
         }}
  end
end
