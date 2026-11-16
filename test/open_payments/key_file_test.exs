defmodule OpenPayments.KeyFileTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Key}
  alias OpenPayments.Types.JWK

  @fixtures File.read!(Path.expand("../fixtures/keys/node-pem.json", __DIR__)) |> Jason.decode!()

  setup do
    directory =
      Path.join(System.tmp_dir!(), "open-payments-key-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  test "loads an existing key without changing contents, metadata or directory entries",
       context do
    path = Path.join(context.directory, "private key α.pem")
    File.write!(path, @fixtures["ed25519"])
    File.chmod!(path, 0o600)
    before = File.stat!(path)

    assert {:ok, key} = Key.from_file(path, "key-1")
    expected = Map.merge(@fixtures["public_jwk"], %{"kid" => "key-1", "alg" => "EdDSA"})
    assert key |> Key.public_jwk() |> JWK.to_map() == expected
    assert File.read!(path) == @fixtures["ed25519"]

    after_read = File.stat!(path)

    assert Map.take(after_read, [:mtime, :ctime, :mode, :size]) ==
             Map.take(before, [:mtime, :ctime, :mode, :size])

    assert File.ls!(context.directory) == [Path.basename(path)]
  end

  test "missing files and directories return configuration errors without creating files",
       context do
    path = Path.join(context.directory, "missing-private-key.pem")

    for input <- [path, context.directory] do
      assert {:error, %Error{kind: :configuration, validation_errors: [%{field: :path}]}} =
               Key.from_file(input, "key-1")
    end

    refute File.exists?(path)
    assert File.ls!(context.directory) == []
  end

  test "retains all PEM validation rules without repairing or replacing a file", context do
    path = Path.join(context.directory, "key.pem")

    for pem <- [
          "invalid-private-key",
          @fixtures["ed448"],
          @fixtures["x25519"],
          @fixtures["rsa"],
          @fixtures["ed25519_public"],
          @fixtures["ed25519_encrypted"],
          @fixtures["ed25519"] <> @fixtures["ed25519"]
        ] do
      File.write!(path, pem)

      assert {:error, %Error{kind: :configuration, validation_errors: [%{field: :pem}]}} =
               Key.from_file(path, "key-1")

      assert File.read!(path) == pem
      assert File.ls!(context.directory) == ["key.pem"]
    end
  end

  test "rejects invalid paths without raising" do
    for path <- [nil, false, 1, [], ~c"key.pem", %{}, "", "key\0.pem", <<255>>] do
      assert {:error, %Error{kind: :configuration, validation_errors: [%{field: :path}]}} =
               Key.from_file(path, "key-1")
    end
  end

  test "validates key IDs and preserves accepted spelling", context do
    path = Path.join(context.directory, "key.pem")
    File.write!(path, @fixtures["ed25519"])

    for id <- [nil, "", "\t\n", 123, <<255>>] do
      assert {:error, %Error{validation_errors: [%{field: :key_id}]}} = Key.from_file(path, id)
    end

    assert {:ok, key} = Key.from_file(path, "  key-α  ")
    assert Key.public_jwk(key).kid == "  key-α  "
  end

  test "aggregates issues without retaining paths or private contents", context do
    path = Path.join(context.directory, "private-file-path-must-not-leak.pem")
    assert {:error, %Error{validation_errors: issues} = error} = Key.from_file(path, nil)
    assert Enum.map(issues, & &1.field) == [:key_id, :path]
    assert error.details == nil
    refute inspect(Map.from_struct(error)) =~ "private-file-path-must-not-leak"

    File.write!(path, "private-file-contents-must-not-leak")
    assert {:error, error} = Key.from_file(path, "key-1")
    refute inspect(Map.from_struct(error)) =~ "private-file-contents-must-not-leak"
    refute Exception.message(error) =~ "private-file-path-must-not-leak"
  end
end
