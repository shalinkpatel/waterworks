defmodule Ww.Message do
  @moduledoc "The transport-independent Waterworks message envelope."

  @enforce_keys [
    :id,
    :from,
    :to,
    :type,
    :payload,
    :reply_to,
    :received_at,
    :sequence
  ]
  defstruct [v: 1] ++ @enforce_keys

  @type t :: %__MODULE__{
          v: 1,
          id: String.t(),
          from: String.t(),
          to: String.t(),
          type: String.t(),
          payload: map(),
          reply_to: String.t() | nil,
          received_at: DateTime.t(),
          sequence: pos_integer()
        }
end
