defmodule OpenPayments.Types.SubjectIdentifierTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.SubjectIdentifier

  @identifier %{"id" => "https://wallet.example.com/alice", "format" => "uri"}

  test "matches the pinned identifier's required strings and format discriminator" do
    {:ok, subject} = Specification.fetch_schema(:auth, "subject")
    schema = subject["properties"]["sub_ids"]["items"]
    assert schema["type"] == "object"
    assert schema["required"] == ~w(id format)
    assert schema["properties"]["id"]["type"] == "string"
    refute Map.has_key?(schema["properties"]["id"], "format")
    refute Map.has_key?(schema["properties"]["id"], "pattern")
    refute Map.has_key?(schema["properties"]["id"], "minLength")
    assert schema["properties"]["format"]["enum"] == ["uri"]
    assert Map.get(schema, "additionalProperties", true) == true
  end

  test "round trips identifier data and preserves permitted extensions" do
    wire = Map.put(@identifier, "custom", %{"values" => [nil, true, 123]})
    assert {:ok, %SubjectIdentifier{} = identifier} = SubjectIdentifier.from_map(wire)
    assert identifier.id == @identifier["id"]
    assert identifier.format == "uri"
    assert identifier.extensions == Map.take(wire, ["custom"])
    assert :ok = SubjectIdentifier.validate(identifier)
    assert SubjectIdentifier.to_map(identifier) == wire
    assert Jason.decode!(Jason.encode!(identifier)) == wire
  end

  test "requires id and exact format strings without coercion" do
    for {wire_field, field} <- [{"id", :id}, {"format", :format}],
        data <- [
          Map.delete(@identifier, wire_field),
          Map.put(@identifier, wire_field, nil),
          Map.put(@identifier, wire_field, 1),
          Map.put(@identifier, wire_field, <<255>>)
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]}} =
               SubjectIdentifier.from_map(data)
    end

    for format <- ["URI", "email", "", :uri] do
      assert {:error, %Error{validation_errors: [%{field: :format}]}} =
               SubjectIdentifier.from_map(Map.put(@identifier, "format", format))
    end
  end

  test "preserves id strings without inventing URI-format or request-target constraints" do
    for id <- [
          "",
          "opaque-subject-id",
          "http://localhost:3000/accounts/alice",
          "https://Wallet.Example.COM:8443/alice?x=1#state",
          "Café 🌍"
        ] do
      wire = %{@identifier | "id" => id}
      assert {:ok, identifier} = SubjectIdentifier.from_map(wire)
      assert SubjectIdentifier.to_map(identifier) == wire
    end
  end

  test "rejects non-objects and non-JSON extension data with safe errors" do
    for value <- [nil, [], false, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :subject_identifier}]} = error} =
               SubjectIdentifier.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    for extra <- [%{custom: true}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               SubjectIdentifier.from_map(Map.merge(@identifier, extra))
    end
  end

  test "revalidates manual changes, protects reserved exports and omits identity data from inspection" do
    wire = %{@identifier | "id" => "private-subject-id"} |> Map.put("custom", "private-extension")
    {:ok, identifier} = SubjectIdentifier.from_map(wire)
    refute inspect(identifier) =~ "private-"
    assert SubjectIdentifier.to_map(identifier) == wire

    assert {:error, %Error{validation_errors: issues} = error} =
             SubjectIdentifier.validate(%{identifier | id: ["private-id"], format: "email"})

    assert Enum.map(issues, & &1.field) == [:id, :format]
    refute inspect(Map.from_struct(error)) =~ "private-id"

    changed = %{identifier | extensions: %{"id" => "override"}}

    assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
             SubjectIdentifier.validate(changed)

    assert SubjectIdentifier.to_map(changed)["id"] == "private-subject-id"
  end
end
