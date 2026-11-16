defmodule OpenPayments.Types.WalletAddressTest do
  use ExUnit.Case, async: true

  alias OpenPayments.Error
  alias OpenPayments.Specification
  alias OpenPayments.Types.WalletAddress

  @required [
    {"id", :id},
    {"assetCode", :asset_code},
    {"assetScale", :asset_scale},
    {"authServer", :auth_server},
    {"resourceServer", :resource_server}
  ]
  # Endpoint layout from https://rafiki.dev/overview/concepts/payment-pointers/.
  @tenant "123e4567-e89b-12d3-a456-426614174000"
  @wallet %{
    "id" => "https://wallet.example.com/alice",
    "assetCode" => "USD",
    "assetScale" => 2,
    "authServer" => "https://auth.wallet.example.com/#{@tenant}",
    "resourceServer" => "https://wallet.example.com/#{@tenant}"
  }

  test "the model contract matches the bundled wallet-address schema" do
    {:ok, schema} = Specification.fetch_schema(:wallet_address, "wallet-address")
    assert schema["type"] == "object"
    assert schema["additionalProperties"] == true
    assert Enum.sort(schema["required"]) == Enum.sort(Enum.map(@required, &elem(&1, 0)))

    for field <- ~w(id authServer resourceServer) do
      assert Map.take(schema["properties"][field], ~w(type format)) == %{
               "type" => "string",
               "format" => "uri"
             }
    end

    assert schema["properties"]["publicName"]["type"] == "string"
    assert schema["properties"]["assetCode"]["type"] == "string"

    assert Map.take(schema["properties"]["assetScale"], ~w(type minimum maximum)) == %{
             "type" => "integer",
             "minimum" => 0,
             "maximum" => 255
           }
  end

  test "decodes required fields to typed snake_case fields" do
    assert {:ok, wallet} = WalletAddress.from_map(@wallet)
    assert %WalletAddress{} = wallet
    assert wallet.id == @wallet["id"]
    assert wallet.asset_code == "USD"
    assert wallet.asset_scale == 2
    assert wallet.auth_server == @wallet["authServer"]
    assert wallet.resource_server == @wallet["resourceServer"]
    assert wallet.public_name == nil
    assert wallet.extensions == %{}
    assert :ok = WalletAddress.validate(wallet)
    assert WalletAddress.to_map(wallet) == @wallet
  end

  test "decodes the official specification examples" do
    {:ok, schema} = Specification.fetch_schema(:wallet_address, "wallet-address")

    for example <- schema["examples"] do
      assert {:ok, wallet} = WalletAddress.from_map(example)
      assert WalletAddress.to_map(wallet) == example
    end
  end

  test "reports each missing or null required field" do
    for {wire, field} <- @required do
      for invalid <- [Map.delete(@wallet, wire), Map.put(@wallet, wire, nil)] do
        assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]}} =
                 WalletAddress.from_map(invalid)
      end
    end

    assert {:error, %Error{validation_errors: issues}} = WalletAddress.from_map(%{})
    assert Enum.map(issues, & &1.field) == Enum.map(@required, &elem(&1, 1))
  end

  test "distinguishes an omitted public name from an explicit null" do
    assert {:ok, wallet} = WalletAddress.from_map(@wallet)
    refute Map.has_key?(Jason.decode!(Jason.encode!(wallet)), "publicName")

    for value <- [nil, 123, false, <<255>>] do
      assert {:error, %Error{validation_errors: [%{field: :public_name}]}} =
               WalletAddress.from_map(Map.put(@wallet, "publicName", value))
    end
  end

  test "preserves public names, including an empty string" do
    for name <- ["Alice", "Comunitate 🌍", ""] do
      wire = Map.put(@wallet, "publicName", name)
      assert {:ok, wallet} = WalletAddress.from_map(wire)
      assert wallet.public_name == name
      assert WalletAddress.to_map(wallet) == wire
      assert Jason.decode!(Jason.encode!(wallet)) == wire
    end
  end

  test "rejects relative and malformed URI fields" do
    for {wire, field} <- [
          {"id", :id},
          {"authServer", :auth_server},
          {"resourceServer", :resource_server}
        ],
        value <- [
          "",
          "/relative/path",
          "//wallet.example/alice",
          "not a uri",
          "https://",
          "https:/path",
          "https://wallet.example/%ZZ",
          "https://wallet.example/%",
          "https://wallet.example/%0",
          "https://[broken",
          "https://wallet.example/\n",
          "https://wallet.example/α",
          123,
          false,
          <<255>>
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               WalletAddress.from_map(Map.put(@wallet, wire, value))
    end
  end

  test "preserves URL spelling, tenant paths, server ports and queries, and percent escapes" do
    wire = %{
      @wallet
      | "id" => "HTTPS://Wallet.Example.COM/Alice%20Account",
        "authServer" => "https://auth.wallet.example.com:8443/#{@tenant}?audience=payments",
        "resourceServer" => "https://wallet.example.com:8443/#{@tenant}?existing=1"
    }

    assert {:ok, wallet} = WalletAddress.from_map(wire)
    assert WalletAddress.to_map(wallet) == wire
  end

  test "accepts tenant-scoped and root server URLs without requiring a provider's layout" do
    for {auth, resource} <- [
          {@wallet["authServer"], @wallet["resourceServer"]},
          {"https://auth.wallet.example.com", "https://wallet.example.com"},
          {"https://auth.wallet.example.com/authorize", "https://wallet.example.com/op"},
          {"https://auth.wallet.example.com/other-tenant",
           "https://wallet.example.com/other-tenant"},
          {"https://[2001:db8::1]:8443/auth", "https://[2001:db8::2]:8443/op"}
        ] do
      wire = %{@wallet | "authServer" => auth, "resourceServer" => resource}
      assert {:ok, wallet} = WalletAddress.from_map(wire)
      assert WalletAddress.to_map(wallet) == wire
    end
  end

  test "accepts full wallet URLs used by path and well-known payment-pointer endpoints" do
    for id <- [
          "https://wallet.example.com",
          "https://wallet.example.com/",
          "https://wallet.example.com/.well-known/pay",
          "https://wallet.example.com/alice",
          "https://[2001:db8::1]/alice"
        ] do
      assert {:ok, wallet} = WalletAddress.from_map(Map.put(@wallet, "id", id))
      assert wallet.id == id
    end
  end

  test "payment-pointer shorthand is discovery input rather than a server-response URL" do
    for {wire, field} <- [
          {"id", :id},
          {"authServer", :auth_server},
          {"resourceServer", :resource_server}
        ],
        pointer <- ["$wallet.example.com", "$wallet.example.com/", "$wallet.example.com/alice"] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               WalletAddress.from_map(Map.put(@wallet, wire, pointer))
    end
  end

  test "response URI validation is separate from stricter production request policies" do
    for {wire, field} <- [
          {"id", :id},
          {"authServer", :auth_server},
          {"resourceServer", :resource_server}
        ],
        url <- [
          "urn:example:wallet:alice",
          "mailto:alice@example.com",
          "ftp://wallet.example.com/alice",
          "https://alice:secret@wallet.example.com/alice",
          "https://@wallet.example.com/alice",
          "https://wallet.example.com/alice#details",
          "https://wallet.example.com/alice#",
          "https://wallet.example.com/alice?view=public",
          "https://wallet.example.com:443/alice",
          "https://wallet.example.com:8443/alice"
        ] do
      assert {:ok, wallet} = WalletAddress.from_map(Map.put(@wallet, wire, url))
      assert Map.fetch!(wallet, field) == url
      assert :ok = WalletAddress.validate(wallet)
    end
  end

  test "decodes local playground HTTP data without rewriting it or requiring transport options" do
    # Ports documented at https://rafiki.dev/integration/playground/overview/.
    wire = %{
      @wallet
      | "id" => "http://localhost:3000/accounts/gfranklin",
        "authServer" => "http://localhost:3006/#{@tenant}",
        "resourceServer" => "http://localhost:3000/#{@tenant}"
    }

    assert {:ok, wallet} = WalletAddress.from_map(wire)
    assert :ok = WalletAddress.validate(wallet)
    assert WalletAddress.to_map(wallet) == wire
    assert Jason.decode!(Jason.encode!(wallet)) == wire
  end

  test "enforces scale bounds and string asset codes without ISO-specific restrictions" do
    for scale <- [0, 255], code <- ["USD", "custom-token", ""] do
      assert {:ok, _} =
               WalletAddress.from_map(%{@wallet | "assetScale" => scale, "assetCode" => code})
    end

    for scale <- [-1, 256, 2.0, "2", true] do
      assert {:error, %Error{validation_errors: [%{field: :asset_scale}]}} =
               WalletAddress.from_map(Map.put(@wallet, "assetScale", scale))
    end

    for code <- [123, :USD, false, <<255>>] do
      assert {:error, %Error{validation_errors: [%{field: :asset_code}]}} =
               WalletAddress.from_map(Map.put(@wallet, "assetCode", code))
    end
  end

  test "retains additional JSON fields with nested data and explicit nulls" do
    wire = Map.merge(@wallet, %{"custom" => %{"labels" => ["one", nil, 3]}, "optional" => nil})
    assert {:ok, wallet} = WalletAddress.from_map(wire)
    assert wallet.extensions == Map.take(wire, ["custom", "optional"])
    assert :ok = WalletAddress.validate(wallet)
    assert WalletAddress.to_map(wallet) == wire
    assert Jason.decode!(Jason.encode!(%{"wallet" => wallet})) == %{"wallet" => wire}
  end

  test "rejects non-object input and non-string extension keys" do
    for data <- [nil, [], "wallet", 1, %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :wallet_address}]}} =
               WalletAddress.from_map(data)
    end

    for extension <- [%{custom: "value"}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               WalletAddress.from_map(Map.merge(@wallet, extension))
    end
  end

  test "validates manually modified structs and reserved extension fields" do
    {:ok, wallet} = WalletAddress.from_map(@wallet)

    assert {:error, %Error{validation_errors: [%{field: :resource_server}]}} =
             WalletAddress.validate(%{wallet | resource_server: "relative"})

    assert {:error, %Error{validation_errors: [%{field: :public_name}]}} =
             WalletAddress.validate(%{wallet | public_name: 123})

    for extensions <- [nil, [], %URI{}, %{"publicName" => "spoofed"}, %{"id" => "spoofed"}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               WalletAddress.validate(%{wallet | extensions: extensions})
    end

    assert WalletAddress.to_map(%{
             wallet
             | extensions: %{"id" => "spoofed", "publicName" => "spoofed"}
           }) ==
             @wallet
  end
end
