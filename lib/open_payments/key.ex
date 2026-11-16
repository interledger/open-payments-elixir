defmodule OpenPayments.Key do
  @moduledoc """
  An Ed25519 signing key with an explicit key ID.

  `generate/1` creates a new key using OTP crypto. `from_seed/2` imports an exact
  32-byte Ed25519 seed and derives its public key. Key IDs must be nonblank strings;
  their spelling is preserved, matching the Node SDK's public-key generator.

  Use `public_jwk/1` or `public_jwks/1` to export public data for registration with
  a wallet address server. These functions never include the private seed.

  Treat this type as opaque and construct it through these functions. Inspection
  hides key material and there is no JSON encoder for private keys. The private
  seed remains in process memory; inspection redaction is not memory protection.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{JWK, JWKS, Validation}

  @derive {Inspect, only: [:key_id]}
  @enforce_keys [:key_id, :public_key, :private_key]
  defstruct [:key_id, :public_key, :private_key]

  @opaque t :: %__MODULE__{
            key_id: String.t(),
            public_key: <<_::256>>,
            private_key: <<_::256>>
          }

  @doc "Generates a new Ed25519 signing key using OTP crypto."
  @spec generate(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def generate(key_id) do
    case key_id_errors(key_id) do
      [] -> derive_key(:undefined, key_id)
      errors -> invalid(errors)
    end
  end

  @doc "Imports a raw 32-byte Ed25519 seed, deriving its public key."
  @spec from_seed(binary(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_seed(seed, key_id) do
    seed_errors =
      if is_binary(seed) and byte_size(seed) == 32,
        do: [],
        else: [issue(:seed, "must be a raw 32-byte Ed25519 seed")]

    case key_id_errors(key_id) ++ seed_errors do
      [] -> derive_key(seed, key_id)
      errors -> invalid(errors)
    end
  end

  @doc "Exports the public key as a typed Open Payments JWK."
  @spec public_jwk(t()) :: JWK.t()
  def public_jwk(%__MODULE__{} = key) do
    %JWK{
      kid: key.key_id,
      alg: "EdDSA",
      kty: "OKP",
      crv: "Ed25519",
      x: Base.url_encode64(key.public_key, padding: false)
    }
  end

  @doc "Exports the public key in a typed Open Payments JWKS document."
  @spec public_jwks(t()) :: JWKS.t()
  def public_jwks(%__MODULE__{} = key), do: %JWKS{keys: [public_jwk(key)]}

  defp derive_key(seed, key_id) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519, seed)
    {:ok, %__MODULE__{key_id: key_id, public_key: public, private_key: private}}
  rescue
    _error in [ErlangError, ArgumentError] ->
      {:error,
       %Error{kind: :configuration, description: "Unable to generate an Ed25519 signing key"}}
  end

  defp key_id_errors(key_id) do
    if Validation.string?(key_id) and String.trim(key_id) != "",
      do: [],
      else: [issue(:key_id, "must be a nonblank string")]
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors) do
    {:error,
     %Error{
       kind: :configuration,
       description: "Invalid Open Payments signing key",
       validation_errors: errors
     }}
  end
end
