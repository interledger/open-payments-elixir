defmodule OpenPayments.Types.SubjectTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Specification}
  alias OpenPayments.Types.{Subject, SubjectIdentifier}

  @identifier %{"id" => "https://wallet.example.com/alice", "format" => "uri"}
  @subject %{"sub_ids" => [@identifier]}

  test "matches the pinned single-identifier subject schema and grant references" do
    {:ok, schema} = Specification.fetch_schema(:auth, "subject")
    assert schema["type"] == "object"
    assert schema["required"] == ["sub_ids"]
    assert schema["properties"]["sub_ids"]["type"] == "array"
    assert schema["properties"]["sub_ids"]["minItems"] == 1
    assert schema["properties"]["sub_ids"]["maxItems"] == 1
    assert Map.get(schema, "additionalProperties", true) == true

    for name <- ~w(grant-request-with-access-token grant-request-with-subject) do
      {:ok, grant} = Specification.fetch_schema(:auth, name)
      assert grant["properties"]["subject"] == %{"$ref" => "#/components/schemas/subject"}
    end

    response =
      Specification.document(:auth)["paths"]["/continue/{id}"]["post"]["responses"]["200"][
        "content"
      ]["application/json"]["schema"]

    assert response["properties"]["subject"] == %{"$ref" => "#/components/schemas/subject"}
  end

  test "round trips subject data from the official grant example as typed identifiers" do
    examples =
      Specification.document(:auth)["paths"]["/"]["post"]["requestBody"]["content"][
        "application/json"
      ]["examples"]

    subjects =
      for {_name, example} <- examples,
          subject = get_in(example, ["value", "subject"]),
          not is_nil(subject),
          do: subject

    assert subjects != []

    for wire <- subjects do
      assert {:ok, %Subject{sub_ids: [%SubjectIdentifier{}]} = subject} = Subject.from_map(wire)
      assert :ok = Subject.validate(subject)
      assert Subject.to_map(subject) == wire
      assert Jason.decode!(Jason.encode!(subject)) == wire
    end
  end

  test "requires exactly one identifier without defaulting, merging or applying naming aliases" do
    for data <- [
          %{},
          %{"sub_ids" => nil},
          %{"sub_ids" => []},
          %{"sub_ids" => @identifier},
          %{"sub_ids" => "identifier"},
          %{"sub_ids" => [@identifier, @identifier]},
          %{"subIds" => [@identifier]}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :sub_ids}]}} = Subject.from_map(data)
    end
  end

  test "prefixes malformed or incomplete identifier errors with source array indexes" do
    for {identifier, field} <- [
          {nil, "sub_ids[0]"},
          {"private-identifier", "sub_ids[0]"},
          {Map.delete(@identifier, "id"), "sub_ids[0].id"},
          {Map.put(@identifier, "format", "email"), "sub_ids[0].format"},
          {Map.put(@identifier, "id", ["private-id"]), "sub_ids[0].id"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]} = error} =
               Subject.from_map(%{"sub_ids" => [identifier]})

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "preserves JSON extensions at the subject and identifier levels" do
    wire = %{
      "sub_ids" => [Map.put(@identifier, "custom-id", %{"value" => nil})],
      "custom-subject" => [true, 1, "retained"]
    }

    assert {:ok, subject} = Subject.from_map(wire)
    assert subject.extensions == %{"custom-subject" => [true, 1, "retained"]}
    assert hd(subject.sub_ids).extensions == %{"custom-id" => %{"value" => nil}}
    assert Subject.to_map(subject) == wire
    assert Jason.decode!(Jason.encode!(subject)) == wire

    for extra <- [%{custom: true}, %{"custom" => self()}] do
      assert {:error, %Error{validation_errors: [%{field: :extensions}]}} =
               Subject.from_map(Map.merge(@subject, extra))
    end
  end

  test "revalidates modified typed identifiers, cardinality and reserved extension fields" do
    {:ok, subject} = Subject.from_map(@subject)
    [identifier] = subject.sub_ids

    for {changed, field} <- [
          {%{subject | sub_ids: []}, :sub_ids},
          {%{subject | sub_ids: [identifier, identifier]}, :sub_ids},
          {%{subject | sub_ids: [@identifier]}, "sub_ids[0]"},
          {%{subject | sub_ids: [%{identifier | format: "email"}]}, "sub_ids[0].format"},
          {%{subject | sub_ids: [%{identifier | extensions: %{"id" => "override"}}]},
           "sub_ids[0].extensions"},
          {%{subject | extensions: %{"sub_ids" => []}}, :extensions}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} = Subject.validate(changed)
    end

    assert Subject.to_map(%{subject | extensions: %{"sub_ids" => []}})["sub_ids"] == [@identifier]
  end

  test "rejects non-objects and omits subject identifiers and extensions from inspection" do
    for value <- [nil, [], false, 1, "private-input", %URI{}] do
      assert {:error, %Error{validation_errors: [%{field: :subject}]} = error} =
               Subject.from_map(value)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    wire = %{
      "sub_ids" => [%{"id" => "private-subject-id", "format" => "uri"}],
      "custom" => "private-extension"
    }

    {:ok, subject} = Subject.from_map(wire)
    refute inspect(subject) =~ "private-"
    assert Subject.to_map(subject) == wire
  end
end
