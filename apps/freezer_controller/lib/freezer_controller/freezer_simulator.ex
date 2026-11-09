defmodule FreezerController.FreezerSimulator do
  @moduledoc false

  use GenServer

  alias FreezerController.Freezer

  @tick_ms 1_000
  @default_speed 5.0
  @min_target_c -40.0
  @max_target_c 60.0

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec list() :: {:ok, [map()]}
  def list, do: GenServer.call(__MODULE__, :list)

  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(id), do: GenServer.call(__MODULE__, {:get, id})

  @spec set_target(String.t(), number()) ::
          {:ok, map()} | {:error, :not_found | :invalid_target}
  def set_target(id, target_c), do: GenServer.call(__MODULE__, {:set_target, id, target_c})

  @spec start_defrost(String.t()) :: {:ok, map()} | {:error, :not_found}
  def start_defrost(id), do: GenServer.call(__MODULE__, {:start_defrost, id})

  @spec stop_defrost(String.t()) :: {:ok, map()} | {:error, :not_found}
  def stop_defrost(id), do: GenServer.call(__MODULE__, {:stop_defrost, id})

  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_opts) do
    state = %{
      freezers: initial_freezers(),
      speed: env_float("SIM_SPEED", @default_speed),
      last_tick_ms: now_ms()
    }

    Process.send_after(self(), :tick, @tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, {:ok, snapshots(state.freezers)}, state}
  end

  def handle_call({:get, id}, _from, state) do
    case Map.fetch(state.freezers, id) do
      {:ok, freezer} -> {:reply, {:ok, Freezer.snapshot(freezer)}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:set_target, id, target_c}, _from, state) do
    with true <- valid_target?(target_c),
         {:ok, freezer} <- Map.fetch(state.freezers, id) do
      freezer = %{
        freezer
        | target_c: target_c * 1.0,
          mode: :cooling,
          last_changed_at_ms: wall_ms()
      }

      {:reply, {:ok, Freezer.snapshot(freezer)}, put_freezer(state, freezer)}
    else
      false -> {:reply, {:error, :invalid_target}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:start_defrost, id}, _from, state) do
    update_freezer(state, id, fn freezer ->
      %{freezer | mode: :defrost, last_changed_at_ms: wall_ms()}
    end)
  end

  def handle_call({:stop_defrost, id}, _from, state) do
    update_freezer(state, id, fn freezer ->
      %{
        freezer
        | mode: :cooling,
          target_c: default_target(freezer.kind),
          last_changed_at_ms: wall_ms()
      }
    end)
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | freezers: initial_freezers(), last_tick_ms: now_ms()}}
  end

  @impl true
  def handle_info(:tick, state) do
    now = now_ms()

    freezers =
      Map.new(state.freezers, fn {id, freezer} -> {id, step(freezer, state.speed, now)} end)

    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, %{state | freezers: freezers, last_tick_ms: now}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp update_freezer(state, id, fun) do
    case Map.fetch(state.freezers, id) do
      {:ok, freezer} ->
        freezer = fun.(freezer)
        {:reply, {:ok, Freezer.snapshot(freezer)}, put_freezer(state, freezer)}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp put_freezer(state, freezer) do
    %{state | freezers: Map.put(state.freezers, freezer.id, freezer)}
  end

  defp step(freezer, speed, now) do
    target = target_for(freezer)
    max_step = max_step_for(freezer.mode) * speed
    delta = target - freezer.current_c

    current_c =
      if abs(delta) <= max_step do
        target
      else
        freezer.current_c + if(delta > 0, do: max_step, else: -max_step)
      end

    {alarm, at_risk_since} = alarm_for(freezer, current_c, now)

    %{
      freezer
      | current_c: current_c,
        alarm: alarm,
        at_risk_since: at_risk_since
    }
  end

  defp target_for(%Freezer{mode: :defrost}), do: 30.0
  defp target_for(%Freezer{mode: :off}), do: 20.0
  defp target_for(%Freezer{mode: :cooling, target_c: target_c}), do: target_c

  defp max_step_for(:defrost), do: 1.5
  defp max_step_for(:off), do: 0.2
  defp max_step_for(:cooling), do: 0.35

  defp alarm_for(freezer, current_c, now) do
    out_of_range? = current_c > freezer.safe_max_c or current_c < freezer.safe_min_c

    cond do
      not out_of_range? ->
        {:ok, nil}

      is_nil(freezer.at_risk_since) ->
        {:ok, now}

      now - freezer.at_risk_since >= 30_000 and current_c > freezer.safe_max_c + 5.0 ->
        {:spoiled, freezer.at_risk_since}

      now - freezer.at_risk_since >= 10_000 ->
        {:at_risk, freezer.at_risk_since}

      true ->
        {:ok, freezer.at_risk_since}
    end
  end

  defp snapshots(freezers) do
    freezers
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&Freezer.snapshot/1)
  end

  defp valid_target?(target_c) do
    is_number(target_c) and target_c >= @min_target_c and target_c <= @max_target_c
  end

  defp default_target(:frozen), do: -18.0
  defp default_target(:chilled), do: 4.0

  defp initial_freezers do
    [
      %Freezer{
        id: "FZ-01",
        name: "Frozen aisle 1",
        kind: :frozen,
        current_c: -18.0,
        target_c: -18.0,
        safe_min_c: -25.0,
        safe_max_c: -15.0,
        stock_value_eur: 15_000
      },
      %Freezer{
        id: "FZ-02",
        name: "Chilled aisle 1",
        kind: :chilled,
        current_c: 3.5,
        target_c: 4.0,
        safe_min_c: 0.0,
        safe_max_c: 6.0,
        stock_value_eur: 8_500
      },
      %Freezer{
        id: "FZ-03",
        name: "Frozen aisle 2",
        kind: :frozen,
        current_c: -19.2,
        target_c: -18.0,
        safe_min_c: -25.0,
        safe_max_c: -15.0,
        stock_value_eur: 12_000
      },
      %Freezer{
        id: "FZ-04",
        name: "Butcher display",
        kind: :chilled,
        current_c: 2.0,
        target_c: 2.5,
        safe_min_c: -1.0,
        safe_max_c: 5.0,
        stock_value_eur: 6_500
      }
    ]
    |> Map.new(&{&1.id, &1})
  end

  defp env_float(name, default) do
    case Float.parse(System.get_env(name, "")) do
      {value, _rest} -> value
      :error -> default
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp wall_ms, do: System.system_time(:millisecond)
end
