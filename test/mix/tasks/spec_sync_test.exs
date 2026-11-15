defmodule Mix.Tasks.OpenPayments.Spec.SyncTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.OpenPayments.Spec.Sync

  @revision String.duplicate("a", 40)

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "open-payments-sync-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(directory) end)

    files =
      Map.new(~w(auth-server resource-server wallet-address-server), fn name ->
        document = %{
          "openapi" => "3.1.0",
          "info" => %{"version" => "1.5.0"},
          "paths" => %{},
          "components" => %{"schemas" => %{}}
        }

        {name <> ".json", Jason.encode!(document)}
      end)

    %{directory: directory, files: files}
  end

  test "writes exact source bytes and provenance, then verifies without changes", context do
    assert capture_io(fn ->
             Sync.sync_files(context.files, @revision, context.directory, false)
           end) =~
             "Synced specifications 1.5.0"

    for {name, expected} <- context.files do
      assert File.read!(Path.join(context.directory, name)) == expected
    end

    source = context.directory |> Path.join("SOURCE.json") |> File.read!() |> Jason.decode!()
    assert source["commit"] == @revision
    assert map_size(source["sha256"]) == 3

    assert capture_io(fn ->
             Sync.sync_files(context.files, @revision, context.directory, true)
           end) =~
             "Bundled specifications match"
  end

  test "check mode detects a changed file and does not repair it", context do
    capture_io(fn -> Sync.sync_files(context.files, @revision, context.directory, false) end)
    path = Path.join(context.directory, "resource-server.json")
    File.write!(path, "changed")

    assert_raise Mix.Error, ~r/resource-server.json/, fn ->
      Sync.sync_files(context.files, @revision, context.directory, true)
    end

    assert File.read!(path) == "changed"
  end

  test "rejects mixed specification versions before writing any files", context do
    changed =
      context.files["auth-server.json"]
      |> Jason.decode!()
      |> put_in(["info", "version"], "1.4.0")
      |> Jason.encode!()

    files = Map.put(context.files, "auth-server.json", changed)

    assert_raise Mix.Error, ~r/same version/, fn ->
      Sync.sync_files(files, @revision, context.directory, false)
    end

    refute File.exists?(context.directory)
  end

  test "rejects incomplete bundles before writing", context do
    assert_raise Mix.Error, ~r/all three/, fn ->
      Sync.sync_files(
        Map.delete(context.files, "auth-server.json"),
        @revision,
        context.directory,
        false
      )
    end

    refute File.exists?(context.directory)
  end

  test "requires an exact commit before accessing the network" do
    for args <- [[], ["--ref", "main"]] do
      assert_raise Mix.Error, fn -> Sync.run(args) end
    end

    assert_raise OptionParser.ParseError, fn -> Sync.run(["--ref", "--help"]) end
  end

  test "rejects positional arguments" do
    assert_raise Mix.Error, ~r/Unexpected arguments/, fn ->
      Sync.run(["--ref", @revision, "unexpected"])
    end
  end

  test "reads all three artifacts at the exact revision from a local checkout", context do
    command = git_reader(context.files)

    capture_io(fn ->
      Sync.run(
        [
          "--ref",
          @revision,
          "--source",
          "local-specifications",
          "--destination",
          context.directory
        ],
        command
      )
    end)

    assert_received {:git, ["-C", "local-specifications", "rev-parse", "--verify", revision]}
    assert revision == @revision <> "^{commit}"

    for filename <- Map.keys(context.files) do
      assert_received {:git, ["-C", "local-specifications", "show", object]}
      assert String.starts_with?(object, @revision <> ":json/")
      assert File.exists?(Path.join(context.directory, filename))
    end
  end

  test "uses the shared repository and removes its temporary checkout", context do
    reader = git_reader(context.files)

    command = fn "git", args, options ->
      case args do
        ["clone", "--filter=blob:none", "--no-checkout", repository, checkout] ->
          assert repository == "https://github.com/interledger/open-payments-specifications.git"
          File.mkdir_p!(checkout)
          send(self(), {:checkout, checkout})
          {"", 0}

        _ ->
          reader.("git", args, options)
      end
    end

    capture_io(fn ->
      Sync.run(["--ref", @revision, "--destination", context.directory], command)
    end)

    assert_received {:checkout, checkout}
    refute File.exists?(checkout)
  end

  test "a failed Git command does not write a bundle", context do
    command = fn "git", _args, _opts -> {"diagnostic output", 1} end

    assert_raise Mix.Error, ~r/Could not read/, fn ->
      Sync.run(
        ["--ref", @revision, "--source", "local", "--destination", context.directory],
        command
      )
    end

    refute File.exists?(context.directory)
  end

  test "a different resolved revision does not write a bundle", context do
    command = fn "git", _args, _opts -> {String.duplicate("b", 40), 0} end

    assert_raise Mix.Error, ~r/revision mismatch/, fn ->
      Sync.run(
        ["--ref", @revision, "--source", "local", "--destination", context.directory],
        command
      )
    end

    refute File.exists?(context.directory)
  end

  test "rejects invalid OpenAPI documents before writing", context do
    files = Map.put(context.files, "auth-server.json", ~s({"openapi":"3.0.0"}))

    assert_raise Mix.Error, ~r/Invalid OpenAPI/, fn ->
      Sync.sync_files(files, @revision, context.directory, false)
    end

    refute File.exists?(context.directory)
  end

  test "rejects invalid semantic versions before writing", context do
    files =
      Map.new(context.files, fn {name, body} ->
        {name, String.replace(body, "1.5.0", "invalid")}
      end)

    assert_raise Mix.Error, ~r/semantic version/, fn ->
      Sync.sync_files(files, @revision, context.directory, false)
    end

    refute File.exists?(context.directory)
  end

  defp git_reader(files) do
    fn "git", args, [stderr_to_stdout: false] ->
      send(self(), {:git, args})

      case args do
        ["-C", _source, "rev-parse", "--verify", revision] ->
          assert revision == @revision <> "^{commit}"
          {@revision <> "\n", 0}

        ["-C", _source, "show", object] ->
          prefix = @revision <> ":json/"
          assert String.starts_with?(object, prefix)
          filename = String.replace_prefix(object, prefix, "")
          {Map.fetch!(files, filename), 0}
      end
    end
  end
end
