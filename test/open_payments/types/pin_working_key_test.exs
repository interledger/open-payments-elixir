defmodule OpenPayments.Types.PINWorkingKeyTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.PINWorkingKey

  @pwk %{
    "key" => "test-encrypted-key",
    "kvc" => "test-key-check-value",
    "iv" => "test-initialization-vector"
  }

  test "matches the pinned PIN working-key schema without adding cryptographic formats" do
    {:ok, schema} = Specification.fetch_schema(:auth, "pin-working-key")
    assert schema["type"] == "object"
    assert schema["required"] == ~w(key kvc iv)
    assert schema["additionalProperties"] == false

    for field <- ~w(key kvc iv) do
      assert schema["properties"][field]["type"] == "string"
      refute Map.has_key?(schema["properties"][field], "pattern")
      refute Map.has_key?(schema["properties"][field], "minLength")
      refute Map.has_key?(schema["properties"][field], "maxLength")
    end
  end

  test "round trips PIN working keys in the official grant examples" do
    examples =
      Specification.document(:auth)["paths"]["/"]["post"]["requestBody"]["content"][
        "application/json"
      ]["examples"]

    entries =
      for {_name, example} <- examples,
          access <- get_in(example, ["value", "access_token", "access"]) || [],
          pwk = get_in(access, ["cardAuthorization", "pwk"]),
          not is_nil(pwk),
          do: pwk

    assert entries != []

    for wire <- entries do
      assert {:ok, %PINWorkingKey{} = pwk} = PINWorkingKey.from_map(wire)
      assert :ok = PINWorkingKey.validate(pwk)
      assert PINWorkingKey.to_map(pwk) == wire
      assert Jason.decode!(Jason.encode!(pwk)) == wire
    end
  end

  test "requires string values and reports missing, null or invalid fields safely" do
    for {wire_field, field} <- [{"key", :key}, {"kvc", :kvc}, {"iv", :iv}],
        data <- [
          Map.delete(@pwk, wire_field),
          Map.put(@pwk, wire_field, nil),
          Map.put(@pwk, wire_field, 1),
          Map.put(@pwk, wire_field, ["private-material"]),
          Map.put(@pwk, wire_field, <<255>>)
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]} = error} =
               PINWorkingKey.from_map(data)

      refute inspect(Map.from_struct(error)) =~ "private-material"
    end
  end

  test "preserves schema-valid strings without hex, size or key-value interpretation" do
    for value <- ["", "opaque-value", "Café 🌍"] do
      wire = %{"key" => value, "kvc" => value, "iv" => value}
      assert {:ok, pwk} = PINWorkingKey.from_map(wire)
      assert PINWorkingKey.to_map(pwk) == wire
    end
  end

  test "rejects non-objects, extra fields and alternative field spellings" do
    for value <- [nil, [], false, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :pin_working_key}]} = error} =
               PINWorkingKey.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    for extra <- [
          %{"custom" => "private-extra"},
          %{"kcv" => "private-extra"},
          %{key: "private-extra"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :pin_working_key}]} = error} =
               PINWorkingKey.from_map(Map.merge(@pwk, extra))

      refute inspect(Map.from_struct(error)) =~ "private-extra"
    end
  end

  test "revalidates manual changes, hides all fields in inspection and exports values explicitly" do
    {:ok, pwk} = PINWorkingKey.from_map(@pwk)
    for value <- Map.values(@pwk), do: refute(inspect(pwk) =~ value)
    assert PINWorkingKey.to_map(pwk) == @pwk

    assert {:error, %Error{validation_errors: issues} = error} =
             PINWorkingKey.validate(%{pwk | key: ["private-key"], kvc: false, iv: nil})

    assert Enum.map(issues, & &1.field) == [:key, :kvc, :iv]
    refute inspect(Map.from_struct(error)) =~ "private-key"
  end
end
