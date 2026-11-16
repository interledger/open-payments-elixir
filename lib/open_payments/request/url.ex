defmodule OpenPayments.Request.URL do
  @moduledoc false

  alias OpenPayments.Error
  alias OpenPayments.Types.Validation

  @spec prepare(String.t(), boolean()) :: {:ok, String.t()} | {:error, Error.t()}
  def prepare(url, allow_http) do
    with true <- Validation.absolute_uri?(url),
         %{} = parts <- :uri_string.parse(url),
         false <- Map.has_key?(parts, :userinfo) or Map.has_key?(parts, :fragment),
         {:ok, uri} <- URI.new(url),
         true <- uri.scheme == "https" or (uri.scheme == "http" and allow_http),
         true <- is_integer(uri.port) and uri.port in 0..65_535 do
      query = if uri.query == "", do: nil, else: uri.query
      uri = %{uri | host: String.downcase(uri.host), path: uri.path || "/", query: query}
      {:ok, URI.to_string(uri)}
    else
      _other ->
        {:error,
         %Error{
           kind: :validation,
           description: "Invalid Open Payments request URL",
           validation_errors: [
             %{
               field: :url,
               message:
                 "must be an absolute HTTPS URL without user-info or fragment and with a valid port; HTTP requires allow_http"
             }
           ]
         }}
    end
  end
end
