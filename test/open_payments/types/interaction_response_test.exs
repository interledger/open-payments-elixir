defmodule OpenPayments.Types.InteractionResponseTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.InteractionResponse

  @interaction %{
    "redirect" => "https://auth.example.com/tenant/consent/opaque-id",
    "finish" => "test-server-finish"
  }

  test "matches the pinned interaction response contract without inferred finish restrictions" do
    {:ok, schema} = Specification.fetch_schema(:auth, "interact-response")
    assert schema["type"] == "object"
    assert schema["required"] == ~w(redirect finish)
    assert schema["properties"]["redirect"]["format"] == "uri"
    assert schema["properties"]["finish"]["type"] == "string"
    refute Map.has_key?(schema["properties"]["finish"], "format")
    refute Map.has_key?(schema["properties"]["finish"], "pattern")
    refute Map.has_key?(schema["properties"]["finish"], "minLength")
    assert Map.get(schema, "additionalProperties", true) == true
  end

  test "round trips interaction instructions from official pending grant examples" do
    examples =
      Specification.document(:auth)["paths"]["/"]["post"]["responses"]["200"]["content"][
        "application/json"
      ]["examples"]

    interactions =
      for {_name, example} <- examples,
          interaction = example["value"]["interact"],
          not is_nil(interaction),
          do: interaction

    assert interactions != []

    for wire <- interactions do
      assert {:ok, %InteractionResponse{} = interaction} = InteractionResponse.from_map(wire)
      assert :ok = InteractionResponse.validate(interaction)
      assert InteractionResponse.to_map(interaction) == wire
      assert Jason.decode!(Jason.encode!(interaction)) == wire
    end
  end

  test "requires URI and string fields and rejects missing, null and wrong types without coercion" do
    for {wire_field, field} <- [{"redirect", :redirect}, {"finish", :finish}],
        wire <- [
          Map.delete(@interaction, wire_field),
          Map.put(@interaction, wire_field, nil),
          Map.put(@interaction, wire_field, 1),
          Map.put(@interaction, wire_field, false),
          Map.put(@interaction, wire_field, ["private-input"]),
          Map.put(@interaction, wire_field, <<255>>)
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]} = error} =
               InteractionResponse.from_map(wire)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end
  end

  test "preserves absolute redirect spelling without applying outgoing request URL policy" do
    for redirect <- [
          "https://Auth.Example.COM:8443/tenant/consent%2Fid?state=1#step",
          "http://localhost:3006/consent/id",
          "example-app://consent/id"
        ] do
      wire = %{@interaction | "redirect" => redirect}
      assert {:ok, interaction} = InteractionResponse.from_map(wire)
      assert InteractionResponse.to_map(interaction) == wire
    end

    for redirect <- [
          "",
          "/consent/id",
          "$auth.example.com",
          "https://",
          "https://auth.example.com/%xx"
        ] do
      assert {:error, %Error{validation_errors: [%{field: :redirect}]}} =
               InteractionResponse.from_map(%{@interaction | "redirect" => redirect})
    end
  end

  test "preserves finish strings without assuming UUID, header or entropy constraints" do
    for finish <- ["", "opaque server finish/value", "Café 🌍"] do
      wire = %{@interaction | "finish" => finish}
      assert {:ok, interaction} = InteractionResponse.from_map(wire)
      assert Jason.decode!(Jason.encode!(interaction)) == wire
    end
  end

  test "preserves JSON extensions and rejects malformed extension data on decoding" do
    wire = Map.put(@interaction, "custom", %{"steps" => [nil, true, 1]})
    assert {:ok, interaction} = InteractionResponse.from_map(wire)
    assert interaction.extensions == Map.take(wire, ["custom"])
    assert Jason.decode!(Jason.encode!(interaction)) == wire

    for extra <- [%{custom: true}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               InteractionResponse.from_map(Map.merge(@interaction, extra))
    end
  end

  test "revalidates manual structs and protects reserved protocol fields during export" do
    {:ok, interaction} = InteractionResponse.from_map(@interaction)

    assert {:error, %Error{validation_errors: issues}} =
             InteractionResponse.validate(%{interaction | redirect: "relative", finish: nil})

    assert Enum.map(issues, & &1.field) == [:redirect, :finish]

    for extensions <- [
          %{"redirect" => "override"},
          %{"finish" => "override"},
          %{custom: true},
          %{"custom" => self()}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               InteractionResponse.validate(%{interaction | extensions: extensions})
    end

    assert InteractionResponse.to_map(%{
             interaction
             | extensions: %{"redirect" => "override", "finish" => "override"}
           }) == @interaction
  end

  test "rejects non-objects and hides redirect, finish and extensions in inspection and errors" do
    for value <- [nil, [], true, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :interaction_response}]} = error} =
               InteractionResponse.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    wire = %{
      "redirect" => "https://private-auth.example.com/private-id",
      "finish" => "private-server-finish",
      "custom" => "private-extension"
    }

    {:ok, interaction} = InteractionResponse.from_map(wire)
    refute inspect(interaction) =~ "private-"
    assert InteractionResponse.to_map(interaction) == wire
    assert Jason.decode!(Jason.encode!(interaction)) == wire
  end
end
