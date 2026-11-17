defmodule OpenPayments.IncomingPayment do
  @moduledoc """
  Incoming-payment operations on an Open Payments resource server.

  Public reads use an unsigned GET to a complete incoming-payment URL and validate
  the current public response schema. Resource URLs are opaque: their paths and
  queries are not inferred from wallet addresses or provider-specific layouts.
  HTTPS is required unless HTTP was explicitly enabled on the client. Redirects
  and automatic retries are disabled.
  """

  alias OpenPayments.{Client, Error}
  alias OpenPayments.Response.JSON
  alias OpenPayments.Types.PublicIncomingPayment

  @operation :get_public_incoming_payment

  @doc """
  Fetches public incoming-payment details without signing or an access token.

  Accepts a full resource URL, including a nondefault HTTPS port or query if
  needed. Payment pointers identify wallets and are not resource URLs. Success
  returns a `PublicIncomingPayment` struct; errors carry the operation
  `:get_public_incoming_payment` and applicable status or validation paths.

  This read does not complete or create a payment, connect to STREAM, select a
  payment method, or cache the response. Explicit JSON exports of returned methods
  contain ILP shared secrets; inspection omits them.
  """
  @spec get_public(Client.t(), String.t()) ::
          {:ok, PublicIncomingPayment.t()} | {:error, Error.t()}
  def get_public(client, url) do
    with {:ok, client} <- Client.validate(client),
         {:ok, response} <- Client.request(client, :get, url),
         {:ok, data} <- JSON.decode(response, [200], @operation),
         {:ok, payment} <- decode(data, response.status) do
      {:ok, payment}
    else
      {:error, error} -> {:error, %{error | operation: @operation}}
    end
  end

  defp decode(data, status) do
    case PublicIncomingPayment.from_map(data) do
      {:ok, payment} ->
        {:ok, payment}

      {:error, error} ->
        {:error,
         %{
           error
           | kind: :decoding,
             status: status,
             code: "invalid_response",
             description: "Invalid Open Payments public incoming-payment response"
         }}
    end
  end
end
