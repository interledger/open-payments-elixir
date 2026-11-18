defmodule OpenPayments.Quote do
  @moduledoc """
  Authenticated quote operations on an Open Payments resource server.

  Reads sign a GET to a complete quote URL using the client's key and a per-call
  access token. Resource paths and queries are opaque; no provider path, wallet
  lookup or receiver lookup is inferred. HTTPS is required unless HTTP was
  explicitly enabled on the client. Redirects and automatic retries are disabled.
  Creation signs a POST to the resource server's quotes collection and returns
  the same typed quote data, with all amount inference left to the server.
  """

  alias OpenPayments.{Client, Error}
  alias OpenPayments.Request.URL
  alias OpenPayments.Response.JSON
  alias OpenPayments.Types.{AccessToken, CreateQuote}
  alias OpenPayments.Types.Quote, as: QuoteData

  @get_operation :get_quote
  @create_operation :create_quote

  @doc """
  Creates a quote using a signed POST with a typed or string-keyed request payload.

  Supply the resource-server base URL, a `CreateQuote` struct or protocol map,
  and the required per-call access_token option accepted by `get/3`. The SDK
  appends `/quotes`, preserving tenant paths and reusing a trailing slash. Base
  queries, including an empty marker, are rejected. Request URL/token rules apply.

  Both typed and map payloads are validated before HTTP. Supply debit_amount,
  receive_amount, or neither when the receiver provides the amount; both are
  invalid. The server checks receiver amount availability, relevant assets,
  permissions and key binding. No wallet/receiver lookup or amount default occurs.

  HTTP 201 returns typed quote data. Invalid success responses return
  decoding/invalid_response with status 201 and safe field paths; errors carry
  `:create_quote`. Following Node's quote operation, no response/request equality,
  FX, fee, value-order, positivity or local expiry rule is added.

  This call does not send an outgoing payment, follow redirects, retry, refresh
  tokens, cache or automatically read back the quote. A timeout may occur after
  the server creates it; the caller decides how to reconcile that outcome.
  """
  @spec create(Client.t(), String.t(), CreateQuote.t() | map(), [
          {:access_token, String.t() | AccessToken.t()}
        ]) :: {:ok, QuoteData.t()} | {:error, Error.t()}
  def create(client, base_url, payload, opts) do
    with {:ok, client} <- Client.validate(client),
         {:ok, _public_key} <- Client.signing_public_jwk(client),
         {:ok, token} <- Client.resource_access_token(opts),
         {:ok, request} <- prepare_payload(payload),
         {:ok, url} <- URL.append_path(base_url, Client.allow_http?(client), "quotes"),
         {:ok, response} <-
           Client.request_signed(client, :post, url, access_token: token, json: request),
         {:ok, data} <- JSON.decode(response, [201], @create_operation),
         {:ok, quote} <- decode(data, response.status) do
      {:ok, quote}
    else
      {:error, error} -> {:error, %{error | operation: @create_operation}}
    end
  end

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
  include them. Quote creation is available separately through `create/4`.
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

  defp prepare_payload(%CreateQuote{} = request) do
    with :ok <- CreateQuote.validate(request), do: {:ok, request}
  end

  defp prepare_payload(payload), do: CreateQuote.from_map(payload)

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
