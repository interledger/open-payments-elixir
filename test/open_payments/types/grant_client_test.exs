defmodule OpenPayments.Types.GrantClientTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{ClientDisplay, GrantClient, JWK}

  @wallet "https://wallet.example.com/alice"
  @jwk %{
    "kid" => "key-1",
    "alg" => "EdDSA",
    "kty" => "OKP",
    "crv" => "Ed25519",
    "x" => "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
  }
  @display %{"name" => "Example client", "logo_uri" => "data:image/png;base64,aW1hZ2U="}

  test "matches the three pinned identity alternatives and strict object contracts" do
    {:ok, schema} = Specification.fetch_schema(:auth, "client")

    assert schema["oneOf"] == [
             %{"$ref" => "#/components/schemas/client-wallet-address"},
             %{"$ref" => "#/components/schemas/client-directed-identity"},
             %{"$ref" => "#/components/schemas/client-wallet-address-string"}
           ]

    {:ok, legacy} = Specification.fetch_schema(:auth, "client-wallet-address-string")
    assert legacy["type"] == "string"
    assert legacy["format"] == "uri"
    assert legacy["deprecated"] == true

    for {name, field} <- [
          {"client-wallet-address", "walletAddress"},
          {"client-directed-identity", "jwk"}
        ] do
      {:ok, object} = Specification.fetch_schema(:auth, name)
      assert object["required"] == [field]
      assert object["additionalProperties"] == false
      assert Enum.sort(Map.keys(object["properties"])) == Enum.sort([field, "display"])
      assert object["properties"]["display"] == %{"$ref" => "#/components/schemas/client-display"}
    end
  end

  test "round trips identities in every pinned grant request example" do
    examples =
      Specification.document(:auth)["paths"]["/"]["post"]["requestBody"]["content"][
        "application/json"
      ]["examples"]

    for {_name, example} <- examples do
      wire = example["value"]["client"]
      assert {:ok, %GrantClient{} = client} = GrantClient.from_value(wire)
      assert :ok = GrantClient.validate(client)
      assert GrantClient.to_value(client) == wire
      assert Jason.decode!(Jason.encode!(client)) == wire
    end
  end

  test "preserves string identities and URI spelling without resolving pointers" do
    for wallet <- [
          @wallet,
          "http://localhost:3000/accounts/alice",
          "https://Wallet.Example.COM:8443/a%2fb?x=1#part"
        ] do
      assert {:ok, %GrantClient{kind: :wallet_string} = client} = GrantClient.from_value(wallet)
      assert client.wallet_address == wallet
      assert client.display == nil
      assert client.jwk == nil
      assert GrantClient.to_value(client) == wallet
      assert Jason.decode!(Jason.encode!(client)) == wallet
    end

    for invalid <- ["", "relative/alice", "$wallet.example.com/alice", <<255>>] do
      assert {:error, %Error{validation_errors: [%{field: :wallet_address}]}} =
               GrantClient.from_value(invalid)
    end
  end

  test "decodes both object forms with optional typed display and public JWK metadata" do
    for wire <- [
          %{"walletAddress" => @wallet},
          %{"walletAddress" => @wallet, "display" => @display},
          %{"walletAddress" => @wallet, "display" => %{}},
          %{"jwk" => @jwk},
          %{"jwk" => Map.put(@jwk, "custom", %{"value" => true}), "display" => @display}
        ] do
      assert {:ok, client} = GrantClient.from_value(wire)

      assert client.kind ==
               if(Map.has_key?(wire, "jwk"), do: :directed_identity, else: :wallet_address)

      if Map.has_key?(wire, "jwk"), do: assert(%JWK{} = client.jwk)
      if Map.has_key?(wire, "display"), do: assert(%ClientDisplay{} = client.display)
      assert :ok = GrantClient.validate(client)
      assert GrantClient.to_value(client) == wire
      assert Jason.decode!(Jason.encode!(client)) == wire
    end
  end

  test "rejects missing, null and mutually exclusive identities without guessing a variant" do
    for wire <- [
          %{},
          %{"display" => @display},
          %{"walletAddress" => @wallet, "jwk" => @jwk},
          %{"walletAddress" => @wallet, "jwk" => nil}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :client}]}} =
               GrantClient.from_value(wire)
    end

    for {field, expected} <- [{"walletAddress", :wallet_address}, {"jwk", :jwk}],
        value <- [nil, false, 1, []] do
      assert {:error, %Error{validation_errors: [%{field: ^expected}]}} =
               GrantClient.from_value(%{field => value})
    end
  end

  test "reports nested JWK failures safely and rejects private keys" do
    for {key, field} <- [
          {Map.delete(@jwk, "kid"), "jwk.kid"},
          {Map.put(@jwk, "x", "private-invalid-value="), "jwk.x"},
          {Map.put(@jwk, "d", "private-seed-must-not-leak"), "jwk.d"}
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]} = error} =
               GrantClient.from_value(%{"jwk" => key})

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "distinguishes omitted display from null and prefixes nested display issues" do
    for identity <- [%{"walletAddress" => @wallet}, %{"jwk" => @jwk}],
        {display, field} <- [
          {nil, :display},
          {[], :display},
          {%{"uri" => "/relative"}, "display.uri"},
          {%{"name" => nil}, "display.name"},
          {%{"extra" => true}, :display}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               GrantClient.from_value(Map.put(identity, "display", display))
    end
  end

  test "rejects non-values and additional top-level fields including naming aliases" do
    for value <- [nil, true, 1, [], %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :client}]}} =
               GrantClient.from_value(value)
    end

    for identity <- [%{"walletAddress" => @wallet}, %{"jwk" => @jwk}],
        extra <- [
          %{"extra" => "private-extra"},
          %{"wallet_address" => @wallet},
          %{display: @display}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :client}]} = error} =
               GrantClient.from_value(Map.merge(identity, extra))

      refute inspect(Map.from_struct(error)) =~ "private-extra"
    end
  end

  test "validates manually constructed forms and rejects inactive fields" do
    {:ok, wallet} = GrantClient.from_value(%{"walletAddress" => @wallet})
    {:ok, directed} = GrantClient.from_value(%{"jwk" => @jwk})
    {:ok, legacy} = GrantClient.from_value(@wallet)

    for {client, field} <- [
          {%{wallet | kind: :unknown}, :kind},
          {%{wallet | jwk: directed.jwk}, :jwk},
          {%{directed | wallet_address: @wallet}, :wallet_address},
          {%{directed | jwk: @jwk}, :jwk},
          {%{legacy | jwk: directed.jwk}, :jwk},
          {%{legacy | display: %ClientDisplay{}}, :display},
          {%{wallet | display: @display}, :display}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               GrantClient.validate(client)
    end
  end

  test "revalidates mutated nested types and permits omitting display in object forms" do
    {:ok, client} = GrantClient.from_value(%{"jwk" => @jwk, "display" => @display})
    assert :ok = GrantClient.validate(%{client | display: nil})
    assert GrantClient.to_value(%{client | display: nil}) == %{"jwk" => @jwk}

    changed = %{
      client
      | jwk: %{client.jwk | use: "enc"},
        display: %{client.display | logo_uri: "/relative"}
    }

    assert {:error, %Error{validation_errors: issues}} = GrantClient.validate(changed)
    assert Enum.map(issues, & &1.field) == ["jwk.use", "display.logo_uri"]
  end

  test "inspection omits nested data and JWK export strips manually inserted private material" do
    wire = %{
      "jwk" => Map.put(@jwk, "custom", "private-key-metadata"),
      "display" => %{"name" => "private-display"}
    }

    {:ok, client} = GrantClient.from_value(wire)
    refute inspect(client) =~ "private-"

    changed = %{client | jwk: %{client.jwk | extensions: %{"d" => "private-seed-must-not-leak"}}}
    assert {:error, %Error{validation_errors: issues} = error} = GrantClient.validate(changed)
    assert Enum.any?(issues, &(&1.field == "jwk.d"))
    refute inspect(Map.from_struct(error)) =~ "private-seed"
    refute Map.has_key?(GrantClient.to_value(changed)["jwk"], "d")
    refute Jason.encode!(changed) =~ "private-seed"
  end
end
