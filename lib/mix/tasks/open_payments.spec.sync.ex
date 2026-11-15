defmodule Mix.Tasks.OpenPayments.Spec.Sync do
  @shortdoc "Syncs bundled Open Payments specifications from an exact upstream commit"
  @moduledoc """
  Updates the bundled documents from the shared Open Payments Specifications repo.

      mix open_payments.spec.sync --ref FULL_COMMIT_SHA

  Use an existing local checkout to work without network access:

      mix open_payments.spec.sync --ref FULL_COMMIT_SHA --source /path/to/specifications

  Add `--check` to verify the bundled documents without writing changes. The ref
  must be a full 40-character commit SHA. Updates preserve the original JSON bytes
  and record the version, revision, and SHA-256 checksums in `SOURCE.json`.

  Review specification changes and update affected types, validators, and tests
  before committing the updated documents. This task does not generate a client
  or establish compatibility with new operations automatically.
  """

  use Mix.Task

  @repository "https://github.com/interledger/open-payments-specifications"
  @filenames ~w(auth-server.json resource-server.json wallet-address-server.json)

  @impl true
  def run(args), do: run(args, &System.cmd/3)

  @doc false
  def run(args, command) do
    {opts, rest} =
      OptionParser.parse!(args,
        strict: [ref: :string, source: :string, destination: :string, check: :boolean]
      )

    if rest != [], do: Mix.raise("Unexpected arguments: #{Enum.join(rest, " ")}")
    revision = Keyword.get(opts, :ref, "")

    unless Regex.match?(~r/\A[0-9a-f]{40}\z/, revision) do
      Mix.raise("--ref must be a full lowercase 40-character commit SHA")
    end

    destination = Keyword.get(opts, :destination, "priv/specifications")

    case Keyword.fetch(opts, :source) do
      {:ok, source} -> sync(source, revision, destination, opts[:check] == true, command)
      :error -> with_checkout(revision, destination, opts[:check] == true, command)
    end
  end

  defp with_checkout(revision, destination, check?, command) do
    directory =
      Path.join(System.tmp_dir!(), "open-payments-spec-#{System.unique_integer([:positive])}")

    try do
      git!(
        ["clone", "--filter=blob:none", "--no-checkout", @repository <> ".git", directory],
        command
      )

      sync(directory, revision, destination, check?, command)
    after
      File.rm_rf!(directory)
    end
  end

  defp sync(source, revision, destination, check?, command) do
    resolved = git!(["-C", source, "rev-parse", "--verify", revision <> "^{commit}"], command)
    unless String.trim(resolved) == revision, do: Mix.raise("Specification revision mismatch")

    files =
      Map.new(@filenames, fn filename ->
        contents = git!(["-C", source, "show", "#{revision}:json/#{filename}"], command)
        {filename, contents}
      end)

    sync_files(files, revision, destination, check?)
  end

  @doc false
  def sync_files(files, revision, destination, check?) do
    unless Enum.sort(Map.keys(files)) == Enum.sort(@filenames) do
      Mix.raise("The bundle must contain all three Open Payments API documents")
    end

    version = validate_documents!(files)

    metadata = %{
      "repository" => @repository,
      "commit" => revision,
      "version" => version,
      "license" => "Apache-2.0",
      "files" => @filenames,
      "sha256" => Map.new(files, fn {name, body} -> {name, checksum(body)} end)
    }

    files = Map.put(files, "SOURCE.json", Jason.encode!(metadata, pretty: true) <> "\n")

    if check? do
      check_files!(files, destination)
      Mix.shell().info("Bundled specifications match #{revision} (#{version}).")
    else
      File.mkdir_p!(destination)
      Enum.each(files, fn {name, body} -> File.write!(Path.join(destination, name), body) end)
      Mix.shell().info("Synced specifications #{version} at #{revision}.")
    end
  end

  defp validate_documents!(files) do
    versions =
      Enum.map(files, fn {name, body} ->
        document = Jason.decode!(body)

        unless document["openapi"] == "3.1.0" and is_map(document["paths"]) and
                 is_map(document["components"]["schemas"]) do
          Mix.raise("Invalid OpenAPI 3.1 specification: #{name}")
        end

        document["info"]["version"]
      end)

    case Enum.uniq(versions) do
      [version] when is_binary(version) ->
        case Version.parse(version) do
          {:ok, _} -> version
          :error -> Mix.raise("Specification version must be a semantic version")
        end

      _ ->
        Mix.raise("All specification documents must declare the same version")
    end
  end

  defp check_files!(files, destination) do
    changed =
      for {name, body} <- files, File.read(Path.join(destination, name)) != {:ok, body}, do: name

    if changed != [] do
      Mix.raise("Bundled specifications differ: #{Enum.join(Enum.sort(changed), ", ")}")
    end
  end

  defp checksum(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp git!(args, command) do
    # Keep stderr separate so Git diagnostics never become part of a JSON artifact.
    case command.("git", args, stderr_to_stdout: false) do
      {output, 0} ->
        output

      {_output, _status} ->
        Mix.raise("Could not read the requested specification revision with Git")
    end
  end
end
