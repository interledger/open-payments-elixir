defmodule OpenPayments.Transport do
  @moduledoc false

  alias OpenPayments.{Error, Request, Response}

  @timeouts [
    connect_timeout: 5_000,
    receive_timeout: 15_000,
    request_timeout: 15_000,
    pool_timeout: 5_000
  ]
  @options Keyword.keys(@timeouts) ++ [:adapter]
  @safe_reasons ~w(timeout nxdomain econnrefused closed enetunreach ehostunreach econnreset)a

  @spec execute(Request.t(), keyword()) :: {:ok, Response.t()} | {:error, Error.t()}
  def execute(request, opts \\ [])

  def execute(%Request{} = request, opts) do
    with {:ok, opts} <- options(opts) do
      request
      |> req_request(opts)
      |> Req.Request.run_request()
      |> result()
    end
  rescue
    _error -> failed()
  end

  def execute(_request, _opts), do: invalid(:request, "must be a prepared Open Payments request")

  defp req_request(request, opts) do
    # No built-in steps: no global defaults, plugins, re-encoding, compression,
    # redirect/retry handling, HTTP-status exceptions, or response decoding.
    Req.Request.new(
      method: request.method,
      url: request.url,
      headers: request.headers |> Map.put("host", authority(request.url)) |> Map.to_list(),
      body: request.body,
      adapter: opts[:adapter],
      options: [
        connect_options: [timeout: opts[:connect_timeout]],
        receive_timeout: opts[:receive_timeout],
        request_timeout: opts[:request_timeout],
        pool_timeout: opts[:pool_timeout]
      ]
    )
  end

  # Own Host explicitly: Req.Finch's implicit IPv6 Host omits a nondefault port.
  defp authority(url) do
    uri = URI.parse(url)
    host = if String.contains?(uri.host, ":"), do: "[#{uri.host}]", else: uri.host
    if uri.port == URI.default_port(uri.scheme), do: host, else: "#{host}:#{uri.port}"
  end

  defp result({_request, %Req.Response{} = response}) do
    data = Req.Response.to_map(response)

    {:ok,
     %Response{
       status: data.status,
       headers: data.headers,
       body: data.body,
       trailers: data.trailers
     }}
  end

  defp result({_request, %Req.TransportError{reason: reason}}) when reason in @safe_reasons,
    do: failed(Atom.to_string(reason))

  defp result({_request, _error}), do: failed()

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in @options)) and
         length(Enum.uniq(Keyword.keys(opts))) == length(opts) do
      validate_options(Keyword.merge(@timeouts ++ [adapter: Req.Finch], opts))
    else
      invalid(:options, "must contain unique supported transport options")
    end
  end

  defp options(_opts), do: invalid(:options, "must be a keyword list")

  defp validate_options(opts) do
    case Enum.find(@timeouts, fn {name, _default} ->
           value = opts[name]
           not is_integer(value) or value <= 0
         end) do
      {name, _default} -> invalid(name, "must be a positive timeout in milliseconds")
      nil -> validate_adapter(opts)
    end
  end

  defp validate_adapter(opts) do
    adapter = opts[:adapter]

    if is_atom(adapter) and Code.ensure_loaded?(adapter) and function_exported?(adapter, :run, 1),
      do: {:ok, opts},
      else: invalid(:adapter, "must be a Req adapter module exporting run/1")
  end

  defp invalid(field, message) do
    {:error,
     %Error{
       kind: :configuration,
       description: "Invalid Open Payments transport configuration",
       validation_errors: [%{field: field, message: message}]
     }}
  end

  defp failed(code \\ nil),
    do:
      {:error,
       %Error{kind: :transport, code: code, description: "Open Payments HTTP request failed"}}
end
