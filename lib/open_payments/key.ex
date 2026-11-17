defmodule OpenPayments.Key do
  @moduledoc """
  An Ed25519 signing key with an explicit key ID.

  `generate/1` creates a new key using OTP crypto. `from_seed/2` imports an exact
  32-byte Ed25519 seed and derives its public key. `from_pem/2` imports a single
  unencrypted Ed25519 PKCS#8 private-key entry using OTP's PEM parser.
  `from_file/2` reads PEM from a file; `from_base64_pem/2` decodes base64 PEM text.
  `from_jwk/2` imports a private Ed25519 JWK and checks its public-key consistency.
  Key IDs must be nonblank strings; their spelling is preserved, matching the
  Node SDK's public-key generator.

  Use `public_jwk/1` or `public_jwks/1` to export public data for registration with
  a wallet address server. These functions never include the private seed.

  Treat this type as opaque and construct it through these functions. Inspection
  hides key material and there is no JSON encoder for private keys. The private
  seed remains in process memory; inspection redaction is not memory protection.
  """

  alias OpenPayments.Error
  alias OpenPayments.Key.PrivateJWK
  alias OpenPayments.Types.{JWK, JWKS, Validation}

  @derive {Inspect, only: [:key_id]}
  @enforce_keys [:key_id, :public_key, :private_key]
  defstruct [:key_id, :public_key, :private_key]

  @ed25519_oid {1, 3, 101, 112}

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

  @doc """
  Imports a single unencrypted Ed25519 PKCS#8 private-key entry.

  Public-only keys, other algorithms, encrypted keys, malformed data, and bundles
  with multiple PEM entries return configuration errors. No password is accepted
  and invalid input never causes a replacement key to be generated.
  """
  @spec from_pem(binary(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_pem(pem, key_id) do
    case decode_pem(pem) do
      {:ok, seed} ->
        from_seed(seed, key_id)

      :error ->
        invalid(
          key_id_errors(key_id) ++
            [issue(:pem, "must contain one unencrypted Ed25519 PKCS#8 private-key entry")]
        )
    end
  end

  @doc """
  Reads a PEM private key from a UTF-8 file path without modifying the file.

  File-read failures return configuration errors without retaining the path.
  The contents are validated by `from_pem/2`; an import never creates or replaces
  a key file. Paths must be nonempty strings without null bytes.
  """
  @spec from_file(String.t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_file(path, key_id) do
    case read_pem_file(path) do
      {:ok, pem} ->
        from_pem(pem, key_id)

      _error ->
        invalid(key_id_errors(key_id) ++ [issue(:path, "must identify a readable PEM file")])
    end
  end

  @doc """
  Imports standard base64-encoded PEM text, as commonly stored in configuration.

  Padding is optional and ASCII whitespace is ignored. Invalid base64 returns a
  configuration issue on `base64_pem`; decoded contents use `from_pem/2` validation.
  No alternate key format is inferred from the decoded data.
  """
  @spec from_base64_pem(binary(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_base64_pem(encoded, key_id) do
    case decode_base64_pem(encoded) do
      {:ok, pem} ->
        from_pem(pem, key_id)

      :error ->
        invalid(
          key_id_errors(key_id) ++
            [issue(:base64_pem, "must be standard base64-encoded PEM text")]
        )
    end
  end

  @doc """
  Imports a private Ed25519 JWK from a JSON object with string keys.

  Requires `kty: "OKP"`, `crv: "Ed25519"`, and canonical unpadded base64url `d`
  and `x` values encoding 32 bytes each. The public value must match the seed.
  Optional `alg` and `use` must be `EdDSA` and `sig`; `key_ops`, when present,
  must permit `sign` and may also permit `verify`, without duplicates.

  The explicit `key_id` sets the exported ID. An optional JWK `kid` must be a
  string but does not override it. Other JSON metadata is accepted and discarded.
  Private JWKs are input only; public exports never include `d`.
  """
  @spec from_jwk(map(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_jwk(jwk, key_id) do
    case PrivateJWK.decode(jwk) do
      {:ok, seed, public} ->
        from_jwk_bytes(seed, public, key_id)

      {:error, errors} ->
        invalid(key_id_errors(key_id) ++ errors)
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

  @doc "Returns the explicitly configured key ID without exposing key material."
  @spec key_id(t()) :: String.t()
  def key_id(%__MODULE__{key_id: key_id}), do: key_id

  @doc false
  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{private_key: seed, public_key: public, key_id: key_id} = key) do
    with {:ok, derived} <- from_seed(seed, key_id) do
      if derived.public_key == public,
        do: {:ok, key},
        else: invalid([issue(:key, "must contain a matching Ed25519 public key and seed")])
    end
  end

  def validate(_key), do: invalid([issue(:key, "must be an Open Payments key")])

  @doc """
  Signs exact binary data with Ed25519, returning the raw signature bytes.

  This operation does not construct an HTTP signature or send a request. Signing
  failures return an error without retaining key material, input, or crypto details.
  """
  @spec sign(t(), binary()) :: {:ok, binary()} | {:error, Error.t()}
  def sign(%__MODULE__{} = key, data) when is_binary(data) do
    {:ok, :crypto.sign(:eddsa, :none, data, [key.private_key, :ed25519])}
  rescue
    _error in [ErlangError, ArgumentError] -> signing_failure()
  end

  def sign(_key, _data), do: signing_failure()

  defp signing_failure do
    {:error, %Error{kind: :signing, description: "Unable to create an Ed25519 signature"}}
  end

  defp from_jwk_bytes(seed, public, key_id) do
    with {:ok, key} <- from_seed(seed, key_id) do
      if key.public_key == public,
        do: {:ok, key},
        else: invalid([issue(:x, "must match the public key derived from d")])
    end
  end

  defp read_pem_file(path) when is_binary(path) do
    if Validation.string?(path) and path != "" and not String.contains?(path, <<0>>) do
      File.read(path)
    else
      :error
    end
  end

  defp read_pem_file(_path), do: :error

  defp decode_base64_pem(encoded) when is_binary(encoded) do
    Base.decode64(encoded, padding: false, ignore: :whitespace)
  end

  defp decode_base64_pem(_encoded), do: :error

  defp decode_pem(pem) when is_binary(pem) do
    with [{:PrivateKeyInfo, _der, :not_encrypted} = entry] <- :public_key.pem_decode(pem),
         {:ECPrivateKey, _version, seed, {:namedCurve, curve}, _public, _attributes}
         when curve in [@ed25519_oid, :ed25519] <- :public_key.pem_entry_decode(entry),
         true <- is_binary(seed) and byte_size(seed) == 32 do
      {:ok, seed}
    else
      _other -> :error
    end
  rescue
    _error -> :error
  catch
    :throw, _reason -> :error
  end

  defp decode_pem(_pem), do: :error

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
