defmodule OpenPayments.WalletAddress.URL do
  @moduledoc false

  alias OpenPayments.{Error, PaymentPointer}
  alias OpenPayments.Request.URL, as: RequestURL
  alias OpenPayments.Types.Validation

  @spec prepare(String.t(), boolean()) :: {:ok, String.t()} | {:error, Error.t()}
  def prepare(address, allow_http) do
    with {:ok, url} <- resolve(address), do: validate_url(url, allow_http)
  end

  defp validate_url(url, allow_http) do
    with true <- Validation.absolute_uri?(url),
         %{} = parts <- :uri_string.parse(url),
         false <- Map.has_key?(parts, :query),
         true <-
           not Map.has_key?(parts, :port) or
             (String.downcase(parts.scheme) == "http" and allow_http),
         {:ok, url} <- RequestURL.prepare(url, allow_http) do
      {:ok, url}
    else
      _other -> invalid()
    end
  end

  defp resolve("$" <> _address = pointer), do: PaymentPointer.to_url(pointer)
  defp resolve(address), do: {:ok, address}

  defp invalid,
    do:
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
