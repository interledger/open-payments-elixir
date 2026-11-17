defmodule OpenPayments.Client do
  @moduledoc """
  Immutable configuration for Open Payments operations.

  `new_public/1` constructs a client without keys or tokens and makes no requests.
  Use it with `OpenPayments.WalletAddress.get/2` or
  `OpenPayments.WalletAddress.get_keys/2` for public discovery.
  """

  alias OpenPayments.{Error, Request, Response, Transport}
  alias OpenPayments.Request.Headers

  @derive {Inspect, only: [:allow_http]}
  @enforce_keys [:allow_http, :headers, :transport_options]
  defstruct [:allow_http, :headers, :transport_options]

  @opaque t :: %__MODULE__{allow_http: boolean(), headers: map(), transport_options: keyword()}

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
      {:error, error} ->
        {:error,
         %{
           error
           | kind: :configuration,
             description: "Invalid Open Payments client configuration"
         }}
    end
  end

  @doc "Reports whether HTTP was explicitly enabled for local development."
  @spec allow_http?(t()) :: boolean()
  def allow_http?(%__MODULE__{allow_http: allow_http}), do: allow_http

  @doc false
  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = client), do: {:ok, client}

  def validate(_client),
    do: invalid(:client, "must be constructed with OpenPayments.Client")

  @doc false
  @spec request(t(), atom(), String.t(), keyword()) :: {:ok, Response.t()} | {:error, Error.t()}
  def request(%__MODULE__{} = client, method, url, opts \\ []) do
    opts = Keyword.merge(opts, allow_http: client.allow_http, headers: client.headers)

    with {:ok, request} <- Request.prepare(method, url, opts),
         do: Transport.execute(request, client.transport_options)
  end

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
