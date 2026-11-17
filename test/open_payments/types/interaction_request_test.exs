defmodule OpenPayments.Types.InteractionRequestTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{InteractionFinish, InteractionRequest}

  @finish %{
    "method" => "redirect",
    "uri" => "https://client.example.com/callback",
    "nonce" => "test-client-nonce"
  }
  @request %{"start" => ["redirect"], "finish" => @finish}

  test "matches the pinned start/finish schema and grant-request references" do
    {:ok, schema} = Specification.fetch_schema(:auth, "interact-request")
    assert schema["type"] == "object"
    assert schema["required"] == ["start"]
    assert schema["properties"]["start"]["items"] == %{"type" => "string", "enum" => ["redirect"]}
    refute Map.has_key?(schema["properties"]["start"], "minItems")
    refute Map.has_key?(schema["properties"]["start"], "uniqueItems")
    assert Map.get(schema, "additionalProperties", true) == true

    for name <- ~w(grant-request-with-access-token grant-request-with-subject) do
      {:ok, grant} = Specification.fetch_schema(:auth, name)

      assert grant["properties"]["interact"] == %{
               "$ref" => "#/components/schemas/interact-request"
             }
    end
  end

  test "decodes typed finish callbacks and round trips official grant interactions" do
    examples =
      Specification.document(:auth)["paths"]["/"]["post"]["requestBody"]["content"][
        "application/json"
      ]["examples"]

    interactions =
      for {_name, example} <- examples,
          interact = get_in(example, ["value", "interact"]),
          not is_nil(interact),
          do: interact

    assert interactions != []

    for wire <- interactions do
      assert {:ok, %InteractionRequest{finish: %InteractionFinish{}} = interaction} =
               InteractionRequest.from_map(wire)

      assert :ok = InteractionRequest.validate(interaction)
      assert InteractionRequest.to_map(interaction) == wire
      assert Jason.decode!(Jason.encode!(interaction)) == wire
    end
  end

  test "requires a redirect-only start array without adding cardinality or uniqueness constraints" do
    for start <- [[], ["redirect"], ["redirect", "redirect"]] do
      assert {:ok, interaction} = InteractionRequest.from_map(%{"start" => start})
      assert InteractionRequest.to_map(interaction) == %{"start" => start}
    end

    for data <- [
          %{},
          %{"start" => nil},
          %{"start" => "redirect"},
          %{"start" => %{}},
          %{"start" => ["push"]},
          %{"start" => [:redirect]},
          %{"start" => ["redirect", nil]}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :start}]}} =
               InteractionRequest.from_map(data)
    end
  end

  test "distinguishes omitted finish from explicit null and rejects non-object input" do
    assert {:ok, %InteractionRequest{finish: nil} = interaction} =
             InteractionRequest.from_map(%{"start" => ["redirect"]})

    refute Map.has_key?(InteractionRequest.to_map(interaction), "finish")

    for finish <- [nil, false, [], "callback"] do
      assert {:error, %Error{validation_errors: [%{field: :finish}]}} =
               InteractionRequest.from_map(%{@request | "finish" => finish})
    end

    for value <- [nil, [], false, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :interaction_request}]} = error} =
               InteractionRequest.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end
  end

  test "prefixes callback errors without retaining rejected values" do
    for {finish, field} <- [
          {Map.delete(@finish, "nonce"), "finish.nonce"},
          {Map.put(@finish, "method", "push"), "finish.method"},
          {Map.put(@finish, "uri", "/relative"), "finish.uri"},
          {Map.put(@finish, "nonce", ["private-nonce"]), "finish.nonce"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               InteractionRequest.from_map(%{@request | "finish" => finish})

      refute inspect(Map.from_struct(error)) =~ "private-nonce"
    end
  end

  test "preserves additional JSON fields at both levels and URI spelling" do
    finish =
      Map.merge(@finish, %{
        "uri" => "http://localhost:4000/return?state=x#done",
        "custom-finish" => %{"value" => nil}
      })

    wire = Map.merge(@request, %{"finish" => finish, "custom-request" => [true, 1, "value"]})
    assert {:ok, interaction} = InteractionRequest.from_map(wire)
    assert interaction.extensions == %{"custom-request" => [true, 1, "value"]}
    assert interaction.finish.extensions == %{"custom-finish" => %{"value" => nil}}
    assert InteractionRequest.to_map(interaction) == wire
    assert Jason.decode!(Jason.encode!(interaction)) == wire
  end

  test "revalidates manually modified nested structs and extension fields" do
    {:ok, interaction} = InteractionRequest.from_map(@request)

    for {changed, field} <- [
          {%{interaction | start: ["push"]}, :start},
          {%{interaction | finish: @finish}, :finish},
          {%{interaction | finish: %{interaction.finish | nonce: nil}}, "finish.nonce"},
          {%{interaction | extensions: %{"finish" => "override"}}, :extensions},
          {%{interaction | extensions: %{custom: true}}, :extensions},
          {%{interaction | extensions: %{"custom" => self()}}, :extensions},
          {%{interaction | finish: %{interaction.finish | extensions: %{"nonce" => "override"}}},
           "finish.extensions"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               InteractionRequest.validate(changed)
    end

    assert :ok = InteractionRequest.validate(%{interaction | finish: nil})

    assert InteractionRequest.to_map(%{interaction | extensions: %{"start" => ["push"]}})["start"] ==
             ["redirect"]
  end

  test "inspection hides callback nonces and extensions while explicit encoding retains them" do
    {:ok, interaction} =
      InteractionRequest.from_map(Map.put(@request, "custom", "private-extension"))

    refute inspect(interaction) =~ "test-client-nonce"
    refute inspect(interaction) =~ "private-extension"
    assert InteractionRequest.to_map(interaction)["finish"]["nonce"] == @finish["nonce"]
    assert Jason.decode!(Jason.encode!(interaction))["finish"]["nonce"] == @finish["nonce"]
  end
end
