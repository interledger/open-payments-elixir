defmodule OpenPayments.Types.ClientDisplayTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.ClientDisplay

  @display %{
    "name" => "Example client",
    "uri" => "https://client.example.com/",
    "logo_uri" => "https://client.example.com/logo.png"
  }

  test "matches the pinned display schema and both client identity references" do
    {:ok, schema} = Specification.fetch_schema(:auth, "client-display")
    assert schema["type"] == "object"
    assert schema["additionalProperties"] == false
    assert Map.get(schema, "required", []) == []
    assert Enum.sort(Map.keys(schema["properties"])) == ~w(logo_uri name uri)
    assert schema["properties"]["name"]["type"] == "string"

    for field <- ~w(uri logo_uri) do
      assert schema["properties"][field]["type"] == "string"
      assert schema["properties"][field]["format"] == "uri"
    end

    for identity <- ~w(client-wallet-address client-directed-identity) do
      {:ok, client} = Specification.fetch_schema(:auth, identity)
      assert client["properties"]["display"] == %{"$ref" => "#/components/schemas/client-display"}
    end
  end

  test "round trips display information from the pinned grant-request example" do
    examples =
      Specification.document(:auth)["paths"]["/"]["post"]["requestBody"]["content"][
        "application/json"
      ]["examples"]

    wire = examples["Grant request with client display information"]["value"]["client"]["display"]
    assert is_map(wire)
    assert {:ok, %ClientDisplay{} = display} = ClientDisplay.from_map(wire)
    assert display.name == wire["name"]
    assert display.uri == wire["uri"]
    assert display.logo_uri == wire["logo_uri"]
    assert :ok = ClientDisplay.validate(display)
    assert ClientDisplay.to_map(display) == wire
    assert Jason.decode!(Jason.encode!(display)) == wire
  end

  test "permits empty and partial displays and preserves protocol field names" do
    for fields <- [[], ["name"], ["uri"], ["logo_uri"], ~w(name uri logo_uri)] do
      data = Map.take(@display, fields)
      assert {:ok, display} = ClientDisplay.from_map(data)
      assert ClientDisplay.to_map(display) == data
      assert Jason.decode!(Jason.encode!(display)) == data
      assert :ok = ClientDisplay.validate(display)
      refute Map.has_key?(ClientDisplay.to_map(display), "logoUri")
    end

    assert {:ok, %ClientDisplay{name: nil, uri: nil, logo_uri: nil}} = ClientDisplay.from_map(%{})
    assert ClientDisplay.to_map(%ClientDisplay{}) == %{}
  end

  test "rejects explicit nulls and invalid types without coercing values" do
    for {wire_field, field} <- [{"name", :name}, {"uri", :uri}, {"logo_uri", :logo_uri}],
        value <- [nil, 1, false, [], %{}, <<255>>] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]}} =
               ClientDisplay.from_map(Map.put(@display, wire_field, value))
    end

    assert {:ok, %ClientDisplay{name: ""}} = ClientDisplay.from_map(%{"name" => ""})
    assert {:ok, %ClientDisplay{name: "Café 🌍"}} = ClientDisplay.from_map(%{"name" => "Café 🌍"})
  end

  test "preserves valid absolute URI schemes and spelling without imposing request policies" do
    for uri <- [
          "https://Client.Example.COM:8443/logo%2fimage?size=2#preview",
          "http://localhost:3000/logo.png",
          "data:image/png;base64,aW1hZ2U=",
          "urn:example:client"
        ] do
      for field <- ~w(uri logo_uri) do
        wire = Map.put(@display, field, uri)
        assert {:ok, display} = ClientDisplay.from_map(wire)
        assert ClientDisplay.to_map(display) == wire
      end
    end
  end

  test "rejects relative or malformed URI values without storing rejected data in errors" do
    for field <- ~w(uri logo_uri),
        uri <- [
          "",
          "/logo.png",
          "client.example.com",
          "$client.example.com",
          "https://",
          "https://client.example.com/%xx",
          "https://client.example.com/\n"
        ] do
      assert {:error, %Error{validation_errors: [%{field: error_field}]} = error} =
               ClientDisplay.from_map(Map.put(@display, field, uri))

      assert Atom.to_string(error_field) == field
      assert error.details == nil
    end

    assert {:error, error} = ClientDisplay.from_map(%{"uri" => "private-invalid-value"})
    refute inspect(Map.from_struct(error)) =~ "private-invalid-value"
  end

  test "rejects non-objects, atom keys, camelCase aliases and additional fields" do
    for data <- [nil, [], "private-display", true, 1, %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :client_display}]} = error} =
               ClientDisplay.from_map(data)

      refute inspect(Map.from_struct(error)) =~ "private-display"
    end

    for extra <- [
          %{"extra" => "private-extra"},
          %{"logoUri" => @display["logo_uri"]},
          %{name: "client"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :client_display}]} = error} =
               ClientDisplay.from_map(Map.merge(@display, extra))

      refute inspect(Map.from_struct(error)) =~ "private-extra"
    end
  end

  test "validates manual changes while treating nil optional fields as omitted" do
    assert {:ok, display} = ClientDisplay.from_map(@display)
    assert :ok = ClientDisplay.validate(%{display | name: nil, logo_uri: nil})

    assert ClientDisplay.to_map(%{display | name: nil, logo_uri: nil}) == %{
             "uri" => @display["uri"]
           }

    assert {:error, %Error{validation_errors: issues}} =
             ClientDisplay.validate(%{display | name: false, uri: "/relative", logo_uri: "bad"})

    assert Enum.map(issues, & &1.field) == [:name, :uri, :logo_uri]
  end
end
