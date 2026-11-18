defmodule OpenPayments.Types.GrantContinuationResponseTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}

  alias OpenPayments.Types.{
    AccessToken,
    Continuation,
    GrantContinuationResponse,
    GrantResponse,
    Subject
  }

  @continuation %{
    "access_token" => %{"value" => "test-continuation-token"},
    "uri" => "https://auth.example.com/tenant/continue/id",
    "wait" => 30
  }
  @token %{
    "value" => "test-resource-token",
    "manage" => "https://auth.example.com/token/id",
    "access" => []
  }
  @subject %{"sub_ids" => [%{"id" => "opaque-subject", "format" => "uri"}]}
  @only %{"continue" => @continuation}
  @both %{"continue" => @continuation, "access_token" => @token, "subject" => @subject}

  test "matches the pinned continuation response schema and optional result references" do
    schema =
      Specification.document(:auth)["paths"]["/continue/{id}"]["post"]["responses"]["200"][
        "content"
      ]["application/json"]["schema"]

    assert schema["type"] == "object"
    assert schema["required"] == ["continue"]
    assert schema["properties"]["continue"]["$ref"] == "#/components/schemas/continue"
    assert schema["properties"]["access_token"]["$ref"] == "#/components/schemas/access_token"
    assert schema["properties"]["subject"]["$ref"] == "#/components/schemas/subject"
    assert Map.get(schema, "additionalProperties", true) == true
    refute Map.has_key?(schema, "oneOf")
    refute Map.has_key?(schema["properties"], "interact")
  end

  test "round trips all official continuation response examples with typed data and result predicates" do
    examples =
      Specification.document(:auth)["paths"]["/continue/{id}"]["post"]["responses"]["200"][
        "content"
      ]["application/json"]["examples"]

    assert map_size(examples) > 0

    for {_name, %{"value" => wire}} <- examples do
      assert {:ok, %GrantContinuationResponse{continue: %Continuation{}} = response} =
               GrantContinuationResponse.from_map(wire)

      assert :ok = GrantContinuationResponse.validate(response)
      assert GrantContinuationResponse.to_map(response) == wire
      assert Jason.decode!(Jason.encode!(response)) == wire

      assert GrantContinuationResponse.has_access_token?(response) ==
               Map.has_key?(wire, "access_token")

      assert GrantContinuationResponse.has_subject?(response) == Map.has_key?(wire, "subject")

      assert GrantContinuationResponse.continuation_only?(response) ==
               (not Map.has_key?(wire, "access_token") and not Map.has_key?(wire, "subject"))
    end
  end

  test "accepts neither, either or both results without applying initial response branch rules" do
    for results <- [
          %{},
          %{"access_token" => @token},
          %{"subject" => @subject},
          %{"access_token" => @token, "subject" => @subject}
        ] do
      wire = Map.merge(@only, results)
      assert {:ok, response} = GrantContinuationResponse.from_map(wire)
      assert :ok = GrantContinuationResponse.validate(response)
      assert Jason.decode!(Jason.encode!(response)) == wire

      assert GrantContinuationResponse.has_access_token?(response) ==
               Map.has_key?(results, "access_token")

      assert GrantContinuationResponse.has_subject?(response) == Map.has_key?(results, "subject")
      assert GrantContinuationResponse.continuation_only?(response) == (map_size(results) == 0)
    end

    {:ok, response} = GrantContinuationResponse.from_map(@both)
    assert %AccessToken{} = response.access_token
    assert %Subject{} = response.subject

    for wire <- [@only, Map.put(@only, "subject", @subject)] do
      assert {:error, %Error{}} = GrantResponse.from_map(wire)
    end
  end

  test "requires typed continuation data and prefixes credential, URI and wait errors" do
    for {wire, field} <- [
          {Map.delete(@only, "continue"), :continue},
          {Map.put(@only, "continue", nil), :continue},
          {Map.put(@only, "continue", []), :continue},
          {put_in(@only, ["continue", "access_token", "value"], ["private-token"]),
           "continue.access_token.value"},
          {put_in(@only, ["continue", "uri"], "private-relative"), "continue.uri"},
          {put_in(@only, ["continue", "wait"], nil), "continue.wait"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               GrantContinuationResponse.from_map(wire)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "distinguishes omitted optional results from explicit null or malformed objects" do
    for {field_name, field} <- [{"access_token", :access_token}, {"subject", :subject}],
        value <- [nil, [], false, "private-input"] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               GrantContinuationResponse.from_map(Map.put(@only, field_name, value))

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    {:ok, response} = GrantContinuationResponse.from_map(@only)
    assert response.access_token == nil
    assert response.subject == nil
    assert GrantContinuationResponse.to_map(response) == @only
  end

  test "retains full nested token access and subject identifier error paths" do
    for {wire, field} <- [
          {put_in(@both, ["access_token", "value"], ["private-token"]), "access_token.value"},
          {put_in(@both, ["access_token", "access"], [
             %{"type" => "incoming-payment", "actions" => ["invalid"]}
           ]), "access_token.access[0].actions"},
          {put_in(@both, ["subject", "sub_ids"], [%{"id" => ["private-id"], "format" => "uri"}]),
           "subject.sub_ids[0].id"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               GrantContinuationResponse.from_map(wire)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "preserves JSON extensions without treating undeclared interaction data as a pending branch" do
    wire =
      @both
      |> Map.put("custom", [nil, true, %{"version" => 1}])
      |> Map.put("interact", %{"custom" => "uninterpreted interaction extension"})
      |> put_in(["subject", "custom"], "subject metadata")
      |> put_in(["subject", "sub_ids"], [
        Map.put(hd(@subject["sub_ids"]), "custom", "identifier metadata")
      ])
      |> put_in(["continue", "access_token", "custom"], "credential metadata")

    assert {:ok, response} = GrantContinuationResponse.from_map(wire)
    assert response.extensions == Map.take(wire, ["custom", "interact"])
    assert Jason.decode!(Jason.encode!(response)) == wire

    for value <- [nil, "opaque extension"] do
      assert {:ok, response} =
               GrantContinuationResponse.from_map(Map.put(@only, "interact", value))

      assert GrantContinuationResponse.continuation_only?(response)
      assert response.extensions == %{"interact" => value}
    end

    for extra <- [%{custom: true}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               GrantContinuationResponse.from_map(Map.merge(@only, extra))
    end
  end

  test "revalidates all typed children and rejects raw maps or the wrong credential role" do
    {:ok, response} = GrantContinuationResponse.from_map(@both)

    for {changed, field} <- [
          {%{response | continue: @continuation}, :continue},
          {%{response | continue: %{response.continue | access_token: response.access_token}},
           "continue.access_token"},
          {%{response | continue: %{response.continue | uri: "relative"}}, "continue.uri"},
          {%{response | access_token: @token}, :access_token},
          {%{response | access_token: response.continue.access_token}, :access_token},
          {%{response | access_token: %{response.access_token | value: nil}},
           "access_token.value"},
          {%{response | subject: @subject}, :subject},
          {%{response | subject: %{response.subject | sub_ids: []}}, "subject.sub_ids"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               GrantContinuationResponse.validate(changed)
    end

    assert :ok = GrantContinuationResponse.validate(%{response | access_token: nil, subject: nil})
  end

  test "predicates report typed result presence without validating changed payloads or lifecycle state" do
    {:ok, response} = GrantContinuationResponse.from_map(@both)

    changed = %{
      response
      | access_token: %{response.access_token | value: nil},
        subject: %{response.subject | sub_ids: []}
    }

    assert GrantContinuationResponse.has_access_token?(changed)
    assert GrantContinuationResponse.has_subject?(changed)
    refute GrantContinuationResponse.continuation_only?(changed)
    assert {:error, %Error{}} = GrantContinuationResponse.validate(changed)

    changed = %{response | access_token: @token, subject: @subject}
    refute GrantContinuationResponse.has_access_token?(changed)
    refute GrantContinuationResponse.has_subject?(changed)
    refute GrantContinuationResponse.continuation_only?(changed)
  end

  test "rejects reserved extension overrides while exports retain typed fields and omit absent results" do
    {:ok, response} = GrantContinuationResponse.from_map(@only)

    for extensions <- [
          %{"continue" => "override"},
          %{"access_token" => "override"},
          %{"subject" => "override"},
          %{custom: true},
          %{"custom" => self()}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               GrantContinuationResponse.validate(%{response | extensions: extensions})
    end

    assert GrantContinuationResponse.to_map(%{
             response
             | extensions: %{
                 "continue" => "override",
                 "access_token" => "override",
                 "subject" => "override"
               }
           }) == @only
  end

  test "rejects non-objects and hides credentials, subjects and metadata from inspection and errors" do
    for value <- [nil, [], true, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :grant_continuation_response}]} = error} =
               GrantContinuationResponse.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    wire = Map.put(@both, "custom", "private-extension")
    {:ok, response} = GrantContinuationResponse.from_map(wire)

    for secret <- ["test-", "auth.example.com", "opaque-subject", "private-extension"] do
      refute inspect(response) =~ secret
    end

    assert GrantContinuationResponse.to_map(response) == wire
    assert Jason.decode!(Jason.encode!(response)) == wire
  end
end
