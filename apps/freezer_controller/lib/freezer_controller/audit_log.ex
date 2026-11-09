defmodule FreezerController.AuditLog do
  @moduledoc false

  use GenServer

  @limit 200

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec record(map()) :: :ok
  def record(entry) when is_map(entry) do
    GenServer.call(__MODULE__, {:record, entry})
  end

  @spec list(pos_integer()) :: [map()]
  def list(limit \\ 50) when is_integer(limit) and limit > 0 do
    GenServer.call(__MODULE__, {:list, limit})
  end

  @impl true
  def init(_entries), do: {:ok, []}

  @impl true
  def handle_call({:record, entry}, _from, entries) do
    {:reply, :ok, Enum.take([entry | entries], @limit)}
  end

  def handle_call({:list, limit}, _from, entries) do
    {:reply, Enum.take(entries, limit), entries}
  end
end
