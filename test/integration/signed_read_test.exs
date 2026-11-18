defmodule OpenPayments.Integration.SignedReadTest do
  use ExUnit.Case, async: false

  alias OpenPayments.Test.Interoperability
  alias OpenPayments.WalletAddress

  @moduletag :integration

  test "reads an existing resource with the registered key and an issued grant token" do
    config = Interoperability.signed_config()
    wallet = Interoperability.result!(WalletAddress.get(config.client, config.wallet_address))
    keys = Interoperability.result!(WalletAddress.get_keys(config.client, config.wallet_address))

    assert Interoperability.registered?(config, keys),
           "Configured signing key is not published in this wallet's JWKS"

    config |> Interoperability.read(wallet) |> Interoperability.result!()
  end
end
