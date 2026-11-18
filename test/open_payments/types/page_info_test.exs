defmodule OpenPayments.Types.PageInfoTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.PageInfo

  @minimal %{"hasNextPage" => false, "hasPreviousPage" => false}

  test "matches the pinned strict page-info schema and shared list references" do
    {:ok, schema} = Specification.fetch_schema(:resource, "page-info")
    assert schema["type"] == "object"
    assert Enum.sort(schema["required"]) == ~w(hasNextPage hasPreviousPage)
    assert schema["additionalProperties"] == false

    assert Enum.sort(Map.keys(schema["properties"])) ==
             ~w(endCursor hasNextPage hasPreviousPage startCursor)

    for cursor <- ~w(startCursor endCursor) do
      assert schema["properties"][cursor]["type"] == "string"
      assert schema["properties"][cursor]["minLength"] == 1
      refute Map.has_key?(schema["properties"][cursor], "format")
    end

    for field <- ~w(hasNextPage hasPreviousPage) do
      assert schema["properties"][field]["type"] == "boolean"
      refute Map.has_key?(schema["properties"][field], "default")
    end

    for path <- ["/incoming-payments", "/outgoing-payments"] do
      schema =
        Specification.document(:resource)["paths"][path]["get"]["responses"]["200"]["content"][
          "application/json"
        ]["schema"]

      assert schema["properties"]["pagination"] == %{"$ref" => "#/components/schemas/page-info"}
    end
  end

  test "round trips every standalone and incoming/outgoing list pagination example" do
    {:ok, schema} = Specification.fetch_schema(:resource, "page-info")
    examples = schema["examples"]
    assert examples != []

    list_examples =
      for path <- ["/incoming-payments", "/outgoing-payments"],
          {_name, %{"value" => value}} <-
            Specification.document(:resource)["paths"][path]["get"]["responses"]["200"]["content"][
              "application/json"
            ]["examples"],
          do: value["pagination"]

    assert length(list_examples) >= 4

    for wire <- examples ++ list_examples do
      assert {:ok, %PageInfo{} = page} = PageInfo.from_map(wire)
      assert :ok = PageInfo.validate(page)
      assert PageInfo.to_map(page) == wire
      assert Jason.decode!(Jason.encode!(page)) == wire
    end
  end

  test "accepts required false flags without defaults and omits missing cursors" do
    assert {:ok, page} = PageInfo.from_map(@minimal)
    assert page.has_next_page == false and page.has_previous_page == false
    assert page.start_cursor == nil and page.end_cursor == nil
    assert PageInfo.to_map(page) == @minimal

    assert Jason.decode!(Jason.encode!(%PageInfo{has_next_page: false, has_previous_page: false})) ==
             @minimal
  end

  test "rejects missing, null or nonboolean flags rather than inferring false" do
    for {wire_field, field} <- [
          {"hasNextPage", :has_next_page},
          {"hasPreviousPage", :has_previous_page}
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]}} =
               PageInfo.from_map(Map.delete(@minimal, wire_field))

      for value <- [nil, "private-flag", "false", 0, 1, [], %{}] do
        assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
                 PageInfo.from_map(Map.put(@minimal, wire_field, value))

        refute inspect(Map.from_struct(error)) =~ "private-flag"
      end
    end

    assert {:error, %Error{validation_errors: issues}} = PageInfo.from_map(%{})
    assert Enum.map(issues, & &1.field) == [:has_next_page, :has_previous_page]
  end

  test "rejects explicit null, empty, invalid UTF-8 and nonstring optional cursors" do
    for {wire_field, field} <- [{"startCursor", :start_cursor}, {"endCursor", :end_cursor}],
        value <- [nil, "", <<255>>, false, 1, 1.5, [], %{}, %URI{}] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]}} =
               PageInfo.from_map(Map.put(@minimal, wire_field, value))
    end
  end

  test "preserves opaque cursor spelling without imposing UUID, URI or encoding rules" do
    for cursor <- [
          "private-cursor",
          "a+/=%2f?&",
          "☕",
          "e\u0301",
          " ",
          "  opaque  ",
          "\n",
          "\u0000"
        ] do
      wire = Map.merge(@minimal, %{"startCursor" => cursor, "endCursor" => cursor})
      assert {:ok, page} = PageInfo.from_map(wire)
      assert :ok = PageInfo.validate(page)
      assert page.start_cursor == cursor and page.end_cursor == cursor
      assert Jason.decode!(Jason.encode!(page)) == wire
    end
  end

  test "permits either cursor independently and does not infer flag or cursor relationships" do
    for next <- [true, false],
        previous <- [true, false],
        cursors <- [
          %{},
          %{"startCursor" => "start-only"},
          %{"endCursor" => "end-only"},
          %{"startCursor" => "same", "endCursor" => "same"},
          %{"startCursor" => "z", "endCursor" => "a"}
        ] do
      wire = Map.merge(%{"hasNextPage" => next, "hasPreviousPage" => previous}, cursors)
      assert {:ok, page} = PageInfo.from_map(wire)
      assert :ok = PageInfo.validate(page)
      assert PageInfo.to_map(page) == wire
    end
  end

  test "rejects extra fields, aliases and invalid roots without exposing values or unknown names" do
    for field <- [
          "private-field",
          "extensions",
          "start_cursor",
          "end_cursor",
          "has_next_page",
          "has_previous_page",
          :startCursor
        ] do
      assert {:error,
              %Error{kind: :validation, validation_errors: [%{field: :page_info}]} = error} =
               PageInfo.from_map(Map.put(@minimal, field, "private-value"))

      refute inspect(Map.from_struct(error)) =~ "private-"
    end

    for root <- [
          nil,
          false,
          1,
          "private-data",
          [],
          %URI{},
          %PageInfo{has_next_page: true, has_previous_page: false}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :page_info}]} = error} =
               PageInfo.from_map(root)

      refute inspect(Map.from_struct(error)) =~ "private-data"
    end
  end

  test "revalidates manually modified structs and treats nil cursors as omitted" do
    page = %PageInfo{
      has_next_page: true,
      has_previous_page: false,
      start_cursor: "start",
      end_cursor: "end"
    }

    assert :ok = PageInfo.validate(page)

    for {invalid, field} <- [
          {%{page | has_next_page: nil}, :has_next_page},
          {%{page | has_previous_page: "private-flag"}, :has_previous_page},
          {%{page | start_cursor: ""}, :start_cursor},
          {%{page | end_cursor: <<255>>}, :end_cursor}
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]} = error} =
               PageInfo.validate(invalid)

      refute inspect(Map.from_struct(error)) =~ "private-flag"
    end

    assert :ok = PageInfo.validate(%{page | start_cursor: nil, end_cursor: nil})

    assert PageInfo.to_map(%{page | start_cursor: nil, end_cursor: nil}) == %{
             "hasNextPage" => true,
             "hasPreviousPage" => false
           }
  end

  test "inspection hides cursors while explicit exports include protocol names without validating" do
    wire = Map.merge(@minimal, %{"startCursor" => "private-start", "endCursor" => "private-end"})
    assert {:ok, page} = PageInfo.from_map(wire)
    refute inspect(page) =~ "private-"
    assert inspect(page) =~ "has_next_page: false"
    assert PageInfo.to_map(page) == wire
    assert Jason.decode!(Jason.encode!(page)) == wire

    invalid = %{page | start_cursor: ""}
    assert {:error, _} = PageInfo.validate(invalid)
    assert PageInfo.to_map(invalid)["startCursor"] == ""
  end
end
