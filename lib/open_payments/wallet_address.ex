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
  alias OpenPayments.Types.{JWKS, Validation, WalletAddress}

  @doc "Fetches and validates public wallet information without signing the request."
  @spec get(Client.t(), String.t()) :: {:ok, WalletAddress.t()} | {:error, Error.t()}
  def get(client, address),
    do: fetch(client, address, :get_wallet_address, &WalletAddress.from_map/1)

  @doc """
  Fetches the public JWKS bound to a wallet URL or payment pointer.

  Appends `jwks.json` to the resolved wallet URL, reusing an existing trailing
  slash. Root payment pointers first resolve to `/.well-known/pay`. This operation
  is unsigned, does not follow redirects or cache keys, and validates each public
  key using the shared schema. Key selection and signature verification are
  separate from discovery.
  """
  @spec get_keys(Client.t(), String.t()) :: {:ok, JWKS.t()} | {:error, Error.t()}
  def get_keys(client, address),
    do: fetch(client, address, :get_wallet_address_keys, &JWKS.from_map/1)

  defp fetch(client, address, operation, decoder) do
    with {:ok, client} <- Client.validate(client),
         {:ok, url} <- resolve(address),
         {:ok, url} <- wallet_url(url, Client.allow_http?(client)),
         {:ok, response} <- Client.request(client, :get, resource_url(url, operation)),
         {:ok, data} <- JSON.decode(response, [200], operation),
         {:ok, resource} <- decode(data, response.status, decoder) do
      {:ok, resource}
    else
      {:error, error} -> {:error, %{error | operation: operation}}
    end
  end

  defp resource_url(url, :get_wallet_address), do: url

  defp resource_url(url, :get_wallet_address_keys),
    do: url <> if(String.ends_with?(url, "/"), do: "jwks.json", else: "/jwks.json")

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

  defp decode(data, status, decoder) do
    case decoder.(data) do
      {:ok, resource} ->
        {:ok, resource}

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
