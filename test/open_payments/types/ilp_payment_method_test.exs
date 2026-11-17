defmodule OpenPayments.Types.ILPPaymentMethodTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.ILPPaymentMethod

  @method %{
    "type" => "ilp",
    "ilpAddress" => "g.ilp.iwuyge987y.98y08y",
    "sharedSecret" => "1c7eaXa4rd2fFOBl1iydvCT1tV5TbM3RW1WLCafu_JA"
  }

  test "matches the pinned ILP method schema and incoming-payment method reference" do
    {:ok, schema} = Specification.fetch_schema(:resource, "ilp-payment-method")
    assert schema["type"] == "object"
    assert schema["additionalProperties"] == false
    assert Enum.sort(schema["required"]) == ~w(ilpAddress sharedSecret type)
    assert schema["properties"]["type"] == %{"type" => "string", "enum" => ["ilp"]}
    assert schema["properties"]["ilpAddress"]["maxLength"] == 1023

    assert schema["properties"]["ilpAddress"]["pattern"] ==
             "^(g|private|example|peer|self|test[1-3]?|local)([.][a-zA-Z0-9_~-]+)+$"

    assert schema["properties"]["sharedSecret"]["pattern"] == "^[a-zA-Z0-9-_]+$"
    refute Map.has_key?(schema["properties"]["sharedSecret"], "minLength")
    refute Map.has_key?(schema["properties"]["sharedSecret"], "maxLength")

    {:ok, base} = Specification.fetch_schema(:resource, "incoming-payment-base-with-methods")
    methods = Enum.at(base["allOf"], 1)["properties"]["methods"]
    assert methods["items"]["anyOf"] == [%{"$ref" => "#/components/schemas/ilp-payment-method"}]
  end

  test "decodes methods from the official incoming-payment examples and round trips JSON" do
    for name <- ["incoming-payment-with-access-token", "incoming-payment-without-access-token"] do
      {:ok, schema} = Specification.fetch_schema(:resource, name)

      for payment <- schema["examples"], wire <- payment["methods"] do
        assert {:ok, %ILPPaymentMethod{} = method} = ILPPaymentMethod.from_map(wire)
        assert method.type == "ilp"
        assert method.ilp_address == wire["ilpAddress"]
        assert method.shared_secret == wire["sharedSecret"]
        assert :ok = ILPPaymentMethod.validate(method)
        assert ILPPaymentMethod.to_map(method) == wire
        assert Jason.decode!(Jason.encode!(method)) == wire
      end
    end
  end

  test "reports missing, null and incorrectly typed fields without defaulting" do
    for {wire_field, field} <- [
          {"type", :type},
          {"ilpAddress", :ilp_address},
          {"sharedSecret", :shared_secret}
        ],
        data <- [
          Map.delete(@method, wire_field),
          Map.put(@method, wire_field, nil),
          Map.put(@method, wire_field, 1),
          Map.put(@method, wire_field, <<255>>)
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]}} =
               ILPPaymentMethod.from_map(data)
    end

    for value <- ["ILP", "card", "", :ilp] do
      assert {:error, %Error{validation_errors: [%{field: :type}]}} =
               ILPPaymentMethod.from_map(Map.put(@method, "type", value))
    end
  end

  test "accepts supported ILP address prefixes, segment alphabet and maximum length" do
    for prefix <- ~w(g private example peer self test test1 test2 test3 local) do
      assert {:ok, _} =
               ILPPaymentMethod.from_map(Map.put(@method, "ilpAddress", prefix <> ".AbC09_~-.x"))
    end

    assert {:ok, _} =
             ILPPaymentMethod.from_map(
               Map.put(@method, "ilpAddress", "g." <> String.duplicate("a", 1021))
             )
  end

  test "rejects malformed and oversized addresses including trailing whitespace" do
    for address <- [
          "",
          "g",
          "g.",
          "g..alice",
          "G.alice",
          "test0.alice",
          "test4.alice",
          "unknown.alice",
          "g.alice/path",
          "g.alice+other",
          "g.alicé",
          "g.alice\n",
          " g.alice",
          "g." <> String.duplicate("a", 1022)
        ] do
      assert {:error, %Error{validation_errors: [%{field: :ilp_address}]}} =
               ILPPaymentMethod.from_map(Map.put(@method, "ilpAddress", address))
    end
  end

  test "validates the secret alphabet without imposing decoded length or canonical encoding" do
    for secret <- ["A", "abc", "AZaz09_-", @method["sharedSecret"]] do
      assert {:ok, method} = ILPPaymentMethod.from_map(Map.put(@method, "sharedSecret", secret))
      assert method.shared_secret == secret
    end

    for secret <- ["", "YWJj=", "ab+c", "ab/c", "ab c", "abc\n", "é"] do
      assert {:error, %Error{validation_errors: [%{field: :shared_secret}]}} =
               ILPPaymentMethod.from_map(Map.put(@method, "sharedSecret", secret))
    end
  end

  test "rejects non-objects and extra fields rather than silently discarding them" do
    for data <- [nil, [], false, "ilp", 1, %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :payment_method}]}} =
               ILPPaymentMethod.from_map(data)
    end

    for key <- ["extra", :shared_secret] do
      assert {:error, %Error{validation_errors: [%{field: :payment_method}]}} =
               ILPPaymentMethod.from_map(Map.put(@method, key, "private-extra-must-not-leak"))
    end
  end

  test "validates manual struct changes and keeps secrets out of inspection and errors" do
    {:ok, method} = ILPPaymentMethod.from_map(@method)
    refute inspect(method) =~ @method["sharedSecret"]
    refute inspect(%{method | shared_secret: "private-secret"}) =~ "private-secret"

    assert {:error, %Error{validation_errors: issues} = error} =
             ILPPaymentMethod.validate(%{method | type: "card", shared_secret: "private-secret="})

    assert Enum.map(issues, & &1.field) == [:type, :shared_secret]
    refute inspect(Map.from_struct(error)) =~ "private-secret"
    refute inspect(error) =~ "private-secret"
    assert ILPPaymentMethod.to_map(method)["sharedSecret"] == @method["sharedSecret"]
  end
end
