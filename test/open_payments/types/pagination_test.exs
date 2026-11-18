defmodule OpenPayments.Types.PaginationTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.Pagination

  test "matches the pinned shared optional query parameters without schema defaults" do
    document = Specification.document(:resource)
    parameters = document["components"]["parameters"]

    for name <- ~w(first last cursor) do
      parameter = parameters[name]
      assert parameter["name"] == name and parameter["in"] == "query"
      refute parameter["required"]
      refute Map.has_key?(parameter["schema"], "default")

      for path <- ["/incoming-payments", "/outgoing-payments"] do
        assert %{"$ref" => "#/components/parameters/" <> name} in document["paths"][path]["get"][
                 "parameters"
               ]
      end
    end

    for name <- ~w(first last) do
      assert parameters[name]["schema"] == %{
               "type" => "integer",
               "minimum" => 1,
               "maximum" => 100
             }
    end

    assert parameters["cursor"]["schema"] == %{"type" => "string", "minLength" => 1}
  end

  test "accepts empty map and typed arguments without applying size or direction defaults" do
    assert {:ok, %Pagination{} = pagination} = Pagination.from_map(%{})
    assert pagination.first == nil and pagination.last == nil and pagination.cursor == nil
    assert :ok = Pagination.validate(pagination)
    assert Pagination.to_map(pagination) == %{}
    assert Pagination.to_map(%Pagination{}) == %{}
    assert Jason.decode!(Jason.encode!(pagination)) == %{}
  end

  test "accepts all integer sizes in the declared range in either direction with optional cursors" do
    for size <- 1..100, name <- ~w(first last), cursor <- [nil, "opaque-cursor"] do
      wire = %{name => size}
      wire = if is_nil(cursor), do: wire, else: Map.put(wire, "cursor", cursor)
      assert {:ok, pagination} = Pagination.from_map(wire)
      assert :ok = Pagination.validate(pagination)
      assert Pagination.to_map(pagination) == wire
      assert Jason.decode!(Jason.encode!(pagination)) == wire
    end
  end

  test "rejects out-of-range counts, numeric strings, floats and nonintegers without coercion" do
    for {name, field} <- [{"first", :first}, {"last", :last}],
        value <- [
          -1,
          0,
          101,
          999_999_999_999_999_999_999,
          "1",
          "100",
          "private-size",
          1.0,
          100.0,
          true,
          false,
          [],
          %{},
          <<255>>
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]} = error} =
               Pagination.from_map(%{name => value})

      refute inspect(Map.from_struct(error)) =~ "private-size"
    end
  end

  test "enforces Node's mutually exclusive forward and backward direction contract" do
    for first <- [1, 100], last <- [1, 100], cursor <- [nil, "opaque"] do
      wire = %{"first" => first, "last" => last}
      wire = if is_nil(cursor), do: wire, else: Map.put(wire, "cursor", cursor)

      assert {:error,
              %Error{
                kind: :validation,
                validation_errors: [
                  %{field: :pagination, message: "must not supply both first and last"}
                ]
              }} = Pagination.from_map(wire)

      assert {:error, %Error{validation_errors: [%{field: :pagination}]}} =
               Pagination.validate(%Pagination{first: first, last: last, cursor: cursor})
    end
  end

  test "rejects explicit null for every optional map field but treats typed nil as omission" do
    for {name, field} <- [{"first", :first}, {"last", :last}, {"cursor", :cursor}] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               Pagination.from_map(%{name => nil})
    end

    assert :ok = Pagination.validate(%Pagination{first: nil, last: nil, cursor: nil})
    assert :ok = Pagination.validate(%Pagination{first: 25, last: nil})
    assert Pagination.to_map(%Pagination{first: 25, last: nil}) == %{"first" => 25}

    assert {:error, %Error{validation_errors: errors}} =
             Pagination.from_map(%{"first" => 25, "last" => nil})

    assert Enum.map(errors, & &1.field) == [:last, :pagination]
  end

  test "rejects empty, invalid UTF-8 and nonstring cursors" do
    for cursor <- ["", <<255>>, false, 1, 1.5, [], %{}, %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :cursor}]}} =
               Pagination.from_map(%{"cursor" => cursor})
    end
  end

  test "preserves opaque cursors with or without counts and exports raw values without query encoding" do
    for cursor <- [
          "private-cursor",
          "a+/=%2f?&",
          "☕",
          "e\u0301",
          " ",
          "  opaque  ",
          "\n",
          "\u0000"
        ],
        counts <- [%{}, %{"first" => 1}, %{"last" => 100}] do
      wire = Map.put(counts, "cursor", cursor)
      assert {:ok, pagination} = Pagination.from_map(wire)
      assert pagination.cursor == cursor
      assert :ok = Pagination.validate(pagination)
      assert Pagination.to_map(pagination) == wire
      assert Jason.decode!(Jason.encode!(pagination)) == wire
    end
  end

  test "rejects unsupported filter/credential/alias fields and invalid roots with safe errors" do
    for name <- [
          "wallet-address",
          "wallet_address",
          "access_token",
          "startCursor",
          "endCursor",
          "hasNextPage",
          "limit",
          "offset",
          "extensions",
          "private-field",
          :first
        ] do
      assert {:error,
              %Error{kind: :validation, validation_errors: [%{field: :pagination}]} = error} =
               Pagination.from_map(%{name => "private-value"})

      refute inspect(Map.from_struct(error)) =~ "private-"
    end

    for root <- [nil, false, 1, "private-data", [], [first: 10], %URI{}, %Pagination{}] do
      assert {:error, %Error{validation_errors: [%{field: :pagination}]} = error} =
               Pagination.from_map(root)

      refute inspect(Map.from_struct(error)) =~ "private-data"
    end
  end

  test "revalidates modified structs and exports shape without silently validating or repairing" do
    pagination = %Pagination{first: 25, cursor: "opaque"}
    assert :ok = Pagination.validate(pagination)

    for {invalid, field} <- [
          {%{pagination | first: 0}, :first},
          {%{pagination | first: "private-size"}, :first},
          {%{pagination | first: nil, last: 101}, :last},
          {%{pagination | cursor: ""}, :cursor},
          {%{pagination | cursor: <<255>>}, :cursor}
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: ^field}]} = error} =
               Pagination.validate(invalid)

      refute inspect(Map.from_struct(error)) =~ "private-size"
    end

    assert Pagination.to_map(%{pagination | first: 0}) == %{"first" => 0, "cursor" => "opaque"}

    assert Jason.decode!(Jason.encode!(%{pagination | first: nil, last: 10})) == %{
             "last" => 10,
             "cursor" => "opaque"
           }
  end

  test "inspection hides cursor data while explicit exports include it" do
    pagination = %Pagination{last: 50, cursor: "private-cursor"}
    refute inspect(pagination) =~ "private-cursor"
    assert inspect(pagination) =~ "last: 50"
    assert Pagination.to_map(pagination) == %{"last" => 50, "cursor" => "private-cursor"}
    assert Jason.decode!(Jason.encode!(pagination)) == Pagination.to_map(pagination)
  end
end
