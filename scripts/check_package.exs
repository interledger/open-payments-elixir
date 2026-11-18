defmodule PackageCheck do
  @moduledoc false

  @root Path.expand("..", __DIR__)
  @fixture Path.join(__DIR__, "package_consumer")
  @root_files ~w(mix.exs README.md LICENSE CHANGELOG.md)

  def run(args) do
    offline? =
      case args do
        [] -> false
        ["--offline"] -> true
        _ -> raise ArgumentError, "usage: elixir scripts/check_package.exs [--offline]"
      end

    directory =
      Path.join(
        System.tmp_dir!(),
        "open-payments-consumer-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(directory)

    try do
      archive = Path.join(directory, "package.tar")
      run!(["hex.build", "--output", archive], @root, environment("dev", offline?))
      unpack!(archive, Path.join(directory, "vendor/open_payments_elixir"))
      prepare_consumer!(directory)

      production = environment("prod", offline?)
      run!(["deps.get"], directory, production)
      run!(["compile", "--warnings-as-errors"], directory, production)
      run!(["run", "--no-compile", "runtime.exs"], directory, production)

      testing = environment("test", offline?)
      run!(["compile", "--warnings-as-errors"], directory, testing)
      run!(["test", "--no-compile"], directory, testing)

      IO.puts(
        "Package consumer check passed on Elixir #{System.version()}/OTP #{System.otp_release()}"
      )
    after
      File.rm_rf!(directory)
    end
  end

  defp unpack!(archive, destination) do
    {:ok, entries} = :erl_tar.extract(String.to_charlist(archive), [:memory])
    {_, compressed} = List.keyfind(entries, ~c"contents.tar.gz", 0)
    {:ok, files} = :erl_tar.extract({:binary, compressed}, [:compressed, :memory])

    for {name, contents} <- files do
      name = List.to_string(name)
      parts = Path.split(name)

      unless Path.type(name) == :relative and ".." not in parts and
               (name in @root_files or hd(parts) in ["lib", "priv"]) do
        raise "Unexpected package entry: #{name}"
      end

      target = Path.join(destination, name)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, contents)
    end
  end

  defp prepare_consumer!(directory) do
    File.mkdir_p!(Path.join(directory, "test"))

    for {source, target} <- [
          {"mix.exs", "mix.exs"},
          {"runtime.exs", "runtime.exs"},
          {"test/test_helper.exs", "test/test_helper.exs"},
          {"test/package_test.exs", "test/package_test.exs"}
        ] do
      File.cp!(Path.join(@fixture, source), Path.join(directory, target))
    end
  end

  defp environment(mode, offline?) do
    [
      {"MIX_ENV", mode},
      {"MIX_BUILD_PATH", nil},
      {"MIX_BUILD_ROOT", nil},
      {"MIX_DEPS_PATH", nil},
      {"MIX_LOCKFILE", nil},
      {"HEX_OFFLINE", if(offline?, do: "1", else: System.get_env("HEX_OFFLINE"))}
    ]
  end

  defp run!(arguments, directory, environment) do
    {_output, status} =
      System.cmd("mix", arguments,
        cd: directory,
        env: environment,
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0, do: raise("mix #{Enum.join(arguments, " ")} failed with status #{status}")
  end
end

PackageCheck.run(System.argv())
