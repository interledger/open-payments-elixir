defmodule OpenPayments.Integration.DiscoveryTest do
  use ExUnit.Case, async: false

  alias OpenPayments.Test.Interoperability
  alias OpenPayments.Types.{JWKS, WalletAddress}
  alias OpenPayments.WalletAddress, as: Discovery

  @moduletag :integration

  test "discovers typed public wallet information over HTTPS" do
    config = Interoperability.public_config()
    wallet = Interoperability.result!(Discovery.get(config.client, config.wallet_address))
    assert %WalletAddress{} = wallet
  end

  test "discovers the wallet's typed public signing-key registry over HTTPS" do
    config = Interoperability.public_config()
    keys = Interoperability.result!(Discovery.get_keys(config.client, config.wallet_address))
    assert %JWKS{} = keys
  end
end
