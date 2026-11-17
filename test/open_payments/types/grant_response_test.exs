defmodule OpenPayments.Types.GrantResponseTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}

  alias OpenPayments.Types.{
    AccessToken,
    Continuation,
    GrantResponse,
    InteractionResponse,
    Subject
  }

  @continuation %{
    "access_token" => %{"value" => "test-continuation-token"},
    "uri" => "https://auth.example.com/tenant/continue/id"
  }
  @interaction %{
    "redirect" => "https://auth.example.com/tenant/consent/id",
    "finish" => "test-finish"
  }
  @token %{
    "value" => "test-resource-token",
    "manage" => "https://auth.example.com/token/id",
    "access" => []
  }
  @subject %{"sub_ids" => [%{"id" => "opaque-subject", "format" => "uri"}]}
  @pending %{"continue" => @continuation, "interact" => @interaction}
  @approved %{"continue" => @continuation, "access_token" => @token}

  test "matches the initial oneOf branches and distinguishes the continuation response contract" do
    document = Specification.document(:auth)

    schema =
      document["paths"]["/"]["post"]["responses"]["200"]["content"]["application/json"]["schema"]

    assert schema["type"] == "object"

    assert Enum.map(schema["oneOf"], & &1["required"]) == [
             ~w(interact continue),
             ~w(access_token continue)
           ]

    [pending, approved] = schema["oneOf"]
    assert pending["properties"]["interact"]["$ref"] == "#/components/schemas/interact-response"
    assert approved["properties"]["access_token"]["$ref"] == "#/components/schemas/access_token"

    for branch <- schema["oneOf"] do
      assert branch["properties"]["continue"]["$ref"] == "#/components/schemas/continue"
      assert Map.get(branch, "additionalProperties", true) == true
      refute Map.has_key?(branch["properties"], "subject")
    end

    continued =
      document["paths"]["/continue/{id}"]["post"]["responses"]["200"]["content"][
        "application/json"
      ]["schema"]

    assert continued["required"] == ["continue"]
    assert continued["properties"]["subject"]["$ref"] == "#/components/schemas/subject"
  end

  test "round trips every official initial grant example with typed nested data and predicates" do
    examples =
      Specification.document(:auth)["paths"]["/"]["post"]["responses"]["200"]["content"][
        "application/json"
      ]["examples"]

    assert map_size(examples) > 0

    for {_name, %{"value" => wire}} <- examples do
      assert {:ok, %GrantResponse{continue: %Continuation{}} = response} =
               GrantResponse.from_map(wire)

      assert :ok = GrantResponse.validate(response)
      assert GrantResponse.to_map(response) == wire
      assert Jason.decode!(Jason.encode!(response)) == wire
      assert GrantResponse.pending?(response) == Map.has_key?(wire, "interact")
      assert GrantResponse.approved?(response) == Map.has_key?(wire, "access_token")

      if Map.has_key?(wire, "interact"),
        do: assert(%InteractionResponse{} = response.interact),
        else: assert(%AccessToken{} = response.access_token)
    end
  end

  test "requires a continuation object and safely prefixes nested credential errors" do
    for {wire, field} <- [
          {Map.delete(@pending, "continue"), :continue},
          {Map.put(@pending, "continue", nil), :continue},
          {Map.put(@pending, "continue", []), :continue},
          {put_in(@pending, ["continue", "access_token", "value"], ["private-token"]),
           "continue.access_token.value"},
          {put_in(@pending, ["continue", "uri"], "private-relative-uri"), "continue.uri"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               GrantResponse.from_map(wire)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "requires exactly one initial branch and rejects ambiguous or continuation-only results" do
    for wire <- [
          %{"continue" => @continuation},
          %{"continue" => @continuation, "subject" => @subject},
          Map.put(@pending, "access_token", @token)
        ] do
      assert {:error, %Error{validation_errors: [%{field: :grant_response}]}} =
               GrantResponse.from_map(wire)
    end
  end

  test "validates all recognized fields even when another branch is valid" do
    for {wire, field} <- [
          {Map.put(@pending, "access_token", nil), :access_token},
          {Map.put(@approved, "interact", nil), :interact},
          {Map.put(@approved, "subject", nil), :subject},
          {Map.put(@pending, "interact", 1), :interact},
          {Map.put(@approved, "access_token", "private-token"), :access_token},
          {put_in(@pending, ["interact", "finish"], ["private-finish"]), "interact.finish"},
          {put_in(@approved, ["access_token", "value"], ["private-token"]), "access_token.value"},
          {put_in(@approved, ["access_token", "manage"], "private-relative"),
           "access_token.manage"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               GrantResponse.from_map(wire)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "preserves accompanying typed subject data without allowing it to replace an initial branch" do
    for base <- [@pending, @approved] do
      wire = Map.put(base, "subject", @subject)
      assert {:ok, %GrantResponse{subject: %Subject{}} = response} = GrantResponse.from_map(wire)
      assert :ok = GrantResponse.validate(response)
      assert Jason.decode!(Jason.encode!(response)) == wire
    end

    assert {:error, %Error{validation_errors: [%{field: "subject.sub_ids[0].format"}]}} =
             GrantResponse.from_map(
               Map.put(@approved, "subject", %{
                 "sub_ids" => [%{"id" => "private-id", "format" => "invalid"}]
               })
             )
  end

  test "preserves extension data at root and nested interaction/continuation levels" do
    wire =
      @pending
      |> Map.put("custom", [nil, true, %{"revision" => 1}])
      |> put_in(["interact", "custom"], "interaction metadata")
      |> put_in(["continue", "custom"], "continuation metadata")
      |> put_in(["continue", "access_token", "custom"], "credential metadata")

    assert {:ok, response} = GrantResponse.from_map(wire)
    assert response.extensions == Map.take(wire, ["custom"])
    assert Jason.decode!(Jason.encode!(response)) == wire

    for extra <- [%{custom: true}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               GrantResponse.from_map(Map.merge(@pending, extra))
    end
  end

  test "retains full nested access and card payload error paths" do
    wire =
      put_in(@approved, ["access_token", "access"], [
        %{
          "type" => "outgoing-payment",
          "actions" => ["create"],
          "identifier" => "https://wallet.example.com/alice",
          "cardAuthorization" => %{
            "tlvData" => "test-tlv",
            "requestId" => "test-id",
            "pwk" => %{"key" => ["private-key"], "kvc" => "test-kvc", "iv" => "test-iv"}
          }
        }
      ])

    assert {:error,
            %Error{
              validation_errors: [%{field: "access_token.access[0].card_authorization.pwk.key"}]
            } = error} =
             GrantResponse.from_map(wire)

    refute inspect(Map.from_struct(error)) =~ "private-key"
  end

  test "revalidates every typed child and nested values after manual changes" do
    {:ok, pending} = GrantResponse.from_map(Map.put(@pending, "subject", @subject))
    {:ok, approved} = GrantResponse.from_map(@approved)

    for {response, field} <- [
          {%{pending | continue: %{}}, :continue},
          {%{pending | continue: %{pending.continue | uri: "relative"}}, "continue.uri"},
          {%{pending | interact: @interaction}, :interact},
          {%{pending | interact: %{pending.interact | finish: nil}}, "interact.finish"},
          {%{approved | access_token: @token}, :access_token},
          {%{approved | access_token: %{approved.access_token | value: nil}},
           "access_token.value"},
          {%{pending | subject: @subject}, :subject},
          {%{pending | subject: %{pending.subject | sub_ids: []}}, "subject.sub_ids"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               GrantResponse.validate(response)
    end

    assert :ok = GrantResponse.validate(%{pending | subject: nil})
  end

  test "revalidates branch shape and documents predicates as shape checks rather than full validation" do
    {:ok, pending} = GrantResponse.from_map(@pending)
    {:ok, approved} = GrantResponse.from_map(@approved)

    for response <- [%{pending | interact: nil}, %{pending | access_token: approved.access_token}] do
      assert {:error, %Error{validation_errors: [%{field: :grant_response}]}} =
               GrantResponse.validate(response)

      refute GrantResponse.pending?(response)
      refute GrantResponse.approved?(response)
    end

    changed = %{pending | interact: %{pending.interact | finish: nil}}
    assert GrantResponse.pending?(changed)
    refute GrantResponse.approved?(changed)
    assert {:error, %Error{}} = GrantResponse.validate(changed)
    refute GrantResponse.pending?(%{pending | interact: @interaction})
    refute GrantResponse.approved?(%{approved | access_token: @token})
  end

  test "rejects reserved extension overrides and omits absent optional fields on export" do
    {:ok, response} = GrantResponse.from_map(@approved)

    for extensions <- [
          %{"continue" => "override"},
          %{"interact" => "override"},
          %{"access_token" => "override"},
          %{"subject" => "override"},
          %{custom: true},
          %{"custom" => self()}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               GrantResponse.validate(%{response | extensions: extensions})
    end

    assert GrantResponse.to_map(%{
             response
             | extensions: %{
                 "interact" => "override",
                 "subject" => "override",
                 "access_token" => "override",
                 "continue" => "override"
               }
           }) == @approved
  end

  test "rejects non-objects and keeps payload values out of inspection and errors" do
    for value <- [nil, [], true, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :grant_response}]} = error} =
               GrantResponse.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    for base <- [@pending, @approved] do
      wire = Map.put(base, "subject", @subject) |> Map.put("custom", "private-extension")
      {:ok, response} = GrantResponse.from_map(wire)

      for secret <- ["test-", "auth.example.com", "opaque-subject", "private-extension"] do
        refute inspect(response) =~ secret
      end

      assert GrantResponse.to_map(response) == wire
    end
  end
end
