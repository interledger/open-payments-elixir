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
  Creation signs a POST to the resource server's incoming-payment collection and
  additionally requires zero received funds and completed false in the response.
  Completion signs a bodyless POST to the payment's complete endpoint and returns
  detailed payment data with completed true.
  Listing signs a GET with encoded wallet/pagination query arguments and returns
  one typed page with consistent amount assets for every item.
  """

  alias OpenPayments.{Client, Error}
  alias OpenPayments.Request.URL
  alias OpenPayments.Response.JSON
  alias OpenPayments.Types.IncomingPayment, as: IncomingPaymentData

  alias OpenPayments.Types.{
    AccessToken,
    CreateIncomingPayment,
    IncomingPaymentPaginationResult,
    IncomingPaymentWithMethods,
    Pagination,
    PublicIncomingPayment,
    Validation
  }

  @operation :get_public_incoming_payment
  @get_operation :get_incoming_payment
  @create_operation :create_incoming_payment
  @complete_operation :complete_incoming_payment
  @list_operation :list_incoming_payments

  @doc """
  Lists one page of incoming payments using a signed GET.

  Supply the resource-server base URL and wallet filter separately. The required
  `access_token` option accepts the same raw string or typed token as `get/3`.
  Optional `pagination` accepts a typed `Pagination` or string-keyed map; omission
  sends no cursor/count defaults, while explicit nil is invalid. Other options,
  duplicate keys and per-call key/header overrides are rejected.

  The wallet filter follows the pinned required-string query schema, without
  URI validation or payment-pointer resolution. Use the discovered wallet ID for
  normal requests. Every UTF-8 string, including empty, is encoded and sent as
  wallet-address; provider meaning and permissions remain server checks. Unlike
  Node's truthy-value filtering, an empty wallet string is not silently omitted.

  Appends `/incoming-payments` to the base while preserving tenant paths and
  reusing a trailing slash. Base queries are rejected. Query values use Node's
  URLSearchParams form encoding, with a stable wallet-address-first order and
  sorted pagination keys. Encoding finishes before signing the complete target.

  HTTP 200 returns `IncomingPaymentPaginationResult` and requires incoming/received
  asset code and scale consistency for every item, following Node. Schema or
  consistency failures return decoding/invalid_response with safe indexed fields
  and status 200. Errors carry `:list_incoming_payments`.

  This call does not infer result ordering, compare wallet identities or page
  sizes, cache responses, fetch another page, follow links/redirects, retry or
  refresh tokens. The caller chooses cursor/direction for each subsequent call.
  Explicit page exports include cursors, metadata and extensions.
  """
  @spec list(Client.t(), String.t(), String.t(), [
          {:access_token, String.t() | AccessToken.t()} | {:pagination, Pagination.t() | map()}
        ]) :: {:ok, IncomingPaymentPaginationResult.t()} | {:error, Error.t()}
  def list(client, base_url, wallet_address, opts) do
    with {:ok, client} <- Client.validate(client),
         {:ok, _public_key} <- Client.signing_public_jwk(client),
         {:ok, token, pagination} <- list_options(opts),
         :ok <- wallet_filter(wallet_address),
         {:ok, url} <- list_url(base_url, Client.allow_http?(client), wallet_address, pagination),
         {:ok, response} <- Client.request_signed(client, :get, url, access_token: token),
         {:ok, data} <- JSON.decode(response, [200], @list_operation),
         {:ok, page} <- decode_page(data, response.status) do
      {:ok, page}
    else
      {:error, error} -> {:error, %{error | operation: @list_operation}}
    end
  end

  @doc """
  Creates an incoming payment using a signed POST and a per-call access token.

  Supply the resource-server base URL, a typed `CreateIncomingPayment` or a
  string-keyed protocol map, and the required `access_token` option accepted by
  `get/3`. The SDK appends `/incoming-payments`, preserving tenant paths and
  reusing an existing trailing slash. Base URLs with queries are rejected.
  HTTPS is required unless HTTP was explicitly enabled on the client.

  Success requires HTTP 201 and a detailed response with payment methods, zero
  received funds, completed false and consistent incoming/received assets,
  following Node's creation checks. Invalid success responses return
  decoding/invalid_response with status 201. Errors carry `:create_incoming_payment`.

  Wallet/amount/expiry/metadata values are sent as supplied. No wallet is fetched
  to compare its assets; the server enforces wallet asset compatibility and grant
  permissions. The response is not compared with request values. No automatic
  retry occurs, including after a timeout; a failed call may have created a
  payment. Explicit response exports include ILP shared secrets.
  """
  @spec create(Client.t(), String.t(), CreateIncomingPayment.t() | map(), [
          {:access_token, String.t() | AccessToken.t()}
        ]) :: {:ok, IncomingPaymentWithMethods.t()} | {:error, Error.t()}
  def create(client, base_url, payload, opts) do
    with {:ok, client} <- Client.validate(client),
         {:ok, _public_key} <- Client.signing_public_jwk(client),
         {:ok, token} <- Client.resource_access_token(opts),
         {:ok, request} <- create_payload(payload),
         {:ok, url} <- URL.append_path(base_url, Client.allow_http?(client), "incoming-payments"),
         {:ok, response} <-
           Client.request_signed(client, :post, url, access_token: token, json: request),
         {:ok, data} <- JSON.decode(response, [201], @create_operation),
         {:ok, payment} <- decode_authenticated(data, response.status, :create) do
      {:ok, payment}
    else
      {:error, error} -> {:error, %{error | operation: @create_operation}}
    end
  end

  @doc """
  Marks an incoming payment complete using a signed POST without a request body.

  Supply the full incoming-payment URL and the required per-call `access_token`
  option accepted by `get/3`. The SDK appends `/complete`, preserving tenant and
  opaque path spelling and reusing an existing trailing slash. Queries, including
  an empty query marker, are rejected. Request URL policies still apply.

  HTTP 200 returns a typed `OpenPayments.Types.IncomingPayment` with completed true
  and consistent incoming/received asset code and scale, following Node's checks.
  The completion response excludes payment methods and other unknown top-level
  fields. The pinned response's additionalProperties restriction is applied to
  the combined detailed fields, rather than literally closing an allOf reference
  with no locally declared properties. Metadata and nested amount extensions are
  still permitted. The standalone detailed codec keeps its extension support.

  Invalid success data returns decoding/invalid_response with status 200. Errors
  carry `:complete_incoming_payment`. The server checks grant permissions, expiry
  and completion eligibility; the SDK does not require the full amount to have
  been received or compare returned identity/timestamps with local state.
  No automatic retry, redirect, token refresh or readback occurs, including after
  ambiguous transport failures. The caller decides how to reconcile the outcome.
  """
  @spec complete(Client.t(), String.t(), [{:access_token, String.t() | AccessToken.t()}]) ::
          {:ok, IncomingPaymentData.t()} | {:error, Error.t()}
  def complete(client, payment_url, opts) do
    with {:ok, client} <- Client.validate(client),
         {:ok, _public_key} <- Client.signing_public_jwk(client),
         {:ok, token} <- Client.resource_access_token(opts),
         {:ok, url} <- URL.append_path(payment_url, Client.allow_http?(client), "complete"),
         {:ok, response} <- Client.request_signed(client, :post, url, access_token: token),
         {:ok, data} <- JSON.decode(response, [200], @complete_operation),
         {:ok, payment} <- decode_completed(data, response.status) do
      {:ok, payment}
    else
      {:error, error} -> {:error, %{error | operation: @complete_operation}}
    end
  end

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

  defp create_payload(%CreateIncomingPayment{} = request) do
    with :ok <- CreateIncomingPayment.validate(request), do: {:ok, request}
  end

  defp create_payload(payload), do: CreateIncomingPayment.from_map(payload)

  defp list_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and length(Enum.uniq(Keyword.keys(opts))) == length(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:access_token, :pagination])) do
      with {:ok, token} <- Client.resource_access_token(Keyword.take(opts, [:access_token])),
           {:ok, pagination} <- prepare_pagination(Keyword.get(opts, :pagination, %Pagination{})) do
        {:ok, token, pagination}
      end
    else
      invalid_payment(
        :options,
        "must contain unique access_token and optional pagination options"
      )
    end
  end

  defp list_options(_opts),
    do:
      invalid_payment(
        :options,
        "must be a keyword list with access_token and optional pagination"
      )

  defp prepare_pagination(%Pagination{} = pagination) do
    with :ok <- Pagination.validate(pagination), do: {:ok, pagination}
  end

  defp prepare_pagination(data), do: Pagination.from_map(data)

  defp wallet_filter(value) do
    if Validation.string?(value),
      do: :ok,
      else: invalid_payment(:wallet_address, "must be a string")
  end

  defp list_url(base_url, allow_http, wallet_address, pagination) do
    with {:ok, url} <- URL.append_path(base_url, allow_http, "incoming-payments") do
      query =
        pagination
        |> Pagination.to_map()
        |> Enum.sort()
        |> List.insert_at(0, {"wallet-address", wallet_address})
        |> URI.encode_query()
        # URLSearchParams escapes tilde and leaves asterisk literal.
        |> String.replace("~", "%7E")
        |> String.replace("%2A", "*")

      {:ok, url <> "?" <> query}
    end
  end

  defp decode_completed(data, status) do
    with {:ok, payment} <- IncomingPaymentData.from_map(data),
         :ok <- validate_completion(payment),
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
             description: "Invalid Open Payments incoming-payment completion response"
         }}
    end
  end

  defp validate_completion(payment) do
    cond do
      map_size(payment.extensions) != 0 ->
        invalid_payment(:incoming_payment, "must contain only detailed incoming-payment fields")

      not payment.completed ->
        invalid_payment(:completed, "must be true for a completed payment")

      true ->
        :ok
    end
  end

  defp decode_page(data, status) do
    with {:ok, page} <- IncomingPaymentPaginationResult.from_map(data),
         :ok <- validate_page_assets(page.result) do
      {:ok, page}
    else
      {:error, error} ->
        {:error,
         %{
           error
           | kind: :decoding,
             status: status,
             code: "invalid_response",
             description: "Invalid Open Payments incoming-payment list response"
         }}
    end
  end

  defp validate_page_assets(payments) do
    payments
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {payment, index}, :ok ->
      case validate_assets(payment) do
        :ok ->
          {:cont, :ok}

        {:error, error} ->
          errors =
            Enum.map(error.validation_errors, &%{&1 | field: "result[#{index}].#{&1.field}"})

          {:halt, {:error, %{error | validation_errors: errors}}}
      end
    end)
  end

  defp decode_authenticated(data, status, mode \\ :read) do
    with {:ok, payment} <- IncomingPaymentWithMethods.from_map(data),
         :ok <- validate_creation(payment, mode),
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

  defp validate_creation(_payment, :read), do: :ok

  defp validate_creation(payment, :create) do
    cond do
      String.to_integer(payment.received_amount.value) != 0 ->
        invalid_payment("received_amount.value", "must be zero for a newly created payment")

      payment.completed ->
        invalid_payment(:completed, "must be false for a newly created payment")

      true ->
        :ok
    end
  end

  defp validate_assets(%{incoming_amount: nil}), do: :ok

  defp validate_assets(%{
         incoming_amount: incoming,
         received_amount: received
       }) do
    incoming_asset = {incoming.asset_code, incoming.asset_scale}
    received_asset = {received.asset_code, received.asset_scale}

    if incoming_asset == received_asset do
      :ok
    else
      invalid_payment(
        :incoming_amount,
        "must use the same asset code and scale as received_amount"
      )
    end
  end

  defp invalid_payment(field, message),
    do:
      {:error, %Error{kind: :validation, validation_errors: [%{field: field, message: message}]}}
end
