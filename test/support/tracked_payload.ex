defmodule OpenPayments.Test.TrackedPayload do
  @moduledoc false
  defstruct [:recipient, :value]
end

defimpl Jason.Encoder, for: OpenPayments.Test.TrackedPayload do
  def encode(payload, opts) do
    send(payload.recipient, :payload_encoded)

    if payload.value == :raise,
      do: raise(ArgumentError, "private-payload-must-not-leak"),
      else: Jason.Encode.map(%{"message" => payload.value}, opts)
  end
end
