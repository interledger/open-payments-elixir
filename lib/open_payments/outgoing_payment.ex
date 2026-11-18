defmodule OpenPayments.OutgoingPayment do
  @moduledoc """
  Authenticated outgoing-payment operations on an Open Payments resource server.

  Reads sign a GET to a complete resource URL with the client's key and a
  per-call access token. Paths and queries are opaque; no provider layout or
  wallet/receiver lookup is inferred. HTTPS is required unless HTTP was explicitly
  enabled on the client. Redirects and automatic retries are disabled.
  """

  alias OpenPayments.{Client, Error}
  alias OpenPayments.Response.JSON
  alias OpenPayments.Types.AccessToken
  alias OpenPayments.Types.OutgoingPayment, as: PaymentData

  @get_operation :get_outgoing_payment

  @doc """
  Fetches an outgoing payment using a signed GET and a per-call access token.

  Supply an authenticated client and the full resource URL; no path is appended.
  Queries and nondefault HTTPS ports are supported. The required access_token
  option accepts a raw string or a typed `AccessToken`, revalidated before using
  its value. Duplicate/unsupported options and continuation credentials are
  rejected. Request URL/token68 policies apply. The server checks permission,
  token expiry and key binding; no token metadata inference is performed locally.

  HTTP 200 returns `OpenPayments.Types.OutgoingPayment` with three typed amounts.
  Following Node, debit and sent assets must match, sent value cannot exceed debit
  using exact integer arithmetic, and identical debit/sent value strings cannot
  accompany failed true. The last check deliberately compares original strings:
  differently padded decimal spellings are preserved, matching Node's behavior.
  Receive assets can differ. No positivity, fee/FX, completion-state inference or
  requested URL/wallet/receiver equality check is added.

  Schema and consistency failures return decoding/invalid_response with status
  200 and safe field paths; all errors carry `:get_outgoing_payment`. Optional
  failed remains nil when omitted. Inspection hides amounts, metadata and related
  references; explicit exports include them. This call makes no payment, caches
  no state, fetches no related resource and does not refresh tokens or poll.
  """
  @spec get(Client.t(), String.t(), [{:access_token, String.t() | AccessToken.t()}]) ::
          {:ok, PaymentData.t()} | {:error, Error.t()}
  def get(client, url, opts) do
    with {:ok, client} <- Client.validate(client),
         {:ok, _public_key} <- Client.signing_public_jwk(client),
         {:ok, token} <- Client.resource_access_token(opts),
         {:ok, response} <- Client.request_signed(client, :get, url, access_token: token),
         {:ok, data} <- JSON.decode(response, [200], @get_operation),
         {:ok, payment} <- decode(data, response.status) do
      {:ok, payment}
    else
      {:error, error} -> {:error, %{error | operation: @get_operation}}
    end
  end

  defp decode(data, status) do
    with {:ok, payment} <- PaymentData.from_map(data),
         :ok <- consistent(payment) do
      {:ok, payment}
    else
      {:error, error} ->
        {:error,
         %{
           error
           | kind: :decoding,
             status: status,
             code: "invalid_response",
             description: "Invalid Open Payments outgoing-payment response"
         }}
    end
  end

  defp consistent(%PaymentData{debit_amount: debit, sent_amount: sent, failed: failed}) do
    debit_asset = {debit.asset_code, debit.asset_scale}
    sent_asset = {sent.asset_code, sent.asset_scale}

    cond do
      debit_asset != sent_asset ->
        invalid_payment(:sent_amount, "must use the same asset code and scale as debit_amount")

      String.to_integer(sent.value) > String.to_integer(debit.value) ->
        invalid_payment(:sent_amount, "must not exceed debit_amount")

      debit.value == sent.value and failed == true ->
        invalid_payment(:failed, "must not be true when debit and sent value strings match")

      true ->
        :ok
    end
  end

  defp invalid_payment(field, message),
    do:
      {:error,
       %Error{
         kind: :validation,
         validation_errors: [%{field: field, message: message}]
       }}
end
