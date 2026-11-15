defmodule OpenPayments.SpecificationTest do
  use ExUnit.Case, async: true

  alias OpenPayments.Specification

  @servers [:auth, :resource, :wallet_address]

  test "all documents share the recorded version and use OpenAPI 3.1" do
    assert Specification.revision() =~ ~r/\A[0-9a-f]{40}\z/

    for server <- @servers do
      document = Specification.document(server)
      assert document["info"]["version"] == OpenPayments.specification_version()
      assert document["openapi"] == "3.1.0"
    end
  end

  test "operation inventory covers every first-release protocol endpoint" do
    operations = Specification.operations()

    assert Enum.frequencies_by(operations, & &1.server) == %{
             auth: 5,
             resource: 10,
             wallet_address: 2
           }

    assert length(Enum.uniq_by(operations, & &1.id)) == length(operations)

    assert Enum.any?(operations, fn operation ->
             operation.id == "get-outgoing-payment-grant" and
               operation.method == :get and operation.success_statuses == [200]
           end)

    for operation <- operations, operation.method == :delete do
      assert operation.success_statuses == [204]
    end
  end

  test "bundled documents are self-contained and every local reference resolves" do
    for server <- @servers do
      document = Specification.document(server)

      for reference <- references(document) do
        assert String.starts_with?(reference, "#/"), "external reference: #{reference}"

        result =
          reference
          |> String.replace_prefix("#/", "")
          |> String.split("/")
          |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
          |> Enum.reduce(document, &Map.fetch!(&2, &1))

        assert is_map(result), "unresolved schema: #{reference}"
      end
    end
  end

  test "request variants retain card data dependencies and client identification alternatives" do
    assert {:ok, card} = Specification.fetch_schema(:auth, "card-authorization")
    assert card["dependentRequired"] == %{"pinBlock" => ["pwk"]}
    assert {:ok, client} = Specification.fetch_schema(:auth, "client")
    assert length(client["oneOf"]) == 3
    assert :error = Specification.fetch_schema(:auth, "unknown-schema")
  end

  test "bundled artifacts match their recorded checksums" do
    directory = Path.expand("../../priv/specifications", __DIR__)
    source = directory |> Path.join("SOURCE.json") |> File.read!() |> Jason.decode!()

    for name <- source["files"] do
      checksum =
        directory
        |> Path.join(name)
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert checksum == source["sha256"][name]
    end
  end

  defp references(value) when is_map(value) do
    own = if Map.has_key?(value, "$ref"), do: [value["$ref"]], else: []
    own ++ Enum.flat_map(Map.values(value), &references/1)
  end

  defp references(value) when is_list(value), do: Enum.flat_map(value, &references/1)
  defp references(_value), do: []
end
