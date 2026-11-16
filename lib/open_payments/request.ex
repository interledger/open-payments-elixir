defmodule OpenPayments.Request do
  @moduledoc false

  alias MessageSignatures.Message
  alias OpenPayments.{Error, Key}
  alias OpenPayments.Request.{Headers, URL}
  alias OpenPayments.Signature.ContentHeaders
  alias OpenPayments.Signature.Headers, as: SignatureHeaders

  @derive {Inspect, only: [:method]}
  @enforce_keys [:method, :url, :headers, :body]
  defstruct [:method, :url, :headers, :body]

  @methods %{"GET" => :get, "POST" => :post, "DELETE" => :delete}
  @options ~w(key access_token headers json body allow_http created)a

  @type t :: %__MODULE__{
          method: :get | :post | :delete,
          url: String.t(),
          headers: %{String.t() => String.t()},
          body: binary() | nil
        }

  # A key explicitly requests signing; callers omit it for public operations.
  # This builder does not infer operation permissions or validate payload schemas.
  @spec prepare(atom() | String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def prepare(method, url, opts \\ []) do
    with {:ok, opts} <- options(opts),
         {:ok, method} <- method(method),
         {:ok, url} <- URL.prepare(url, opts[:allow_http]),
         {:ok, headers} <- Headers.normalize(opts[:headers]),
         {:ok, body} <- body(opts),
         {:ok, content_headers} <- ContentHeaders.build(body),
         headers = Map.merge(%{"accept" => "application/json"}, headers),
         headers = Map.merge(headers, content_headers),
         headers = authorization(headers, opts[:access_token]),
         {:ok, signature_headers} <- sign(opts, method, url, headers, body) do
      {:ok,
       %__MODULE__{
         method: method,
         url: url,
         headers: Map.merge(headers, signature_headers),
         body: body
       }}
    end
  end

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in @options)) and
         length(Enum.uniq(Keyword.keys(opts))) == length(opts) do
      validate_options(opts)
    else
      invalid(:options, "must be a keyword list of unique supported options")
    end
  end

  defp options(_opts), do: invalid(:options, "must be a keyword list of unique supported options")

  defp validate_options(opts) do
    defaults = [
      key: nil,
      access_token: nil,
      headers: %{},
      allow_http: false,
      created: System.system_time(:second)
    ]

    opts = Keyword.merge(defaults, opts)
    key = opts[:key]
    token = opts[:access_token]
    created = opts[:created]

    checks = [
      {is_nil(key) or is_struct(key, Key), :key, "must be an Open Payments key"},
      {is_nil(token) or token?(token), :access_token, "must be a token68 string"},
      {is_nil(token) or not is_nil(key), :key, "must be provided with access_token"},
      {is_boolean(opts[:allow_http]), :allow_http, "must be a boolean"},
      {valid_created?(created), :created,
       "must be a nonnegative structured-field Unix timestamp"},
      {not (Keyword.has_key?(opts, :json) and Keyword.has_key?(opts, :body)), :body,
       "json and body are mutually exclusive"}
    ]

    case Enum.find(checks, fn {valid, _field, _message} -> not valid end) do
      nil -> {:ok, opts}
      {false, field, message} -> invalid(field, message)
    end
  end

  defp valid_created?(created),
    do: is_integer(created) and created >= 0 and created <= 999_999_999_999_999

  defp token?(token) when is_binary(token),
    do: Regex.match?(~r/\A[A-Za-z0-9._~+\/-]+=*\z/, token)

  defp token?(_token), do: false

  defp method(method) when method in [:get, :post, :delete], do: {:ok, method}

  defp method(method) when is_binary(method) do
    case Map.fetch(@methods, method) do
      {:ok, method} -> {:ok, method}
      :error -> invalid(:method, "must be get, post or delete, or their uppercase HTTP strings")
    end
  end

  defp method(_method),
    do: invalid(:method, "must be get, post or delete, or their uppercase HTTP strings")

  defp body(opts) do
    case Keyword.fetch(opts, :json) do
      {:ok, json} -> encode_json(json)
      :error -> {:ok, Keyword.get(opts, :body)}
    end
  end

  defp encode_json(json) do
    case Jason.encode(json) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _error} -> invalid(:body, "must be JSON encodable")
    end
  rescue
    _error -> invalid(:body, "must be JSON encodable")
  end

  defp authorization(headers, nil), do: headers
  defp authorization(headers, token), do: Map.put(headers, "authorization", "GNAP " <> token)

  defp sign(opts, method, url, headers, body) do
    case opts[:key] do
      nil ->
        {:ok, %{}}

      key ->
        message = Message.from_request(method: method, url: url, headers: Map.to_list(headers))
        SignatureHeaders.build(key, message, not is_nil(body), opts[:created])
    end
  end

  defp invalid(field, message) do
    {:error,
     %Error{
       kind: :validation,
       description: "Invalid Open Payments request",
       validation_errors: [%{field: field, message: message}]
     }}
  end
end
