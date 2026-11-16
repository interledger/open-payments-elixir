defmodule OpenPayments.Types.AmountTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias OpenPayments.Error
  alias OpenPayments.Specification
  alias OpenPayments.Types.Amount

  @max_value 18_446_744_073_709_551_615

  test "the model contract matches the amount schemas of both servers" do
    for server <- [:auth, :resource] do
      {:ok, schema} = Specification.fetch_schema(server, "amount")
      properties = schema["properties"]

      assert Enum.sort(schema["required"]) == ~w(assetCode assetScale value)
      assert schema["type"] == "object"
      assert Map.get(schema, "additionalProperties", true) == true
      assert properties["value"]["type"] == "string"
      assert properties["value"]["format"] == "uint64"
      assert properties["assetCode"]["type"] == "string"

      assert Map.take(properties["assetScale"], ~w(type minimum maximum)) == %{
               "type" => "integer",
               "minimum" => 0,
               "maximum" => 255
             }
    end
  end

  test "accepts zero and the unsigned 64-bit maximum at both scale boundaries" do
    for value <- ["0", Integer.to_string(@max_value)], scale <- [0, 255] do
      assert {:ok, %Amount{value: ^value, asset_code: "USD", asset_scale: ^scale}} =
               Amount.new(value, "USD", scale)
    end
  end

  test "keeps leading zeroes and non-ISO asset codes unchanged" do
    assert {:ok, amount} = Amount.new("00001000", "custom-token", 8)
    assert amount.value == "00001000"
    assert amount.asset_code == "custom-token"

    assert {:ok, _} = Amount.new("000" <> Integer.to_string(@max_value), "USD", 2)
    assert {:ok, _} = Amount.new(String.duplicate("0", 1000), "USD", 2)
  end

  test "follows the schema's string constraint without imposing ISO currency rules" do
    assert {:ok, _} = Amount.new("1", "", 0)
    assert {:ok, _} = Amount.new("1", "asset-α", 0)
  end

  test "rejects signs, fractions, exponents, whitespace, non-ASCII digits and non-strings" do
    for value <- [
          "",
          "-1",
          "+1",
          "1.0",
          "1e3",
          " 1",
          "1 ",
          "1\n",
          "１２",
          "1x",
          <<255>>,
          1,
          1.0,
          nil,
          true
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: issues}} =
               Amount.new(value, "USD", 2)

      assert Enum.map(issues, & &1.field) == [:value]
    end
  end

  test "rejects overflow without converting an unbounded string to a big integer" do
    for value <- [
          Integer.to_string(@max_value + 1),
          "00018446744073709551616",
          String.duplicate("9", 1000)
        ] do
      assert {:error, %Error{validation_errors: [%{field: :value}]}} = Amount.new(value, "USD", 2)
    end
  end

  test "rejects invalid scales without coercion" do
    for scale <- [-1, 256, 2.0, "2", nil, true] do
      assert {:error, %Error{validation_errors: [%{field: :asset_scale}]}} =
               Amount.new("1", "USD", scale)
    end
  end

  test "rejects invalid asset code types and invalid UTF-8" do
    for code <- [nil, :USD, 123, <<255>>] do
      assert {:error, %Error{validation_errors: [%{field: :asset_code}]}} =
               Amount.new("1", code, 2)
    end
  end

  test "decodes required wire fields and reports all missing fields" do
    assert {:ok, %Amount{value: "1000", asset_code: "USD", asset_scale: 2}} =
             Amount.from_map(%{"value" => "1000", "assetCode" => "USD", "assetScale" => 2})

    assert {:error, %Error{validation_errors: issues}} = Amount.from_map(%{})
    assert Enum.map(issues, & &1.field) == [:value, :asset_code, :asset_scale]
  end

  test "rejects explicit null fields" do
    assert {:error, %Error{validation_errors: issues}} =
             Amount.from_map(%{"value" => nil, "assetCode" => nil, "assetScale" => nil})

    assert Enum.map(issues, & &1.field) == [:value, :asset_code, :asset_scale]
  end

  test "rejects non-object inputs and maps with atom keys" do
    for value <- [nil, [], "amount", 1, %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :amount}]}} = Amount.from_map(value)
    end

    assert {:error, %Error{validation_errors: issues}} =
             Amount.from_map(%{value: "1", asset_code: "USD", asset_scale: 2})

    assert Enum.any?(issues, &(&1.field == :extensions))
  end

  test "encodes exact wire names and preserves an amount as a string inside JSON" do
    {:ok, amount} = Amount.new(Integer.to_string(@max_value), "USD", 2)

    expected = %{"value" => "18446744073709551615", "assetCode" => "USD", "assetScale" => 2}
    assert Amount.to_map(amount) == expected

    assert Jason.decode!(Jason.encode!(%{"incomingAmount" => amount})) == %{
             "incomingAmount" => expected
           }
  end

  test "retains additional JSON fields, including nested objects and null values" do
    wire = %{
      "value" => "1",
      "assetCode" => "USD",
      "assetScale" => 2,
      "custom" => %{"labels" => ["example", nil, 3]},
      "optional" => nil
    }

    assert {:ok, amount} = Amount.from_map(wire)
    assert amount.extensions == Map.take(wire, ["custom", "optional"])
    assert :ok = Amount.validate(amount)
    assert Amount.to_map(amount) == wire
    assert Jason.decode!(Jason.encode!(amount)) == wire
  end

  test "validates manually modified structs and rejects conflicting or non-JSON extensions" do
    {:ok, amount} = Amount.new("1", "USD", 2)

    assert {:error, %Error{validation_errors: [%{field: :value}]}} =
             Amount.validate(%{amount | value: -1})

    for extensions <- [nil, [], %URI{}, %{key: "value"}, %{"value" => "2"}, %{"x" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               Amount.validate(%{amount | extensions: extensions})
    end
  end

  property "every uint64 value and permitted scale keeps its exact protocol representation" do
    check all(
            units <- integer(0..@max_value),
            scale <- integer(0..255),
            code <- string(:alphanumeric, min_length: 1, max_length: 12)
          ) do
      value = Integer.to_string(units)
      assert {:ok, amount} = Amount.new(value, code, scale)

      assert Jason.decode!(Jason.encode!(amount)) == %{
               "value" => value,
               "assetCode" => code,
               "assetScale" => scale
             }
    end
  end

  property "values above uint64 are rejected" do
    check all(excess <- integer(1..1_000_000)) do
      assert {:error, %Error{kind: :validation}} =
               Amount.new(Integer.to_string(@max_value + excess), "USD", 2)
    end
  end
end
