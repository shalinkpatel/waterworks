defmodule Ww.Endpoint do
  @moduledoc "A registered agent or tool instance."

  @enforce_keys [:id, :kind, :name, :accepts, :emits, :metadata, :token_hash, :created_at]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          kind: String.t(),
          name: String.t(),
          accepts: [String.t()],
          emits: [String.t()],
          metadata: map(),
          token_hash: binary(),
          created_at: DateTime.t()
        }

  def public(%__MODULE__{} = endpoint) do
    endpoint
    |> Map.take([:id, :kind, :name, :accepts, :emits, :metadata, :created_at])
    |> Map.put(:online, online?(endpoint.id))
  end

  def online?(id), do: :pg.get_members(:ww, {:endpoint, id}) != []
end
