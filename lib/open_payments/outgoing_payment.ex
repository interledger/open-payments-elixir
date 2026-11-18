defmodule OpenPayments.OutgoingPayment do
  @moduledoc """
  Authenticated outgoing-payment operations on an Open Payments resource server.

  Reads sign a GET to a complete resource URL with the client's key and a
  per-call access token. Paths and queries are opaque; no provider layout or
  wallet/receiver lookup is inferred. HTTPS is required unless HTTP was explicitly
  enabled on the client. Redirects and automatic retries are disabled.
  Creation signs a POST to the outgoing-payments collection using either supported
  request form and returns typed payment data with optional grant spent amounts.
  Listing signs a GET with wallet/pagination query arguments and returns one typed
  page, applying the same payment consistency rules to each item.
  """

  alias OpenPayments.{Client, Error}
  alias OpenPayments.Request.{Collection, URL}
  alias OpenPayments.Response.JSON

  alias OpenPayments.Types.{
    AccessToken,
    CreateOutgoingPayment,
    OutgoingPaymentPaginationResult,
    OutgoingPaymentWithSpentAmounts,
    Pagination
  }

  alias OpenPayments.Types.OutgoingPayment, as: PaymentData

  @get_operation :get_outgoing_payment
  @create_operation :create_outgoing_payment
  @list_operation :list_outgoing_payments

  @doc """
  Lists one page of outgoing payments using a signed GET.

  Supply the resource-server base and a separate wallet filter. The required
  access_token option accepts the same raw string or typed token as `get/3`.
  Optional pagination accepts a typed `Pagination` or protocol map; omission
  sends no count/cursor defaults, while explicit nil is invalid. Duplicate or
  unsupported options and per-call key/header overrides are rejected.

  The wallet filter follows the pinned required-string query schema, without URI
  validation, pointer resolution or substitution of client identity. Every UTF-8
  string, including empty, is encoded and sent. Unlike Node's truthy filtering,
  an empty wallet string is not silently omitted; server meaning/permission checks
  still apply. Usually supply the discovered wallet ID.

  Appends `/outgoing-payments` while preserving tenant paths and trailing slashes;
  base queries are rejected. Uses the same Node URLSearchParams-compatible form
  encoding and wallet-first/sorted pagination order as incoming-payment listing.
  The entire query is encoded before signing the bodyless GNAP GET.

  HTTP 200 returns `OutgoingPaymentPaginationResult` with strict detailed items.
  Each item must pass the same ordered debit/sent consistency checks as `get/3`.
  Schema/consistency failures return decoding/invalid_response/status200 with safe
  indexed paths such as result[1].sent_amount; errors carry
  `:list_outgoing_payments`. Creation spent-amount fields are not list item data.

  This call does not compare filter/result identities, page sizes, flags/cursors
  or ordering, cache state, traverse pages, follow links/redirects, retry, refresh
  tokens or poll. Choose direction/cursor and credentials for each subsequent call.
  Explicit exports include cursors, references, amounts, metadata and extensions.
  """
  @spec list(Client.t(), String.t(), String.t(), [
          {:access_token, String.t() | AccessToken.t()} | {:pagination, Pagination.t() | map()}
        ]) :: {:ok, OutgoingPaymentPaginationResult.t()} | {:error, Error.t()}
  def list(client, base_url, wallet_address, opts) do
    with {:ok, client} <- Client.validate(client),
         {:ok, _public_key} <- Client.signing_public_jwk(client),
         {:ok, url, token} <-
           Collection.prepare(
             base_url,
             Client.allow_http?(client),
             wallet_address,
             opts,
             "outgoing-payments"
           ),
         {:ok, response} <- Client.request_signed(client, :get, url, access_token: token),
         {:ok, data} <- JSON.decode(response, [200], @list_operation),
         {:ok, page} <- decode_page(data, response.status) do
      {:ok, page}
    else
      {:error, error} -> {:error, %{error | operation: @list_operation}}
    end
  end

  @doc """
  Creates an outgoing payment using one signed POST and a validated request form.

  Supply the resource-server base, a `CreateOutgoingPayment` struct or protocol
  map, and the required per-call access_token option accepted by `get/3`. Appends
  `/outgoing-payments`, preserving tenant paths and reusing a trailing slash.
  Base queries, including an empty marker, are rejected. URL/token policies apply.

  Both typed/map inputs are validated before HTTP. Supply quote_id, or both
  incoming_payment and debit_amount; metadata is optional. No quote/wallet/receiver
  is fetched and no amount is inferred. The server checks quote validity, wallet
  asset compatibility, grant permissions and key binding.

  HTTP 201 returns `OutgoingPaymentWithSpentAmounts`. Either, both or neither
  grant spent amount may appear; permitted JSON extensions are retained. Shared
  debit/sent consistency checks match `get/3`, including original-string equality
  for the failed rule. No zero-sent, failed-false, request/response identity or
  amount equality, grant-budget or grant-asset rule is added. Creation responses
  may already reflect payment progress. Invalid success schemas or consistency
  return decoding/invalid_response/status201; all errors carry
  `:create_outgoing_payment`.

  Creating an outgoing payment authorizes processing by the server. This call
  does not make a second send request, retry, follow redirects, refresh a token,
  poll or read back the resource. A timeout, lost response or invalid response
  may occur after the server has created/started the payment. The caller decides
  how to reconcile that outcome; automatic replay could duplicate the payment.
  """
  @spec create(Client.t(), String.t(), CreateOutgoingPayment.t() | map(), [
          {:access_token, String.t() | AccessToken.t()}
        ]) :: {:ok, OutgoingPaymentWithSpentAmounts.t()} | {:error, Error.t()}
  def create(client, base_url, payload, opts) do
    with {:ok, client} <- Client.validate(client),
         {:ok, _public_key} <- Client.signing_public_jwk(client),
         {:ok, token} <- Client.resource_access_token(opts),
         {:ok, request} <- prepare_payload(payload),
         {:ok, url} <- URL.append_path(base_url, Client.allow_http?(client), "outgoing-payments"),
         {:ok, response} <-
           Client.request_signed(client, :post, url, access_token: token, json: request),
         {:ok, data} <- JSON.decode(response, [201], @create_operation),
         {:ok, payment} <-
           decode(data, response.status, &OutgoingPaymentWithSpentAmounts.from_map/1) do
      {:ok, payment}
    else
      {:error, error} -> {:error, %{error | operation: @create_operation}}
    end
  end

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
         {:ok, payment} <- decode(data, response.status, &PaymentData.from_map/1) do
      {:ok, payment}
    else
      {:error, error} -> {:error, %{error | operation: @get_operation}}
    end
  end

  defp prepare_payload(%CreateOutgoingPayment{} = request) do
    with :ok <- CreateOutgoingPayment.validate(request), do: {:ok, request}
  end

  defp prepare_payload(payload), do: CreateOutgoingPayment.from_map(payload)

  defp decode(data, status, decoder) do
    with {:ok, payment} <- decoder.(data),
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

  defp decode_page(data, status) do
    with {:ok, page} <- OutgoingPaymentPaginationResult.from_map(data),
         :ok <- consistent_page(page.result) do
      {:ok, page}
    else
      {:error, error} ->
        {:error,
         %{
           error
           | kind: :decoding,
             status: status,
             code: "invalid_response",
             description: "Invalid Open Payments outgoing-payment list response"
         }}
    end
  end

  defp consistent_page(payments) do
    payments
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {payment, index}, :ok ->
      case consistent(payment) do
        :ok ->
          {:cont, :ok}

        {:error, error} ->
          errors =
            Enum.map(error.validation_errors, &%{&1 | field: "result[#{index}].#{&1.field}"})

          {:halt, {:error, %{error | validation_errors: errors}}}
      end
    end)
  end

  defp consistent(%{debit_amount: debit, sent_amount: sent, failed: failed}) do
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
