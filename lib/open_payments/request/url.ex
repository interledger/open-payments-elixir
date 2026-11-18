defmodule OpenPayments.Request.URL do
  @moduledoc false

  alias OpenPayments.Error
  alias OpenPayments.Types.Validation

  # Internal callers supply a fixed resource path; queries on the base would
  # make simple appending ambiguous, including a trailing empty query marker.
  @spec append_path(String.t(), boolean(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def append_path(base_url, allow_http, path) do
    with {:ok, url} <- prepare(base_url, allow_http),
         {:ok, %URI{query: nil}} <- URI.new(base_url) do
      {:ok, url <> if(String.ends_with?(url, "/"), do: path, else: "/" <> path)}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      _other ->
        {:error,
         %Error{
           kind: :validation,
           validation_errors: [
             %{field: :url, message: "must not contain a query when appending a resource path"}
           ]
         }}
    end
  end

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
