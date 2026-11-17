defmodule OpenPayments.Types.CardAuthorizationTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{CardAuthorization, PINWorkingKey}

  @pwk %{
    "key" => "test-encrypted-key",
    "kvc" => "test-key-check-value",
    "iv" => "test-initialization-vector"
  }
  @card %{"tlvData" => "test-card-data", "requestId" => "test-request-id"}
  @with_pin Map.merge(@card, %{"pinBlock" => "test-encrypted-pin", "pwk" => @pwk})

  test "matches the pinned card schema, outgoing access reference and one-way dependency" do
    {:ok, schema} = Specification.fetch_schema(:auth, "card-authorization")
    assert schema["required"] == ~w(tlvData requestId)
    assert schema["additionalProperties"] == false
    assert schema["dependentRequired"] == %{"pinBlock" => ["pwk"]}
    assert schema["properties"]["pwk"] == %{"$ref" => "#/components/schemas/pin-working-key"}

    for field <- ~w(tlvData requestId pinBlock) do
      assert schema["properties"][field]["type"] == "string"
      refute Map.has_key?(schema["properties"][field], "format")
      refute Map.has_key?(schema["properties"][field], "pattern")
    end

    {:ok, access} = Specification.fetch_schema(:auth, "access-outgoing")

    assert access["properties"]["cardAuthorization"] == %{
             "$ref" => "#/components/schemas/card-authorization"
           }
  end

  test "round trips official PIN and no-PIN card authorization examples" do
    examples =
      Specification.document(:auth)["paths"]["/"]["post"]["requestBody"]["content"][
        "application/json"
      ]["examples"]

    cards =
      for {_name, example} <- examples,
          access <- get_in(example, ["value", "access_token", "access"]) || [],
          card = access["cardAuthorization"],
          not is_nil(card),
          do: card

    assert Enum.any?(cards, &Map.has_key?(&1, "pinBlock"))
    assert Enum.any?(cards, &(not Map.has_key?(&1, "pinBlock")))

    for wire <- cards do
      assert {:ok, %CardAuthorization{} = card} = CardAuthorization.from_map(wire)
      if Map.has_key?(wire, "pwk"), do: assert(%PINWorkingKey{} = card.pwk)
      assert :ok = CardAuthorization.validate(card)
      assert CardAuthorization.to_map(card) == wire
      assert Jason.decode!(Jason.encode!(card)) == wire
    end
  end

  test "requires TLV data and request ID strings without coercion" do
    for {wire_field, field} <- [{"tlvData", :tlv_data}, {"requestId", :request_id}],
        data <- [
          Map.delete(@card, wire_field),
          Map.put(@card, wire_field, nil),
          Map.put(@card, wire_field, 1),
          Map.put(@card, wire_field, ["private-card-data"]),
          Map.put(@card, wire_field, <<255>>)
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               CardAuthorization.from_map(data)

      refute inspect(Map.from_struct(error)) =~ "private-card-data"
    end
  end

  test "distinguishes optional omission from explicit null and invalid field types" do
    assert {:ok, %CardAuthorization{pin_block: nil, pwk: nil} = card} =
             CardAuthorization.from_map(@card)

    assert CardAuthorization.to_map(card) == @card

    for pin <- [nil, false, [], 1, <<255>>] do
      assert {:error, %Error{validation_errors: [%{field: :pin_block}]}} =
               CardAuthorization.from_map(Map.put(@with_pin, "pinBlock", pin))
    end

    for pwk <- [nil, false, [], 1, "private-key-data"] do
      assert {:error, %Error{validation_errors: [%{field: :pwk}]} = error} =
               CardAuthorization.from_map(Map.put(@card, "pwk", pwk))

      refute inspect(Map.from_struct(error)) =~ "private-key-data"
    end
  end

  test "requires a working key whenever a PIN block is present, including an empty string" do
    for pin <- ["test-encrypted-pin", ""] do
      assert {:error, %Error{validation_errors: [%{field: :pwk}]}} =
               CardAuthorization.from_map(Map.put(@card, "pinBlock", pin))
    end

    {:ok, card} = CardAuthorization.from_map(@card)

    assert {:error, %Error{validation_errors: [%{field: :pwk}]}} =
             CardAuthorization.validate(%{card | pin_block: ""})
  end

  test "permits a working key without imposing the reverse PIN-block dependency" do
    wire = Map.put(@card, "pwk", @pwk)

    assert {:ok, %CardAuthorization{pwk: %PINWorkingKey{}, pin_block: nil} = card} =
             CardAuthorization.from_map(wire)

    assert CardAuthorization.to_map(card) == wire
  end

  test "prefixes nested working-key errors without leaking the material" do
    for {pwk, field} <- [
          {Map.delete(@pwk, "iv"), "pwk.iv"},
          {Map.put(@pwk, "key", ["private-key-material"]), "pwk.key"},
          {Map.put(@pwk, "extra", "private-key-material"), :pwk}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               CardAuthorization.from_map(Map.put(@with_pin, "pwk", pwk))

      refute inspect(Map.from_struct(error)) =~ "private-key-material"
    end
  end

  test "preserves strings without TLV decoding, hex constraints or request-ID format checks" do
    for value <- ["", "opaque-value", "Café 🌍"] do
      wire = %{"tlvData" => value, "requestId" => value, "pinBlock" => value, "pwk" => @pwk}
      assert {:ok, card} = CardAuthorization.from_map(wire)
      assert CardAuthorization.to_map(card) == wire
    end
  end

  test "rejects non-objects and extra fields or naming aliases" do
    for value <- [nil, [], false, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :card_authorization}]} = error} =
               CardAuthorization.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    for extra <- [
          %{"custom" => "private-extra"},
          %{"tlv_data" => "private-extra"},
          %{request_id: "private-extra"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :card_authorization}]} = error} =
               CardAuthorization.from_map(Map.merge(@card, extra))

      refute inspect(Map.from_struct(error)) =~ "private-extra"
    end
  end

  test "revalidates manual mutations and hides all payload fields in inspection and errors" do
    {:ok, card} = CardAuthorization.from_map(@with_pin)

    for value <- [@card["tlvData"], @card["requestId"], @with_pin["pinBlock"]] ++ Map.values(@pwk),
        do: refute(inspect(card) =~ value)

    assert CardAuthorization.to_map(card) == @with_pin

    for {changed, field} <- [
          {%{card | pwk: @pwk}, :pwk},
          {%{card | pwk: %{card.pwk | kvc: nil}}, "pwk.kvc"},
          {%{card | tlv_data: ["private-tlv"]}, :tlv_data},
          {%{card | request_id: ["private-request-id"]}, :request_id},
          {%{card | pin_block: ["private-pin"]}, :pin_block}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               CardAuthorization.validate(changed)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end

    without_pin = %{card | pin_block: nil, pwk: nil}
    assert :ok = CardAuthorization.validate(without_pin)
    assert CardAuthorization.to_map(without_pin) == @card
  end
end
