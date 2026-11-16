defmodule OpenPayments.Key.PrivateJWK do
  @moduledoc false

  alias OpenPayments.Error
  alias OpenPayments.Types.Validation

  @fields ~w(kty crv x d alg use key_ops kid)

  @spec decode(term()) :: {:ok, binary(), binary()} | {:error, [Error.validation_issue()]}
  def decode(data) when is_map(data) and not is_struct(data) do
    seed = decode_bytes(Map.get(data, "d"))
    public = decode_bytes(Map.get(data, "x"))

    errors =
      [
        {data["kty"] == "OKP", :kty, "must be OKP"},
        {data["crv"] == "Ed25519", :crv, "must be Ed25519"},
        {not is_nil(seed), :d, "must encode 32 bytes using canonical unpadded base64url"},
        {not is_nil(public), :x, "must encode 32 bytes using canonical unpadded base64url"},
        {not Map.has_key?(data, "alg") or data["alg"] == "EdDSA", :alg,
         "must be EdDSA when present"},
        {not Map.has_key?(data, "use") or data["use"] == "sig", :use, "must be sig when present"},
        {not Map.has_key?(data, "key_ops") or signing_operations?(data["key_ops"]), :key_ops,
         "must permit sign, optionally verify, without duplicate or other operations"},
        {not Map.has_key?(data, "kid") or Validation.string?(data["kid"]), :kid,
         "must be a string when present"},
        {Validation.extensions?(Map.drop(data, @fields), []), :jwk,
         "additional metadata must be JSON values with string keys"}
      ]
      |> Enum.flat_map(fn
        {true, _field, _message} -> []
        {false, field, message} -> [issue(field, message)]
      end)

    case errors do
      [] -> {:ok, seed, public}
      errors -> {:error, errors}
    end
  end

  def decode(_data), do: {:error, [issue(:jwk, "must be a JSON object")]}

  defp decode_bytes(encoded) when is_binary(encoded) do
    with {:ok, bytes} <- Base.url_decode64(encoded, padding: false),
         true <- byte_size(bytes) == 32,
         ^encoded <- Base.url_encode64(bytes, padding: false) do
      bytes
    else
      _other -> nil
    end
  end

  defp decode_bytes(_encoded), do: nil

  defp signing_operations?(operations) do
    operations in [["sign"], ["sign", "verify"], ["verify", "sign"]]
  end

  defp issue(field, message), do: %{field: field, message: message}
end
