defmodule AdminUi.MeshClient do
  @moduledoc """
  The laptop's Macula citizen at site A.

  The browser never speaks the mesh. This process holds the operator's node
  identity, connects outbound to site A's station, resolves both gateways'
  `ot/*` advertisements, and calls a chosen provider through site A's station.
  Site A's station forwards a site B call to site B's station; the gateway
  authorizes writes by this node identity. The browser never holds the key.

  Reads are refreshed in a background task so a slow DHT lookup or a dead
  provider never blocks the LiveView's mailbox (the part 1 dashboard taught
  that lesson the hard way with a dead legacy edge).
  """

  use GenServer

  require Logger

  @retry_ms 2_000
  @refresh_ms 1_000
  @call_timeout_ms 6_000
  @gen_server_timeout_ms 20_000

  @read "ot/list_freezers"
  @commands "ot/list_freezer_commands"
  @set_target "ot/set_freezer_target"
  @start_defrost "ot/start_freezer_defrost"
  @stop_defrost "ot/stop_freezer_defrost"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec status() :: :starting | :connected | :disconnected
  def status, do: call(:status)

  @spec operator_node_id() :: String.t() | nil
  def operator_node_id, do: call(:operator_node_id)

  @spec stranger_node_id() :: String.t() | nil
  def stranger_node_id, do: call(:stranger_node_id)

  @doc "A fast snapshot of the last background refresh, for the LiveView tick."
  @spec snapshot() :: map()
  def snapshot, do: call(:snapshot)

  @spec refresh_now() :: :ok
  def refresh_now, do: GenServer.cast(__MODULE__, :refresh_now)

  @spec set_freezer_target(String.t(), String.t(), number()) ::
          {:ok, map(), map() | nil} | {:error, term()}
  def set_freezer_target(site, freezer_id, target_c) do
    payload = command_payload(freezer_id, %{"target_c" => target_c})
    call({:write_freezer, site, @set_target, payload})
  end

  @spec start_defrost(String.t(), String.t()) :: {:ok, map(), map() | nil} | {:error, term()}
  def start_defrost(site, freezer_id) do
    call({:write_freezer, site, @start_defrost, command_payload(freezer_id, %{})})
  end

  @spec stop_defrost(String.t(), String.t()) :: {:ok, map(), map() | nil} | {:error, term()}
  def stop_defrost(site, freezer_id) do
    call({:write_freezer, site, @stop_defrost, command_payload(freezer_id, %{})})
  end

  @spec replay_last() :: {:ok, map(), map() | nil} | {:error, term()}
  def replay_last, do: call(:replay_last)

  @doc """
  Sends a write from a second, unlisted node identity.

  The gateway's write policy admits only the operator node. This call exists
  to show what a stranger on the same station gets: `unauthorized`.
  """
  @spec stranger_set_target(String.t(), String.t(), number()) ::
          {:ok, map(), map() | nil} | {:error, term()}
  def stranger_set_target(site, freezer_id, target_c) do
    payload = command_payload(freezer_id, %{"target_c" => target_c})
    call({:stranger_write, site, @set_target, payload})
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
       last_error: nil,
       sites: %{},
       providers: [],
       version: 0,
       refreshing?: false,
       last_refresh_ms: nil
     }, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: connect(state)

  @impl true
  def handle_info(:connect, state), do: connect(state)

  def handle_info(:refresh, state) do
    state = start_refresh(state)

    if state.status == :connected and not state.refreshing? do
      Process.send_after(self(), :refresh, @retry_ms)
    end

    {:noreply, state}
  end

  def handle_info({:refreshed, {:ok, sites, providers}}, state) do
    Process.send_after(self(), :refresh, @refresh_ms)

    {:noreply,
     %{
       state
       | refreshing?: false,
         sites: sites,
         providers: providers,
         version: state.version + 1,
         last_refresh_ms: System.system_time(:millisecond),
         last_error: nil
     }}
  end

  def handle_info({:refreshed, {:error, reason}}, state) do
    Process.send_after(self(), :refresh, @refresh_ms * 2)

    {:noreply,
     %{
       state
       | refreshing?: false,
         last_error: reason,
         last_refresh_ms: System.system_time(:millisecond)
     }}
  end

  def handle_info({:DOWN, _ref, :process, pool, reason}, %{pool: pool} = state) do
    {:noreply,
     schedule_retry(%{
       state
       | status: :disconnected,
         pool: nil,
         refreshing?: false,
         last_error: reason
     })}
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

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       status: state.status,
       operator_node_id: state.node_id_hex,
       stranger_node_id: state.stranger_node_id_hex,
       sites: state.sites,
       providers: state.providers,
       station_ids: station_ids(state),
       version: state.version,
       refreshing?: state.refreshing?,
       last_refresh_ms: state.last_refresh_ms,
       last_error: state.last_error
     }, state}
  end

  def handle_call({:write_freezer, site, procedure, payload}, _from, state) do
    with %{provider_id: provider} <- provider_for(state, site),
         {:ok, reply, report} <-
           call_provider(state, provider, procedure, payload, @call_timeout_ms),
         {:ok, freezer} <- normalize_freezer(reply) do
      state =
        state
        |> record_command(site, provider, procedure, payload)
        |> record_freezer(site, freezer, report)

      send(self(), :refresh)
      {:reply, {:ok, freezer, report}, state}
    else
      nil ->
        {:reply, {:error, :site_unresolved}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | last_error: reason}}
    end
  end

  def handle_call(:replay_last, _from, %{status: :connected, last_command: command} = state)
      when is_map(command) do
    %{site: site, provider: provider, procedure: procedure, payload: payload} = command

    case call_provider(state, provider, procedure, payload, @call_timeout_ms) do
      {:ok, reply, report} ->
        case normalize_freezer(reply) do
          {:ok, freezer} ->
            {:reply, {:ok, freezer, report}, record_freezer(state, site, freezer, report)}

          {:error, reason} ->
            {:reply, {:error, reason}, %{state | last_error: reason}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | last_error: reason}}
    end
  end

  def handle_call(:replay_last, _from, state), do: {:reply, {:error, :no_last_command}, state}

  def handle_call({:stranger_write, site, procedure, payload}, _from, state) do
    case provider_for(state, site) do
      nil ->
        {:reply, {:error, :site_unresolved}, state}

      %{provider_id: provider} ->
        case ensure_stranger_pool(state) do
          {:ok, pool, state} ->
            case call_provider(pool, state.config, provider, procedure, payload, @call_timeout_ms) do
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
  end

  @impl true
  def handle_cast(:refresh_now, state) do
    send(self(), :refresh)
    {:noreply, state}
  end

  # -- connection --------------------------------------------------------

  defp connect(state) do
    with {:ok, config} <- read_config(),
         {:ok, pool, node_id_hex} <-
           connect_pool(config, operator_identity_path(), publish_operator: true) do
      _ref = Process.monitor(pool)

      Logger.info(
        "mesh client connected to station #{Base.encode16(config.station_node_id, case: :lower)} as #{node_id_hex}"
      )

      send(self(), :refresh)

      {:noreply,
       %{
         state
         | status: :connected,
           pool: pool,
           realm: config.realm,
           config: config,
           node_id_hex: node_id_hex,
           sites: %{},
           providers: [],
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
      {:ok,
       %{
         realm: realm,
         realm_key: realm_key,
         station_node_id: station_id,
         station_ids: decode_station_ids(decoded["stations"])
       }}
    else
      false -> {:error, :realm_file_not_ready}
      _ -> {:error, :invalid_realm_file}
    end
  end

  defp decode_station_ids(stations) when is_map(stations) do
    Map.new(stations, fn {site, hex} ->
      case Base.decode16(hex, case: :lower) do
        {:ok, id} -> {site, Base.encode16(id, case: :lower)}
        :error -> {site, hex}
      end
    end)
  end

  defp decode_station_ids(_other), do: %{}

  defp station_ids(%{config: %{station_ids: ids}}) when is_map(ids), do: ids
  defp station_ids(_state), do: %{}

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
      Application.get_env(:admin_ui, :mesh_station_seed, "station-a:4433")
      |> parse_seed()

    seeds = [%{host: host, port: port, expected_node_id: station_id}]
    opts = %{node_identity: identity_key, realm_trust: %{realm => realm_key}}

    case :macula_client.connect(seeds, opts) do
      {:ok, pool} ->
        case wait_healthy(pool, 100) do
          {:ok, pool} -> {:ok, pool, node_id_hex}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
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

  # -- background refresh ------------------------------------------------

  defp start_refresh(%{status: :connected, refreshing?: false, pool: pool, realm: realm} = state) do
    config = state.config
    parent = self()

    Task.start(fn ->
      result =
        try do
          refresh_sites(pool, realm, config)
        catch
          kind, reason ->
            Logger.error(
              "mesh refresh failed: " <> Exception.format(kind, reason, __STACKTRACE__)
            )

            {:error, {kind, reason}}
        end

      send(parent, {:refreshed, result})
    end)

    %{state | refreshing?: true}
  end

  defp start_refresh(state), do: state

  defp refresh_sites(pool, realm, config) do
    with {:ok, providers} <- discover_providers(pool, realm) do
      {sites, rows} =
        Enum.reduce(providers, {%{}, []}, &refresh_provider(&1, &2, pool, config))

      {:ok, sites, Enum.reverse(rows)}
    end
  end

  defp discover_providers(pool, realm) do
    case :macula_direct_dial.providers(pool, realm, @read, @call_timeout_ms) do
      {:ok, providers} when is_list(providers) ->
        {:ok,
         providers
         |> Enum.map(fn provider ->
           %{
             provider_id: Map.get(provider, :provider),
             provider: hex(Map.get(provider, :provider)),
             station: hex(Map.get(provider, :station))
           }
         end)
         |> Enum.uniq_by(& &1.provider_id)
         |> Enum.sort_by(& &1.provider)}

      {:error, {:unresolved, _reason}} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refresh_provider(provider, {sites, rows}, pool, config) do
    case call_provider(pool, config, provider.provider_id, @read, %{}, @call_timeout_ms) do
      {:ok, reply, report} ->
        case normalize_freezers(reply) do
          {:ok, freezers} ->
            site = site_of(freezers) || "?"

            {audit, audit_error} =
              case call_provider(
                     pool,
                     config,
                     provider.provider_id,
                     @commands,
                     %{},
                     @call_timeout_ms
                   ) do
                {:ok, audit_reply, _audit_report} ->
                  case normalize_commands(audit_reply) do
                    {:ok, commands} -> {commands, nil}
                    {:error, reason} -> {[], inspect(reason)}
                  end

                {:error, reason} ->
                  {[], format_reason(reason)}
              end

            site_entry =
              Map.merge(provider, %{
                site: site,
                freezers: freezers,
                report: report,
                audit: audit,
                audit_error: audit_error
              })

            {Map.put(sites, site, site_entry),
             [Map.merge(provider, %{site: site, status: "ok"}) | rows]}

          {:error, reason} ->
            {sites, [Map.merge(provider, %{status: "bad_reply", error: inspect(reason)}) | rows]}
        end

      {:error, reason} ->
        {sites,
         [Map.merge(provider, %{status: "unreachable", error: format_reason(reason)}) | rows]}
    end
  end

  defp call_provider(state, provider, procedure, payload, timeout)
       when is_map(state) do
    call_provider(state.pool, state.config, provider, procedure, payload, timeout)
  end

  defp call_provider(pool, config, provider, procedure, payload, timeout) do
    opts = %{
      expected_node_id: config.station_node_id,
      report: true,
      confidential: :required
    }

    case :macula.call_station(
           pool,
           station_url(),
           provider,
           config.realm,
           procedure,
           payload,
           timeout,
           opts
         ) do
      {:ok, reply, report} -> {:ok, reply, report}
      {:ok, reply} -> {:ok, reply, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp station_url do
    {host, port} =
      Application.get_env(:admin_ui, :mesh_station_seed, "station-a:4433")
      |> parse_seed()

    "quic://#{host}:#{port}"
  end

  defp provider_for(state, site) do
    case Map.get(state.sites, site) do
      %{provider_id: provider} = entry when is_binary(provider) -> entry
      _other -> nil
    end
  end

  defp record_command(state, site, provider, procedure, payload) do
    %{
      state
      | last_command: %{site: site, provider: provider, procedure: procedure, payload: payload}
    }
  end

  defp record_freezer(state, site, freezer, report) do
    case Map.fetch(state.sites, site) do
      {:ok, entry} ->
        freezers =
          entry.freezers
          |> Enum.reject(&(&1["id"] == freezer["id"]))
          |> then(&[freezer | &1])
          |> Enum.sort_by(& &1["id"])

        entry = %{entry | freezers: freezers, report: report}
        %{state | sites: Map.put(state.sites, site, entry), version: state.version + 1}

      :error ->
        state
    end
  end

  # -- payload and normalization ----------------------------------------

  defp command_payload(freezer_id, extra) do
    %{
      "freezer_id" => freezer_id,
      "command_id" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      "requested_at_ms" => System.system_time(:millisecond)
    }
    |> Map.merge(extra)
  end

  defp site_of([%{"site_id" => site} | _]) when is_binary(site), do: site

  defp site_of([%{"id" => "FZ-" <> rest} | _]) do
    rest |> String.first()
  end

  defp site_of(_other), do: nil

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
      "site_id" => field(raw, "site_id"),
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

  defp hex(nil), do: nil
  defp hex(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)
  defp hex(other), do: inspect(other)

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp call(message) do
    GenServer.call(__MODULE__, message, @gen_server_timeout_ms)
  end
end
