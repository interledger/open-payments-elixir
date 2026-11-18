defmodule OpenPayments.Interaction do
  @moduledoc """
  Pure SHA-256 helpers for an interaction finish callback hash.

  Supply stored `client_nonce`, stored `server_nonce` (the initial response's
  `interact.finish`), callback `interact_ref` and the initial `grant_endpoint` as
  keyword options. The four ASCII values are joined in that order with single
  newline separators and no trailing newline. URI spelling is preserved: use the
  exact grant endpoint used for initiation, not a callback or continuation URI.

  Default `encoding: :base64` uses canonical padded Base64, matching the deployed
  Open Payments implementation and its JavaScript documentation example.
  Explicit `encoding: :base64url` uses canonical unpadded base64url from GNAP
  RFC 9635 section 4.2.3. There is no format detection or fallback. Only SHA-256
  is supported; do not negotiate another hash method for use with these helpers.

  Callback inputs are deliberately stricter than the general JSON data codecs:
  nonces/reference must be nonempty printable ASCII without leading/trailing
  whitespace. Internal spaces are preserved. Controls and non-ASCII values are
  rejected rather than converted. Endpoint must be an absolute HTTP(S) request
  URL without user-info/fragment; validation does not normalize its hash input.

  The caller binds these values to the correct session, generates fresh
  unpredictable client nonces, checks callback result/error fields and prevents
  replay. These helpers perform no HTTP requests, session management, entropy
  assessment, waiting or automatic continuation. A matching hash does not itself
  establish granted access. Errors retain safe field names, not input values.
  """

  alias OpenPayments.Error
  alias OpenPayments.Request.URL

  @fields ~w(client_nonce server_nonce interact_ref)a
  @options @fields ++ [:grant_endpoint, :encoding]

  @type hash_options :: [
          {:client_nonce, String.t()}
          | {:server_nonce, String.t()}
          | {:interact_ref, String.t()}
          | {:grant_endpoint, String.t()}
          | {:encoding, :base64 | :base64url}
        ]

  @doc "Calculates an interaction callback hash using SHA-256 and an explicit encoding profile."
  @spec hash(hash_options()) :: {:ok, String.t()} | {:error, Error.t()}
  def hash(opts) do
    with {:ok, opts} <- options(opts) do
      base = Enum.map_join(@fields ++ [:grant_endpoint], "\n", &Keyword.fetch!(opts, &1))
      {:ok, encode(:crypto.hash(:sha256, base), opts[:encoding])}
    end
  end

  @doc """
  Verifies a canonical callback hash against the supplied stored interaction context.

  Returns `:ok` on a match, otherwise a validation error with operation
  `:verify_interaction_hash`. Equal-length canonical hash strings are compared
  using OTP's `:crypto.hash_equals/2`. Received hash must already be extracted and
  URL-decoded once by the caller's callback handler; no decoding is performed here.
  Only submit `interact_ref` to continuation after verification succeeds.
  """
  @spec verify_hash(String.t(), hash_options()) :: :ok | {:error, Error.t()}
  def verify_hash(received, opts) do
    with {:ok, expected} <- hash(opts),
         :ok <- hash_format(received, Keyword.get(opts, :encoding, :base64)) do
      if :crypto.hash_equals(expected, received),
        do: :ok,
        else:
          invalid(
            :verify_interaction_hash,
            [issue(:hash, "does not match the interaction context")],
            "invalid_interaction_hash"
          )
    else
      {:error, error} -> {:error, %{error | operation: :verify_interaction_hash}}
    end
  end

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and length(Enum.uniq(Keyword.keys(opts))) == length(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in @options)) do
      opts |> Keyword.put_new(:encoding, :base64) |> validate_options()
    else
      invalid(:calculate_interaction_hash, [
        issue(:options, "must be a keyword list of unique supported options")
      ])
    end
  end

  defp options(_opts),
    do: invalid(:calculate_interaction_hash, [issue(:options, "must be a keyword list")])

  defp validate_options(opts) do
    errors =
      Enum.flat_map(@fields, fn field ->
        if component?(opts[field]),
          do: [],
          else: [
            issue(
              field,
              "must be nonempty printable ASCII without leading or trailing whitespace"
            )
          ]
      end)

    checks = [
      {match?({:ok, _}, URL.prepare(opts[:grant_endpoint], true)), :grant_endpoint,
       "must be an absolute HTTP(S) request URL without user-info or fragment and with a valid port"},
      {opts[:encoding] in [:base64, :base64url], :encoding, "must be base64 or base64url"}
    ]

    errors =
      errors ++
        Enum.flat_map(checks, fn
          {true, _field, _message} -> []
          {false, field, message} -> [issue(field, message)]
        end)

    case errors do
      [] -> {:ok, opts}
      errors -> invalid(:calculate_interaction_hash, errors)
    end
  end

  defp component?(value) when is_binary(value),
    do: Regex.match?(~r/\A[\x20-\x7E]+\z/, value) and value == String.trim(value)

  defp component?(_value), do: false

  defp hash_format(value, encoding) do
    size = if encoding == :base64, do: 44, else: 43

    if is_binary(value) and byte_size(value) == size and canonical_hash?(value, encoding),
      do: :ok,
      else:
        invalid(:verify_interaction_hash, [
          issue(:hash, "must be a canonical SHA-256 hash in the selected encoding")
        ])
  end

  defp canonical_hash?(value, encoding) do
    decoded =
      case encoding do
        :base64 -> Base.decode64(value)
        :base64url -> Base.url_decode64(value, padding: false)
      end

    case decoded do
      {:ok, digest} -> byte_size(digest) == 32 and encode(digest, encoding) == value
      :error -> false
    end
  end

  defp encode(digest, :base64), do: Base.encode64(digest)
  defp encode(digest, :base64url), do: Base.url_encode64(digest, padding: false)
  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(operation, errors, code \\ nil),
    do:
      {:error,
       %Error{
         kind: :validation,
         operation: operation,
         code: code,
         description: "Invalid Open Payments interaction hash",
         validation_errors: errors
       }}
end
