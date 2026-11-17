defmodule OpenPayments.Types.GrantRequestTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}

  alias OpenPayments.Types.{
    AccessOutgoing,
    AccessQuote,
    AccessTokenRequest,
    GrantClient,
    GrantRequest,
    InteractionRequest,
    Subject
  }

  @client %{
    "walletAddress" => "https://wallet.example.com/alice",
    "display" => %{"name" => "Example client"}
  }
  @token %{"access" => [%{"type" => "quote", "actions" => ["create"]}]}
  @subject %{"sub_ids" => [%{"id" => "https://wallet.example.com/alice", "format" => "uri"}]}
  @interact %{
    "start" => ["redirect"],
    "finish" => %{
      "method" => "redirect",
      "uri" => "https://client.example.com/callback",
      "nonce" => "private-nonce"
    }
  }
  @grant %{"client" => @client, "access_token" => @token}
  @jwk %{
    "kid" => "key-1",
    "alg" => "EdDSA",
    "kty" => "OKP",
    "crv" => "Ed25519",
    "x" => "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
  }

  test "matches the pinned anyOf variants and their distinct required fields" do
    {:ok, schema} = Specification.fetch_schema(:auth, "grant-request")

    assert schema["anyOf"] ==
             Enum.map(
               ~w(grant-request-with-access-token grant-request-with-subject),
               &%{"$ref" => "#/components/schemas/#{&1}"}
             )

    for {name, required} <- [
          {"grant-request-with-access-token", ~w(client access_token)},
          {"grant-request-with-subject", ~w(client interact subject)}
        ] do
      {:ok, branch} = Specification.fetch_schema(:auth, name)
      assert branch["required"] == required
      assert branch["properties"]["client"] == %{"$ref" => "#/components/schemas/client"}

      assert branch["properties"]["interact"] == %{
               "$ref" => "#/components/schemas/interact-request"
             }

      assert branch["properties"]["subject"] == %{"$ref" => "#/components/schemas/subject"}
      assert Map.get(branch, "additionalProperties", true) == true
    end
  end

  test "round trips every official grant example with nested typed values" do
    examples =
      Specification.document(:auth)["paths"]["/"]["post"]["requestBody"]["content"][
        "application/json"
      ]["examples"]

    assert map_size(examples) > 0

    for {_name, example} <- examples do
      wire = example["value"]
      assert {:ok, %GrantRequest{client: %GrantClient{}} = request} = GrantRequest.from_map(wire)

      if Map.has_key?(wire, "access_token"),
        do: assert(%AccessTokenRequest{} = request.access_token)

      if Map.has_key?(wire, "interact"), do: assert(%InteractionRequest{} = request.interact)
      if Map.has_key?(wire, "subject"), do: assert(%Subject{} = request.subject)
      assert :ok = GrantRequest.validate(request)
      assert GrantRequest.to_map(request) == wire
      assert Jason.decode!(Jason.encode!(request)) == wire
    end
  end

  test "permits access-only, subject-with-interaction and combined request branches" do
    for wire <- [
          @grant,
          %{@grant | "access_token" => %{"access" => []}},
          %{"client" => @client, "subject" => @subject, "interact" => @interact},
          Map.put(@grant, "subject", @subject),
          Map.merge(@grant, %{"subject" => @subject, "interact" => @interact})
        ] do
      assert {:ok, request} = GrantRequest.from_map(wire)
      assert GrantRequest.to_map(request) == wire
    end
  end

  test "rejects requests without a purpose or subject-only requests without interaction" do
    for wire <- [
          %{"client" => @client},
          %{"client" => @client, "interact" => @interact},
          %{"client" => @client, "accessToken" => @token}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :grant_request}]}} =
               GrantRequest.from_map(wire)
    end

    assert {:error, %Error{validation_errors: [%{field: :interact}]}} =
             GrantRequest.from_map(%{"client" => @client, "subject" => @subject})
  end

  test "requires a valid client identity without interpreting signing-client configuration" do
    for wire <- [
          Map.delete(@grant, "client"),
          Map.put(@grant, "client", nil),
          Map.put(@grant, "client", []),
          Map.put(@grant, "client", %{})
        ] do
      assert {:error, %Error{validation_errors: [%{field: :client}]}} =
               GrantRequest.from_map(wire)
    end

    assert {:ok, request} =
             GrantRequest.from_map(%{@grant | "client" => "https://Wallet.Example.COM/alice"})

    assert GrantRequest.to_map(request)["client"] == "https://Wallet.Example.COM/alice"
  end

  test "rejects explicit nulls for each optional typed field" do
    for {wire_field, field} <- [
          {"access_token", :access_token},
          {"interact", :interact},
          {"subject", :subject}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               GrantRequest.from_map(Map.put(@grant, wire_field, nil))
    end

    {:ok, request} = GrantRequest.from_map(@grant)
    assert request.subject == nil
    assert request.interact == nil
    refute Map.has_key?(GrantRequest.to_map(request), "subject")
    refute Map.has_key?(GrantRequest.to_map(request), "interact")
  end

  test "permits non-interactive directed identity and rejects an explicit interaction field" do
    wire = %{@grant | "client" => %{"jwk" => @jwk}}
    assert {:ok, request} = GrantRequest.from_map(wire)
    assert request.client.kind == :directed_identity

    for interact <- [@interact, %{"start" => []}] do
      assert {:error, %Error{validation_errors: [%{field: :interact}]}} =
               GrantRequest.from_map(Map.put(wire, "interact", interact))
    end

    {:ok, interact} = InteractionRequest.from_map(@interact)

    assert {:error, %Error{validation_errors: [%{field: :interact}]}} =
             GrantRequest.validate(%{request | interact: interact})
  end

  test "prefixes nested errors at each composed request boundary" do
    for {wire, field} <- [
          {%{
             @grant
             | "client" => %{
                 "walletAddress" => "https://wallet.example.com/alice",
                 "display" => %{"logo_uri" => "relative"}
               }
           }, "client.display.logo_uri"},
          {Map.put(@grant, "access_token", %{}), "access_token.access"},
          {Map.put(@grant, "access_token", %{
             "access" => [@token["access"] |> hd(), @token["access"] |> hd()]
           }), "access_token.access"},
          {Map.put(@grant, "interact", %{
             "start" => ["redirect"],
             "finish" => Map.put(@interact["finish"], "nonce", ["private-nonce"])
           }), "interact.finish.nonce"},
          {Map.put(@grant, "subject", %{
             "sub_ids" => [%{"id" => "private-subject", "format" => "email"}]
           }), "subject.sub_ids[0].format"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               GrantRequest.from_map(wire)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "validates limits on every outgoing access entry and preserves deep card error paths" do
    amount = %{"value" => "500", "assetCode" => "USD", "assetScale" => 2}

    outgoing = %{
      "type" => "outgoing-payment",
      "actions" => ["create"],
      "identifier" => "https://wallet.example.com/alice"
    }

    invalid = Map.put(outgoing, "limits", %{"debitAmount" => amount, "receiveAmount" => amount})
    wire = Map.put(@grant, "access_token", %{"access" => [outgoing, invalid]})

    assert {:error, %Error{validation_errors: [%{field: "access_token.access[1].limits"}]}} =
             GrantRequest.from_map(wire)

    card = %{
      "tlvData" => "private-card",
      "requestId" => "test-id",
      "pwk" => %{"key" => ["private-key"], "kvc" => "test-kvc", "iv" => "test-iv"}
    }

    wire =
      Map.put(@grant, "access_token", %{
        "access" => [Map.put(outgoing, "cardAuthorization", card)]
      })

    assert {:error,
            %Error{
              validation_errors: [%{field: "access_token.access[0].card_authorization.pwk.key"}]
            } = error} = GrantRequest.from_map(wire)

    refute inspect(Map.from_struct(error)) =~ "private-"
  end

  test "preserves root and token-request extensions and exact protocol names" do
    wire =
      @grant
      |> Map.put("custom-root", [true, nil])
      |> Map.put("access_token", Map.put(@token, "custom-token", %{"value" => 1}))

    assert {:ok, request} = GrantRequest.from_map(wire)
    assert request.extensions == %{"custom-root" => [true, nil]}
    assert request.access_token.extensions == %{"custom-token" => %{"value" => 1}}
    assert Jason.decode!(Jason.encode!(request)) == wire
    refute Map.has_key?(GrantRequest.to_map(request), "accessToken")
  end

  test "requires typed children in manually constructed request structs" do
    {:ok, request} =
      GrantRequest.from_map(Map.merge(@grant, %{"interact" => @interact, "subject" => @subject}))

    for {changed, field} <- [
          {%{request | client: @client}, :client},
          {%{request | access_token: @token}, :access_token},
          {%{request | interact: @interact}, :interact},
          {%{request | subject: @subject}, :subject}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               GrantRequest.validate(changed)
    end

    assert :ok = GrantRequest.validate(%{request | access_token: nil})
  end

  test "revalidates all nested typed models and reports independent field errors" do
    {:ok, request} =
      GrantRequest.from_map(Map.merge(@grant, %{"interact" => @interact, "subject" => @subject}))

    changed = %{
      request
      | client: %{request.client | wallet_address: nil},
        access_token: %{
          request.access_token
          | access: [%AccessQuote{type: "quote", actions: ["complete"]}]
        },
        interact: %{request.interact | start: ["push"]},
        subject: %{request.subject | sub_ids: []}
    }

    assert {:error, %Error{validation_errors: issues}} = GrantRequest.validate(changed)

    assert Enum.map(issues, & &1.field) == [
             "client.wallet_address",
             "access_token.access[0].actions",
             "interact.start",
             "subject.sub_ids"
           ]
  end

  test "validates extension JSON and prevents reserved payload overrides during export" do
    {:ok, request} = GrantRequest.from_map(@grant)

    for extensions <- [%{"client" => "override"}, %{custom: true}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               GrantRequest.validate(%{request | extensions: extensions})
    end

    assert GrantRequest.to_map(%{
             request
             | extensions: %{"client" => "override", "subject" => "injected"}
           }) == @grant
  end

  test "rejects non-objects and hides sensitive nested payloads in inspection and errors" do
    for value <- [nil, [], false, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :grant_request}]} = error} =
               GrantRequest.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    outgoing = %{
      "type" => "outgoing-payment",
      "actions" => ["create"],
      "identifier" => "https://wallet.example.com/alice",
      "cardAuthorization" => %{"tlvData" => "private-card", "requestId" => "private-request-id"}
    }

    wire =
      Map.merge(@grant, %{
        "access_token" => %{"access" => [outgoing]},
        "interact" => @interact,
        "subject" => @subject,
        "custom" => "private-extension"
      })

    {:ok, request} = GrantRequest.from_map(wire)
    assert [%AccessOutgoing{}] = request.access_token.access
    refute inspect(request) =~ "private-"
    assert Jason.decode!(Jason.encode!(request)) == wire
  end
end
