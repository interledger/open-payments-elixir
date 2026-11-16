defmodule OpenPayments.Types.WalletAddress do
  @moduledoc """
  Public wallet information returned by the wallet address server.

  `from_map/1` decodes and validates a JSON object using the bundled wallet-address
  schema. Known fields use snake_case in Elixir and their protocol names in JSON.
  Additional fields are preserved in `extensions`.

  An omitted `publicName` becomes `public_name: nil` and is omitted on encoding.
  An explicit JSON null is rejected because the schema requires a string when
  this optional field is present.

  URI fields follow the shared schema's `uri` format and are preserved without
  rewriting paths, ports, queries, or fragments. This response type follows the
  Node SDK's separation between response data and request handling. HTTP and HTTPS
  data, including local development endpoints, can be decoded without an option.

  Decoding a response does not verify that its URIs are safe or suitable request
  targets. HTTPS policy and wallet discovery URL rules belong to the client. This
  type makes no requests.

  These fields describe a server response and require absolute URIs. Payment-pointer
  shorthand such as `$wallet.example/alice` belongs to discovery input and must
  be converted to a URL before requesting wallet information.

  Struct literals can bypass constructor checks. Call `validate/1` before using
  a manually constructed or modified wallet; `to_map/1` only converts its shape.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.Validation

  @enforce_keys [:id, :asset_code, :asset_scale, :auth_server, :resource_server]
  defstruct [
    :id,
    :asset_code,
    :asset_scale,
    :auth_server,
    :resource_server,
    :public_name,
    extensions: %{}
  ]

  @wire_fields ~w(id assetCode assetScale authServer resourceServer publicName)

  @type t :: %__MODULE__{
          id: String.t(),
          asset_code: String.t(),
          asset_scale: 0..255,
          auth_server: String.t(),
          resource_server: String.t(),
          public_name: String.t() | nil,
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Decodes a wallet-address JSON object and validates its required fields."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    wallet = %__MODULE__{
      id: Map.get(data, "id"),
      asset_code: Map.get(data, "assetCode"),
      asset_scale: Map.get(data, "assetScale"),
      auth_server: Map.get(data, "authServer"),
      resource_server: Map.get(data, "resourceServer"),
      public_name: Map.get(data, "publicName"),
      extensions: Map.drop(data, @wire_fields)
    }

    case validate_fields(wallet, Map.has_key?(data, "publicName")) do
      :ok -> {:ok, wallet}
      {:error, error} -> {:error, error}
    end
  end

  def from_map(_data), do: invalid([issue(:wallet_address, "must be a JSON object")])

  @doc "Validates a struct, treating a nil public name as omitted."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = wallet) do
    validate_fields(wallet, not is_nil(wallet.public_name))
  end

  @doc "Converts a wallet to JSON field names without validating it."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = wallet) do
    fields = %{
      "id" => wallet.id,
      "assetCode" => wallet.asset_code,
      "assetScale" => wallet.asset_scale,
      "authServer" => wallet.auth_server,
      "resourceServer" => wallet.resource_server
    }

    fields =
      if is_nil(wallet.public_name),
        do: fields,
        else: Map.put(fields, "publicName", wallet.public_name)

    wallet.extensions |> Map.drop(@wire_fields) |> Map.merge(fields)
  end

  defp validate_fields(wallet, public_name_present?) do
    errors =
      [
        {Validation.absolute_uri?(wallet.id), :id, "must be an absolute URI"},
        {Validation.string?(wallet.asset_code), :asset_code, "must be a string"},
        {Validation.asset_scale?(wallet.asset_scale), :asset_scale,
         "must be an integer between 0 and 255"},
        {Validation.absolute_uri?(wallet.auth_server), :auth_server, "must be an absolute URI"},
        {Validation.absolute_uri?(wallet.resource_server), :resource_server,
         "must be an absolute URI"},
        {not public_name_present? or Validation.string?(wallet.public_name), :public_name,
         "must be a string when present"},
        {Validation.extensions?(wallet.extensions, @wire_fields), :extensions,
         "must be a JSON object with string keys and no reserved wallet fields"}
      ]
      |> Enum.flat_map(fn
        {true, _field, _message} -> []
        {false, field, message} -> [issue(field, message)]
      end)

    if errors == [], do: :ok, else: invalid(errors)
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors) do
    {:error,
     %Error{
       kind: :validation,
       description: "Invalid Open Payments wallet address",
       validation_errors: errors
     }}
  end
end

defimpl Jason.Encoder, for: OpenPayments.Types.WalletAddress do
  def encode(wallet, opts) do
    wallet |> OpenPayments.Types.WalletAddress.to_map() |> Jason.Encode.map(opts)
  end
end
