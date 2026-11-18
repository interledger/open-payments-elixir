defmodule OpenPayments.Test.Interoperability do
  @moduledoc false

  import ExUnit.Assertions

  alias OpenPayments.{Client, Error, IncomingPayment, Key, OutgoingPayment, Quote}

  @derive {Inspect, only: [:read_kind]}
  defstruct [:client, :wallet_address, :read_kind, :resource_url, :access_token, :public_key]

  @prefix "OPEN_PAYMENTS_INTEGRATION_"
  @read_kinds ~w(incoming quote outgoing grant_spent)

  def public_config(get_env \\ &System.get_env/1) do
    %__MODULE__{
      client: result!(Client.new_public()),
      wallet_address: required!(get_env, "WALLET_ADDRESS")
    }
  end

  def signed_config(get_env \\ &System.get_env/1) do
    config = public_config(get_env)
    kind = required!(get_env, "READ_KIND")

    unless kind in @read_kinds,
      do: flunk(@prefix <> "READ_KIND must be incoming, quote, outgoing or grant_spent")

    resource = if kind == "grant_spent", do: nil, else: required!(get_env, "RESOURCE_URL")

    key =
      result!(Key.from_file(required!(get_env, "PRIVATE_KEY_FILE"), required!(get_env, "KEY_ID")))

    token = read_token!(required!(get_env, "ACCESS_TOKEN_FILE"))
    client = result!(Client.new_authenticated(wallet_address: config.wallet_address, key: key))

    %{
      config
      | client: client,
        read_kind: kind,
        resource_url: resource,
        access_token: token,
        public_key: Key.public_jwk(key)
    }
  end

  def registered?(config, keys) do
    expected = config.public_key

    Enum.any?(keys.keys, fn key ->
      {key.kid, key.alg, key.kty, key.crv, key.x} ==
        {expected.kid, expected.alg, expected.kty, expected.crv, expected.x}
    end)
  end

  def read(config, wallet) do
    opts = [access_token: config.access_token]

    case config.read_kind do
      "incoming" ->
        IncomingPayment.get(config.client, config.resource_url, opts)

      "quote" ->
        Quote.get(config.client, config.resource_url, opts)

      "outgoing" ->
        OutgoingPayment.get(config.client, config.resource_url, opts)

      "grant_spent" ->
        OutgoingPayment.get_grant_spent_amounts(config.client, wallet.resource_server, opts)
    end
  end

  def result!({:ok, value}), do: value

  def result!({:error, %Error{} = error}) do
    # Provider payloads, URLs, codes and descriptions can contain credentials.
    flunk(
      "Open Payments check failed: kind=#{error.kind}, status=#{inspect(error.status)}, " <>
        "operation=#{inspect(error.operation)}"
    )
  end

  defp required!(get_env, suffix) do
    name = @prefix <> suffix

    case get_env.(name) do
      value when is_binary(value) ->
        if String.valid?(value) and String.trim(value) != "",
          do: value,
          else: flunk("Set #{name} before running this integration check")

      _ ->
        flunk("Set #{name} before running this integration check")
    end
  end

  defp read_token!(path) do
    case File.read(path) do
      {:ok, value} ->
        if String.valid?(value) and
             Regex.match?(~r/\A[A-Za-z0-9\-._~+\/]+=*\z/, String.trim(value)),
           do: String.trim(value),
           else: flunk(@prefix <> "ACCESS_TOKEN_FILE must contain one token68 access token")

      {:error, _reason} ->
        flunk(@prefix <> "ACCESS_TOKEN_FILE must be a readable token file")
    end
  end
end
