defmodule OpenPayments.Quote do
  @moduledoc """
  Authenticated quote operations on an Open Payments resource server.

  Reads sign a GET to a complete quote URL using the client's key and a per-call
  access token. Resource paths and queries are opaque; no provider path, wallet
  lookup or receiver lookup is inferred. HTTPS is required unless HTTP was
  explicitly enabled on the client. Redirects and automatic retries are disabled.
  """

  alias OpenPayments.{Client, Error}
  alias OpenPayments.Response.JSON
  alias OpenPayments.Types.AccessToken
  alias OpenPayments.Types.Quote, as: QuoteData

  @get_operation :get_quote

  @doc """
  Fetches a quote using a signed GET and the required per-call access_token option.

  Supply an authenticated client and the full resource URL; no path is appended.
  Nondefault HTTPS ports and queries are supported. The token may be an opaque
  string or typed `AccessToken`, revalidated before using its value. Unsupported
  or duplicate options and typed continuation credentials are rejected. Request
  URL/token68 rules apply; server checks permissions, expiry and key binding.

  HTTP 200 returns `OpenPayments.Types.Quote` with typed debit/receive amounts.
  Invalid schemas return decoding/invalid_response with status 200 and safe field
  paths; all errors carry `:get_quote`. The schema's optional expires_at remains
  string data, without local clock checks. Cross-asset amounts are valid.

  Following Node's quote read, no FX/fee/value-order/positivity rule, requested
  URL/response identity equality, wallet match or receiver comparison is added.
  This call makes no payment and does not cache, refresh tokens or fetch related
  resources. Inspection omits wallet/receiver/amount/expiry data; explicit exports
  include them. Quote creation remains a separate operation under development.
  """
  @spec get(Client.t(), String.t(), [{:access_token, String.t() | AccessToken.t()}]) ::
          {:ok, QuoteData.t()} | {:error, Error.t()}
  def get(client, url, opts) do
    with {:ok, client} <- Client.validate(client),
         {:ok, _public_key} <- Client.signing_public_jwk(client),
         {:ok, token} <- Client.resource_access_token(opts),
         {:ok, response} <- Client.request_signed(client, :get, url, access_token: token),
         {:ok, data} <- JSON.decode(response, [200], @get_operation),
         {:ok, quote} <- decode(data, response.status) do
      {:ok, quote}
    else
      {:error, error} -> {:error, %{error | operation: @get_operation}}
    end
  end

  defp decode(data, status) do
    case QuoteData.from_map(data) do
      {:ok, quote} ->
        {:ok, quote}

      {:error, error} ->
        {:error,
         %{
           error
           | kind: :decoding,
             status: status,
             code: "invalid_response",
             description: "Invalid Open Payments quote response"
         }}
    end
  end
end
