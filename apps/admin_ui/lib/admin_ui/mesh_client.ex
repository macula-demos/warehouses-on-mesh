defmodule AdminUi.MeshClient do
  @moduledoc """
  The laptop's Macula citizen.

  The browser never speaks the mesh. This process holds the operator's node
  identity, connects outbound to the station, and answers the LiveView's
  read and write calls. The gateway authorizes writes by this node identity;
  the browser never holds the key.
  """

  use GenServer

  require Logger

  @retry_ms 2_000
  @call_timeout_ms 5_000
  @gen_server_timeout_ms 15_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec status() :: :starting | :connected | :disconnected
  def status, do: GenServer.call(__MODULE__, :status, @gen_server_timeout_ms)

  @spec operator_node_id() :: String.t() | nil
  def operator_node_id, do: GenServer.call(__MODULE__, :operator_node_id, @gen_server_timeout_ms)

  @spec stranger_node_id() :: String.t() | nil
  def stranger_node_id, do: GenServer.call(__MODULE__, :stranger_node_id, @gen_server_timeout_ms)

  @spec list_freezers() :: {:ok, [map()], map() | nil} | {:error, term()}
  def list_freezers, do: GenServer.call(__MODULE__, :list_freezers, @gen_server_timeout_ms)

  @spec list_freezer_commands() :: {:ok, [map()], map() | nil} | {:error, term()}
  def list_freezer_commands do
    GenServer.call(__MODULE__, :list_freezer_commands, @gen_server_timeout_ms)
  end

  @spec set_freezer_target(String.t(), number()) :: {:ok, map(), map() | nil} | {:error, term()}
  def set_freezer_target(freezer_id, target_c) do
    payload = command_payload(freezer_id, %{"target_c" => target_c})

    GenServer.call(
      __MODULE__,
      {:write_freezer, "ot/set_freezer_target", payload},
      @gen_server_timeout_ms
    )
  end

  @spec start_defrost(String.t()) :: {:ok, map(), map() | nil} | {:error, term()}
  def start_defrost(freezer_id) do
    payload = command_payload(freezer_id, %{})

    GenServer.call(
      __MODULE__,
      {:write_freezer, "ot/start_freezer_defrost", payload},
      @gen_server_timeout_ms
    )
  end

  @spec stop_defrost(String.t()) :: {:ok, map(), map() | nil} | {:error, term()}
  def stop_defrost(freezer_id) do
    payload = command_payload(freezer_id, %{})

    GenServer.call(
      __MODULE__,
      {:write_freezer, "ot/stop_freezer_defrost", payload},
      @gen_server_timeout_ms
    )
  end

  @spec replay_last() :: {:ok, map(), map() | nil} | {:error, term()}
  def replay_last do
    GenServer.call(__MODULE__, :replay_last, @gen_server_timeout_ms)
  end

  @doc """
  Sends a write from a second, unlisted node identity.

  The gateway's write policy admits only the operator node. This call exists
  to show what a stranger on the same station gets: `unauthorized`.
  """
  @spec stranger_set_target(String.t(), number()) :: {:ok, map(), map() | nil} | {:error, term()}
  def stranger_set_target(freezer_id, target_c) do
    payload = command_payload(freezer_id, %{"target_c" => target_c})

    GenServer.call(
      __MODULE__,
      {:stranger_write, "ot/set_freezer_target", payload},
      @gen_server_timeout_ms
    )
  end

  @impl true
  def init(_opts) do
    {:ok,
     %{
       status: :starting,
       pool: nil,
       realm: nil,
       config: nil,
       node_id_hex: nil,
       stranger_pool: nil,
       stranger_node_id_hex: nil,
       last_command: nil,
       last_error: nil
     }, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: connect(state)

  @impl true
  def handle_info(:connect, state), do: connect(state)

  def handle_info({:DOWN, _ref, :process, pool, reason}, %{pool: pool} = state) do
    {:noreply, schedule_retry(%{state | status: :disconnected, pool: nil, last_error: reason})}
  end

  def handle_info({:DOWN, _ref, :process, pool, reason}, %{stranger_pool: pool} = state) do
    {:noreply, %{state | stranger_pool: nil, stranger_node_id_hex: nil, last_error: reason}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:operator_node_id, _from, state), do: {:reply, state.node_id_hex, state}

  def handle_call(:stranger_node_id, _from, state),
    do: {:reply, state.stranger_node_id_hex, state}

  def handle_call(:list_freezers, _from, %{status: :connected, pool: pool, realm: realm} = state) do
    case :macula.call(pool, realm, "ot/list_freezers", %{}, @call_timeout_ms, %{report: true}) do
      {:ok, reply, report} ->
        reply_freezers(reply, report, state)

      {:ok, reply} ->
        reply_freezers(reply, nil, state)

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | last_error: reason}}
    end
  end

  def handle_call(:list_freezers, _from, state) do
    {:reply, {:error, state.last_error || :not_connected}, state}
  end

  def handle_call(:list_freezer_commands, _from, %{status: :connected} = state) do
    case call_write(state, "ot/list_freezer_commands", %{}) do
      {:ok, reply, report} ->
        case normalize_commands(reply) do
          {:ok, commands} -> {:reply, {:ok, commands, report}, state}
          {:error, reason} -> {:reply, {:error, reason}, %{state | last_error: reason}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | last_error: reason}}
    end
  end

  def handle_call(:list_freezer_commands, _from, state) do
    {:reply, {:error, state.last_error || :not_connected}, state}
  end

  def handle_call({:write_freezer, procedure, payload}, _from, %{status: :connected} = state) do
    state = %{state | last_command: {procedure, payload}}

    case call_write(state, procedure, payload) do
      {:ok, reply, report} ->
        case normalize_freezer(reply) do
          {:ok, freezer} -> {:reply, {:ok, freezer, report}, state}
          {:error, reason} -> {:reply, {:error, reason}, %{state | last_error: reason}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | last_error: reason}}
    end
  end

  def handle_call({:write_freezer, _procedure, _payload}, _from, state) do
    {:reply, {:error, state.last_error || :not_connected}, state}
  end

  def handle_call(
        :replay_last,
        _from,
        %{status: :connected, last_command: {procedure, payload}} = state
      ) do
    case call_write(state, procedure, payload) do
      {:ok, reply, report} ->
        case normalize_freezer(reply) do
          {:ok, freezer} -> {:reply, {:ok, freezer, report}, state}
          {:error, reason} -> {:reply, {:error, reason}, %{state | last_error: reason}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | last_error: reason}}
    end
  end

  def handle_call(:replay_last, _from, state) do
    {:reply, {:error, :no_last_command}, state}
  end

  def handle_call({:stranger_write, procedure, payload}, _from, %{status: :connected} = state) do
    case ensure_stranger_pool(state) do
      {:ok, pool, state} ->
        case call_write(%{pool: pool, realm: state.realm}, procedure, payload) do
          {:ok, reply, report} ->
            case normalize_freezer(reply) do
              {:ok, freezer} -> {:reply, {:ok, freezer, report}, state}
              {:error, reason} -> {:reply, {:error, reason}, %{state | last_error: reason}}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, %{state | last_error: reason}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | last_error: reason}}
    end
  end

  def handle_call({:stranger_write, _procedure, _payload}, _from, state) do
    {:reply, {:error, state.last_error || :not_connected}, state}
  end

  defp reply_freezers(reply, report, state) do
    case normalize_freezers(reply) do
      {:ok, freezers} -> {:reply, {:ok, freezers, report}, state}
      {:error, reason} -> {:reply, {:error, reason}, %{state | last_error: reason}}
    end
  end

  defp connect(state) do
    with {:ok, config} <- read_config(),
         {:ok, pool, node_id_hex} <-
           connect_pool(config, operator_identity_path(), publish_operator: true) do
      _ref = Process.monitor(pool)

      Logger.info(
        "mesh client connected to station #{Base.encode16(config.station_node_id, case: :lower)} as #{node_id_hex}"
      )

      {:noreply,
       %{
         state
         | status: :connected,
           pool: pool,
           realm: config.realm,
           config: config,
           node_id_hex: node_id_hex,
           last_error: nil
       }}
    else
      {:error, reason} ->
        Logger.debug("mesh client not connected yet: #{inspect(reason)}")
        {:noreply, schedule_retry(%{state | status: :disconnected, last_error: reason})}
    end
  end

  defp read_config do
    path = Application.get_env(:admin_ui, :mesh_config_path, "/mesh/realm.json")

    with true <- File.regular?(path),
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         realm_hex when is_binary(realm_hex) <- decoded["realm"],
         key_hex when is_binary(key_hex) <- decoded["realm_key"],
         station_hex when is_binary(station_hex) <- decoded["station_node_id"],
         {:ok, realm} <- Base.decode16(realm_hex, case: :lower),
         {:ok, realm_key} <- Base.decode16(key_hex, case: :lower),
         {:ok, station_id} <- Base.decode16(station_hex, case: :lower) do
      {:ok, %{realm: realm, realm_key: realm_key, station_node_id: station_id}}
    else
      false -> {:error, :realm_file_not_ready}
      _ -> {:error, :invalid_realm_file}
    end
  end

  defp connect_pool(config, identity_path, opts \\ [])

  defp connect_pool(
         %{realm: realm, realm_key: realm_key, station_node_id: station_id},
         identity_path,
         opts
       ) do
    File.mkdir_p!(Path.dirname(identity_path))
    {:ok, identity_key} = :macula_node_keys.node_identity(identity_path, :pq_hybrid)
    {:ok, node_id} = :macula_node_keys.node_id(identity_key)
    node_id_hex = Base.encode16(node_id, case: :lower)

    if Keyword.get(opts, :publish_operator, false) do
      write_operator_node_id(node_id_hex)
    end

    {host, port} =
      Application.get_env(:admin_ui, :mesh_station_seed, "station:4433")
      |> parse_seed()

    seeds = [%{host: host, port: port, expected_node_id: station_id}]
    opts = %{node_identity: identity_key, realm_trust: %{realm => realm_key}}

    case :macula_client.connect(seeds, opts) do
      {:ok, pool} ->
        case wait_healthy(pool, 50) do
          {:ok, pool} -> {:ok, pool, node_id_hex}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_stranger_pool(%{stranger_pool: pool} = state) when not is_nil(pool) do
    {:ok, pool, state}
  end

  defp ensure_stranger_pool(%{config: %{} = config} = state) do
    case connect_pool(config, stranger_identity_path()) do
      {:ok, pool, node_id_hex} ->
        _ref = Process.monitor(pool)

        Logger.info(
          "stranger identity connected to station as #{node_id_hex}; writes should be refused"
        )

        {:ok, pool, %{state | stranger_pool: pool, stranger_node_id_hex: node_id_hex}}

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_stranger_pool(_state), do: {:error, :not_connected}

  defp operator_identity_path do
    Application.get_env(:admin_ui, :mesh_identity_path, "/data/operator.key")
  end

  defp stranger_identity_path do
    Application.get_env(:admin_ui, :mesh_stranger_identity_path, "/data/stranger.key")
  end

  defp write_operator_node_id(node_id_hex) do
    path =
      Application.get_env(:admin_ui, :mesh_operator_node_id_path, "/mesh/operator-node-id")

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, node_id_hex)
  end

  defp wait_healthy(_pool, 0), do: {:error, :station_unhealthy}

  defp wait_healthy(pool, attempts) do
    case :macula_client.status(pool) do
      {:ok, %{healthy_links: links}} when links > 0 ->
        {:ok, pool}

      _other ->
        Process.sleep(100)
        wait_healthy(pool, attempts - 1)
    end
  end

  defp parse_seed(seed) do
    case String.split(seed, ":", parts: 2) do
      [host, port] -> {host, String.to_integer(port)}
      [host] -> {host, 4433}
    end
  end

  defp schedule_retry(state) do
    Process.send_after(self(), :connect, @retry_ms)
    state
  end

  defp command_payload(freezer_id, extra) do
    %{
      "freezer_id" => freezer_id,
      "command_id" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      "requested_at_ms" => System.system_time(:millisecond)
    }
    |> Map.merge(extra)
  end

  defp call_write(%{pool: pool, realm: realm}, procedure, payload) do
    case :macula.call(pool, realm, procedure, payload, @call_timeout_ms, %{report: true}) do
      {:ok, reply, report} -> {:ok, reply, report}
      {:ok, reply} -> {:ok, reply, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_freezers(reply) do
    case field(reply, "freezers") do
      freezers when is_list(freezers) ->
        {:ok, Enum.map(freezers, &normalize_freezer!/1)}

      other ->
        {:error, {:unexpected_reply, other}}
    end
  end

  defp normalize_freezer(reply) do
    case field(reply, "id") do
      id when is_binary(id) -> {:ok, normalize_freezer!(reply)}
      _other -> {:error, :unexpected_freezer_reply}
    end
  end

  defp normalize_freezer!(raw) do
    %{
      "id" => field(raw, "id"),
      "name" => field(raw, "name"),
      "kind" => field(raw, "kind"),
      "current_c" => field(raw, "current_c"),
      "target_c" => field(raw, "target_c"),
      "mode" => field(raw, "mode"),
      "door_open" => field(raw, "door_open"),
      "safe_min_c" => field(raw, "safe_min_c"),
      "safe_max_c" => field(raw, "safe_max_c"),
      "alarm" => field(raw, "alarm"),
      "stock_value_eur" => field(raw, "stock_value_eur"),
      "last_changed_at_ms" => field(raw, "last_changed_at_ms")
    }
  end

  defp normalize_commands(reply) do
    case field(reply, "commands") do
      commands when is_list(commands) ->
        {:ok, Enum.map(commands, &normalize_command/1)}

      other ->
        {:error, {:unexpected_reply, other}}
    end
  end

  defp normalize_command(raw) do
    %{
      "at_ms" => field(raw, "at_ms"),
      "caller" => field(raw, "caller"),
      "action" => field(raw, "action"),
      "freezer_id" => field(raw, "freezer_id"),
      "command_id" => field(raw, "command_id"),
      "result" => field(raw, "result")
    }
  end

  defp field(map, key) when is_map(map) do
    bin = if is_atom(key), do: Atom.to_string(key), else: key
    atom = existing_atom(bin)

    [atom, bin, {:text, bin}]
    |> Enum.reject(&is_nil/1)
    |> lookup(map, nil)
  end

  defp field(_not_a_map, _key), do: nil

  defp existing_atom(bin) do
    String.to_existing_atom(bin)
  rescue
    ArgumentError -> nil
  end

  defp lookup([], _map, default), do: default

  defp lookup([key | rest], map, default) do
    case Map.fetch(map, key) do
      {:ok, value} -> unwrap(value)
      :error -> lookup(rest, map, default)
    end
  end

  defp unwrap({:text, bin}) when is_binary(bin), do: bin
  defp unwrap(nil), do: nil
  defp unwrap(list) when is_list(list), do: Enum.map(list, &unwrap/1)
  defp unwrap(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, unwrap(value)} end)
  defp unwrap(other), do: other
end
