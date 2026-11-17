defmodule OpenPayments.WalletAddress do
  @moduledoc """
  Public wallet-address discovery using full wallet URLs or payment pointers.

  Discovery uses an unsigned GET and validates the returned wallet information.
  Production identifiers use HTTPS without user-info, explicit port, query, or
  fragment. With HTTP explicitly enabled on the client, HTTP URLs and local ports
  are accepted for development. Paths and returned server URLs are not inferred
  from a provider's layout. Redirects are returned as HTTP errors.
  """

  alias OpenPayments.{Client, Error, PaymentPointer}
  alias OpenPayments.Request.URL
  alias OpenPayments.Response.JSON
  alias OpenPayments.Types.{Validation, WalletAddress}

  @operation :get_wallet_address

  @doc "Fetches and validates public wallet information without signing the request."
  @spec get(Client.t(), String.t()) :: {:ok, WalletAddress.t()} | {:error, Error.t()}
  def get(client, address) do
    with {:ok, client} <- Client.validate(client),
         {:ok, url} <- resolve(address),
         {:ok, url} <- wallet_url(url, Client.allow_http?(client)),
         {:ok, response} <- Client.request(client, :get, url),
         {:ok, data} <- JSON.decode(response, [200], @operation),
         {:ok, wallet} <- decode(data, response.status) do
      {:ok, wallet}
    else
      {:error, error} -> {:error, %{error | operation: @operation}}
    end
  end

  defp resolve("$" <> _address = pointer), do: PaymentPointer.to_url(pointer)
  defp resolve(address), do: {:ok, address}

  defp wallet_url(url, allow_http) do
    with true <- Validation.absolute_uri?(url),
         %{} = parts <- :uri_string.parse(url),
         false <- Map.has_key?(parts, :query),
         true <-
           not Map.has_key?(parts, :port) or
             (String.downcase(parts.scheme) == "http" and allow_http),
         {:ok, url} <- URL.prepare(url, allow_http) do
      {:ok, url}
    else
      _other ->
        {:error,
         %Error{
           kind: :validation,
           description: "Invalid Open Payments wallet URL",
           validation_errors: [
             %{
               field: :wallet_address,
               message:
                 "must be a wallet URL without user-info, port, query or fragment; HTTP development URLs may use a port"
             }
           ]
         }}
    end
  end

  defp decode(data, status) do
    case WalletAddress.from_map(data) do
      {:ok, wallet} ->
        {:ok, wallet}

      {:error, error} ->
        {:error,
         %{
           error
           | kind: :decoding,
             status: status,
             code: "invalid_response",
             description: "Invalid Open Payments wallet-address response"
         }}
    end
  end
end
