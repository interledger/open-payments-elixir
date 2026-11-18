defmodule OpenPayments.Client do
  @moduledoc """
  Immutable configuration for Open Payments operations.

  `new_public/1` constructs a client without keys or tokens and makes no requests.
  Use it with `OpenPayments.WalletAddress.get/2`,
  `OpenPayments.WalletAddress.get_keys/2`, or
  `OpenPayments.IncomingPayment.get_public/2` for public reads.

  `new_authenticated/1` adds a wallet identity and an Ed25519 signing key.
  Use it with `OpenPayments.Grant.request/3` and `OpenPayments.Grant.continue/2`
  for signed grant initiation and continuation.
  Existing public operations remain unsigned with either client type.
  """

  alias OpenPayments.{Error, Key, Request, Response, Transport}
  alias OpenPayments.Request.Headers
  alias OpenPayments.WalletAddress.URL

  @derive {Inspect, only: [:allow_http]}
  @enforce_keys [:allow_http, :headers, :transport_options]
  defstruct [:allow_http, :headers, :transport_options, :wallet_address, :key]

  @authenticated_options ~w(wallet_address key key_id private_key)a

  @opaque t :: %__MODULE__{
            allow_http: boolean(),
            headers: map(),
            transport_options: keyword(),
            wallet_address: String.t() | nil,
            key: Key.t() | nil
          }

  @doc """
  Creates an unsigned client with validated configuration.

  Supports `allow_http` (default false), a custom `headers` map, positive millisecond
  `connect_timeout`, `receive_timeout`, `request_timeout`, and `pool_timeout` values,
  and a Req `adapter` module for tests. Transport defaults are 5 seconds for connect
  and pool waits, and 15 seconds for receive and complete-response waits.

  Accept and Accept-Encoding are managed by the client: public API responses are
  requested as JSON with identity encoding. Signing/transport headers cannot be
  supplied through custom headers. No redirects or automatic retries are enabled.
  """
  @spec new_public(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new_public(opts \\ []) do
    with :ok <- valid_options(opts),
         :ok <- valid_http_option(Keyword.get(opts, :allow_http, false)),
         {:ok, headers} <- Headers.normalize(Keyword.get(opts, :headers, %{})),
         :ok <- valid_headers(headers),
         {:ok, transport} <- Transport.configure(Keyword.drop(opts, [:allow_http, :headers])) do
      {:ok,
       %__MODULE__{
         allow_http: Keyword.get(opts, :allow_http, false),
         headers:
           Map.merge(headers, %{"accept" => "application/json", "accept-encoding" => "identity"}),
         transport_options: transport
       }}
    else
      {:error, error} -> configuration_error(error)
    end
  end

  @doc """
  Creates a client with a validated wallet identity and Ed25519 signing key.

  Accepts the same HTTP options as `new_public/1`, plus required `wallet_address`
  and either `key: key` from `OpenPayments.Key`, or `key_id` with an explicit
  `private_key` source: `{:pem, text}`, `{:file, path}`, `{:base64_pem, text}`,
  `{:jwk, map}`, or `{:seed, bytes}`. These two key configurations are mutually
  exclusive. Sources are not guessed and invalid keys are never replaced.

  Wallet identity follows discovery's URL/payment-pointer rules. Construction
  makes no network requests and does not verify registration of the public key.
  Public operations remain unsigned. Tokens belong to individual operations and
  are not stored on the client. Grants use `OpenPayments.Grant.request/3` and
  `OpenPayments.Grant.continue/2`;
  token and authenticated resource operations remain under development.
  """
  @spec new_authenticated(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new_authenticated(opts) do
    with :ok <- valid_options(opts),
         {:ok, client} <- new_public(Keyword.drop(opts, @authenticated_options)),
         {:ok, wallet} <- URL.prepare(Keyword.get(opts, :wallet_address), client.allow_http),
         {:ok, key} <- load_key(opts) do
      {:ok, %{client | wallet_address: wallet, key: key}}
    else
      {:error, error} -> configuration_error(error)
    end
  end

  @doc "Reports whether the client was constructed with a signing identity."
  @spec authenticated?(t()) :: boolean()
  def authenticated?(%__MODULE__{key: key}), do: not is_nil(key)

  @doc "Returns the normalized wallet identity, or nil for a public client."
  @spec wallet_address(t()) :: String.t() | nil
  def wallet_address(%__MODULE__{wallet_address: wallet}), do: wallet

  @doc "Reports whether HTTP was explicitly enabled for local development."
  @spec allow_http?(t()) :: boolean()
  def allow_http?(%__MODULE__{allow_http: allow_http}), do: allow_http

  @doc false
  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = client), do: {:ok, client}

  def validate(_client),
    do: invalid(:client, "must be constructed with OpenPayments.Client")

  @doc false
  @spec signing_public_jwk(t()) :: {:ok, OpenPayments.Types.JWK.t()} | {:error, Error.t()}
  def signing_public_jwk(%__MODULE__{key: nil}),
    do: invalid(:key, "requires an authenticated Open Payments client")

  def signing_public_jwk(%__MODULE__{key: key}) do
    with {:ok, key} <- Key.validate(key), do: {:ok, Key.public_jwk(key)}
  end

  @doc false
  @spec request(t(), atom(), String.t(), keyword()) :: {:ok, Response.t()} | {:error, Error.t()}
  def request(%__MODULE__{} = client, method, url, opts \\ []) do
    execute(client, method, url, Keyword.put(opts, :key, nil))
  end

  @doc false
  @spec request_signed(t(), atom(), String.t(), keyword()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def request_signed(client, method, url, opts \\ [])

  def request_signed(%__MODULE__{key: nil}, _method, _url, _opts),
    do: invalid(:key, "requires an authenticated Open Payments client")

  def request_signed(%__MODULE__{} = client, method, url, opts),
    do: execute(client, method, url, Keyword.put(opts, :key, client.key))

  defp execute(client, method, url, opts) do
    opts = Keyword.merge(opts, allow_http: client.allow_http, headers: client.headers)

    with {:ok, request} <- Request.prepare(method, url, opts),
         do: Transport.execute(request, client.transport_options)
  end

  defp load_key(opts) do
    cond do
      Keyword.has_key?(opts, :key) and
          (Keyword.has_key?(opts, :key_id) or Keyword.has_key?(opts, :private_key)) ->
        invalid(:key, "key and private_key/key_id configurations are mutually exclusive")

      Keyword.has_key?(opts, :key) ->
        Key.validate(opts[:key])

      true ->
        import_key(opts[:private_key], opts[:key_id])
    end
  end

  defp import_key({:pem, value}, key_id), do: Key.from_pem(value, key_id)
  defp import_key({:file, value}, key_id), do: Key.from_file(value, key_id)
  defp import_key({:base64_pem, value}, key_id), do: Key.from_base64_pem(value, key_id)
  defp import_key({:jwk, value}, key_id), do: Key.from_jwk(value, key_id)
  defp import_key({:seed, value}, key_id), do: Key.from_seed(value, key_id)

  defp import_key(_source, _key_id),
    do: invalid(:private_key, "must be an explicitly tagged supported private-key source")

  defp configuration_error(error),
    do:
      {:error,
       %{error | kind: :configuration, description: "Invalid Open Payments client configuration"}}

  defp valid_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and length(Enum.uniq(Keyword.keys(opts))) == length(opts),
      do: :ok,
      else: invalid(:options, "must be a keyword list of unique supported options")
  end

  defp valid_options(_opts), do: invalid(:options, "must be a keyword list")

  defp valid_http_option(value) when is_boolean(value), do: :ok
  defp valid_http_option(_value), do: invalid(:allow_http, "must be a boolean")

  defp valid_headers(headers) do
    if Map.has_key?(headers, "accept") or Map.has_key?(headers, "accept-encoding"),
      do: invalid(:headers, "Accept and Accept-Encoding are managed by the client"),
      else: :ok
  end

  defp invalid(field, message),
    do:
      {:error,
       %Error{kind: :configuration, validation_errors: [%{field: field, message: message}]}}
end
