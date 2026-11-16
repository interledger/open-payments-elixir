defmodule OpenPayments.PaymentPointer do
  @moduledoc """
  Converts payment-pointer shorthand into an HTTPS discovery URL.

  Payment pointers use `$host[/path]` syntax. A missing or root path resolves to
  `/.well-known/pay`. Other paths, including their percent encoding and trailing
  slashes, are preserved. User-info, explicit ports, queries, and fragments are
  forbidden, including empty query and fragment components.

  This is a pure syntax conversion. Whether the resulting endpoint supports Open
  Payments must be checked during discovery. Apply it to user input rather than
  to wallet-address response fields.

  See the [payment-pointer specification](https://paymentpointers.org/syntax/).

  ## Examples

      iex> OpenPayments.PaymentPointer.to_url("$wallet.example.com")
      {:ok, "https://wallet.example.com/.well-known/pay"}

      iex> OpenPayments.PaymentPointer.to_url("$wallet.example.com/")
      {:ok, "https://wallet.example.com/.well-known/pay"}

      iex> OpenPayments.PaymentPointer.to_url("$wallet.example.com/alice")
      {:ok, "https://wallet.example.com/alice"}
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.Validation

  @forbidden_components [:userinfo, :port, :query, :fragment]

  @doc "Converts a valid payment pointer to a full HTTPS URL without making a request."
  @spec to_url(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def to_url("$" <> address) do
    url = "https://" <> address

    if Validation.absolute_uri?(url) do
      parts = :uri_string.parse(url)

      if Enum.any?(@forbidden_components, &Map.has_key?(parts, &1)) do
        invalid()
      else
        {:ok, resolve_path(url, Map.get(parts, :path, ""))}
      end
    else
      invalid()
    end
  end

  def to_url(_pointer), do: invalid()

  defp resolve_path(url, path) when path in ["", "/"] do
    String.trim_trailing(url, "/") <> "/.well-known/pay"
  end

  defp resolve_path(url, _path), do: url

  defp invalid do
    {:error,
     %Error{
       kind: :validation,
       description: "Invalid payment pointer",
       validation_errors: [
         %{
           field: :payment_pointer,
           message: "must use $host[/path] syntax without user-info, port, query, or fragment"
         }
       ]
     }}
  end
end
