defmodule OpenPayments.Specification do
  @moduledoc """
  The bundled Open Payments specification and operation inventory.

  Documents are loaded at compilation, so using the SDK does not fetch schemas
  from a server or depend on a Git submodule. `revision/0` identifies the exact
  upstream commit from which the documents were copied.
  """

  @directory Path.expand("../../priv/specifications", __DIR__)
  @external_resource Path.join(@directory, "SOURCE.json")
  @source @directory |> Path.join("SOURCE.json") |> File.read!() |> Jason.decode!()

  @servers [
    auth: "auth-server",
    resource: "resource-server",
    wallet_address: "wallet-address-server"
  ]
  @external_resource Path.join(@directory, "auth-server.json")
  @external_resource Path.join(@directory, "resource-server.json")
  @external_resource Path.join(@directory, "wallet-address-server.json")
  @documents Map.new(@servers, fn {server, filename} ->
               path = Path.join(@directory, filename <> ".json")
               {server, path |> File.read!() |> Jason.decode!()}
             end)
  @methods %{"get" => :get, "post" => :post, "delete" => :delete}
  @operations (for {server, document} <- @documents,
                   {path, operations} <- document["paths"],
                   {method, operation} <- operations,
                   Map.has_key?(@methods, method) do
                 %{
                   server: server,
                   method: Map.fetch!(@methods, method),
                   path: path,
                   id: Map.fetch!(operation, "operationId"),
                   success_statuses:
                     operation
                     |> Map.fetch!("responses")
                     |> Map.keys()
                     |> Enum.filter(&String.starts_with?(&1, "2"))
                     |> Enum.map(&String.to_integer/1)
                     |> Enum.sort()
                 }
               end)

  @type server :: :auth | :resource | :wallet_address
  @type operation :: %{
          server: server(),
          method: :get | :post | :delete,
          path: String.t(),
          id: String.t(),
          success_statuses: [pos_integer()]
        }

  @doc "The bundled specification's semantic version."
  @spec version() :: String.t()
  def version, do: @source["version"]

  @doc "The full upstream specification commit SHA."
  @spec revision() :: String.t()
  def revision, do: @source["commit"]

  @doc "Returns the bundled OpenAPI document for a server."
  @spec document(server()) :: map()
  def document(server), do: Map.fetch!(@documents, server)

  @doc "Lists supported protocol operations in stable order by operation ID."
  @spec operations() :: [operation()]
  def operations, do: Enum.sort_by(@operations, & &1.id)

  @doc "Fetches a named component schema, or returns `:error` if it is unknown."
  @spec fetch_schema(server(), String.t()) :: {:ok, map()} | :error
  def fetch_schema(server, name), do: Map.fetch(document(server)["components"]["schemas"], name)
end
