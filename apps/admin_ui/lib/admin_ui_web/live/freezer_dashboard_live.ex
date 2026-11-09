defmodule AdminUiWeb.FreezerDashboardLive do
  use AdminUiWeb, :live_view

  alias AdminUi.LegacyController
  alias AdminUi.MeshClient

  @tick_ms 1_000
  @history_points 40

  @impl true
  def mount(_params, _session, socket) do
    base_url = Application.get_env(:admin_ui, :legacy_edge_url, "http://localhost:8080")

    socket =
      socket
      |> assign(:page_title, "Cold Chain Control")
      # This lab has no legacy edge: the retrofit is assumed done at both
      # sites. Start on the mesh path so a dead legacy URL never blocks the
      # LiveView's mailbox.
      |> assign(:mode, :mesh)
      |> assign(:base_url, base_url)
      |> assign(:auth, nil)
      |> assign(:login_form, to_form(%{"username" => "admin", "password" => "admin"}, as: :login))
      |> assign(:readings, %{})
      |> assign(:freezer_count, 0)
      |> assign(:audit_count, 0)
      |> assign(:gateway_audit_count, 0)
      |> assign(:last_refresh_ms, nil)
      |> assign(:error, nil)
      |> assign(:attack_result, nil)
      |> assign(:mesh_ready?, MeshClient.status() == :connected)
      |> assign(:operator_node_id, MeshClient.operator_node_id())
      |> assign(:seal_report, nil)
      |> stream(:freezers, [], dom_id: &"freezer-#{&1["id"]}")
      |> stream(:audit, [], dom_id: &"audit-#{&1["id"]}")
      |> stream(:gateway_audit, [], dom_id: &"gateway-audit-#{&1["id"]}")

    if connected?(socket), do: Process.send_after(self(), :tick, 0)

    {:ok, refresh(socket)}
  end

  @impl true
  def handle_info(:tick, socket) do
    socket = refresh(socket)
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_mode", %{"mode" => "legacy"}, socket) do
    {:noreply, socket |> assign(:mode, :legacy) |> refresh()}
  end

  def handle_event("switch_mode", %{"mode" => "mesh"}, socket) do
    if MeshClient.status() == :connected do
      {:noreply, socket |> assign(:mode, :mesh) |> refresh()}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "The mesh client is not connected yet. Check the station and the gateway."
       )}
    end
  end

  def handle_event("login", %{"login" => %{"username" => user, "password" => password}}, socket) do
    case LegacyController.login(socket.assigns.base_url, user, password) do
      {:ok, signed_in} ->
        {:noreply,
         socket
         |> assign(:auth, %{user: user, password: password})
         |> put_flash(
           :info,
           "Signed in as #{signed_in}. This login is a UI gate; the controller API is still directly reachable."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Login failed: #{reason}")}
    end
  end

  def handle_event("logout", _params, socket) do
    {:noreply, socket |> assign(:auth, nil) |> put_flash(:info, "Signed out of the UI.")}
  end

  def handle_event("set_target", %{"id" => id, "target" => target}, socket) do
    case Float.parse(target) do
      {target_c, ""} -> write_target(socket, id, target_c)
      _ -> {:noreply, put_flash(socket, :error, "Invalid target temperature.")}
    end
  end

  def handle_event("start_defrost", %{"id" => id}, socket) do
    write_defrost(socket, id, :start)
  end

  def handle_event("stop_defrost", %{"id" => id}, socket) do
    write_defrost(socket, id, :stop)
  end

  def handle_event("replay_last", _params, %{assigns: %{mode: :mesh}} = socket) do
    case MeshClient.replay_last() do
      {:ok, freezer, _report} ->
        write_ok(socket, freezer, "Replayed command accepted (unexpected).")

      {:error, reason} ->
        write_error(socket, reason)
    end
  end

  def handle_event("replay_last", _params, socket) do
    {:noreply, put_flash(socket, :error, "Replay is only available in Mesh mode.")}
  end

  def handle_event("stranger_write", _params, %{assigns: %{mode: :mesh}} = socket) do
    case MeshClient.stranger_set_target("FZ-01", 60.0) do
      {:ok, freezer, _report} ->
        write_ok(socket, freezer, "Stranger write accepted (unexpected).")

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Stranger #{short_id(MeshClient.stranger_node_id())} refused: #{format_reason(reason)}"
         )}
    end
  end

  def handle_event("stranger_write", _params, socket) do
    {:noreply, put_flash(socket, :error, "The stranger probe is only available in Mesh mode.")}
  end

  def handle_event("attack_read", _params, socket) do
    case LegacyController.list_freezers(socket.assigns.base_url) do
      {:ok, freezers} ->
        {:noreply,
         assign(socket, :attack_result, %{
           kind: :success,
           text: "Read #{length(freezers)} freezers with no credentials. The controller answered."
         })}

      {:error, reason} ->
        {:noreply,
         assign(socket, :attack_result, %{kind: :error, text: "Read failed: #{reason}"})}
    end
  end

  def handle_event("attack_set_target", _params, socket) do
    case LegacyController.set_target(socket.assigns.base_url, "admin", "admin", "FZ-01", 50) do
      {:ok, _freezer} ->
        {:noreply,
         socket
         |> assign(:attack_result, %{
           kind: :success,
           text: "Set FZ-01 to +50°C using the default admin/admin credentials."
         })
         |> refresh()}

      {:error, reason} ->
        {:noreply,
         assign(socket, :attack_result, %{kind: :error, text: "Attack failed: #{reason}"})}
    end
  end

  def handle_event("attack_defrost", _params, socket) do
    case LegacyController.start_defrost(socket.assigns.base_url, "admin", "admin", "FZ-01") do
      {:ok, _freezer} ->
        {:noreply,
         socket
         |> assign(:attack_result, %{
           kind: :success,
           text: "Forced FZ-01 into defrost with the default admin/admin credentials."
         })
         |> refresh()}

      {:error, reason} ->
        {:noreply,
         assign(socket, :attack_result, %{kind: :error, text: "Attack failed: #{reason}"})}
    end
  end

  def handle_event("reset_lab", _params, socket) do
    case LegacyController.reset(socket.assigns.base_url, "admin", "admin") do
      {:ok, _body} ->
        {:noreply,
         socket
         |> assign(:attack_result, %{kind: :success, text: "Lab reset to safe temperatures."})
         |> refresh()}

      {:error, reason} ->
        {:noreply,
         assign(socket, :attack_result, %{kind: :error, text: "Reset failed: #{reason}"})}
    end
  end

  def handle_event("dismiss_attack", _params, socket) do
    {:noreply, assign(socket, :attack_result, nil)}
  end

  defp write_target(%{assigns: %{mode: :mesh}} = socket, id, target_c) do
    case MeshClient.set_freezer_target(id, target_c) do
      {:ok, freezer, _report} ->
        write_ok(socket, freezer, "Gateway accepted #{id} target #{target_c}°C (sealed).")

      {:error, reason} ->
        write_error(socket, reason)
    end
  end

  defp write_target(%{assigns: %{mode: :legacy}} = socket, id, target_c) do
    with %{user: user, password: password} <- socket.assigns.auth do
      case LegacyController.set_target(socket.assigns.base_url, user, password, id, target_c) do
        {:ok, freezer} -> write_ok(socket, freezer, "Set #{id} target to #{target_c}°C.")
        {:error, reason} -> write_error(socket, reason)
      end
    else
      nil -> sign_in_required(socket)
    end
  end

  defp write_defrost(%{assigns: %{mode: :mesh}} = socket, id, action) do
    result =
      case action do
        :start -> MeshClient.start_defrost(id)
        :stop -> MeshClient.stop_defrost(id)
      end

    case result do
      {:ok, freezer, _report} ->
        write_ok(socket, freezer, "#{action_label(action)} #{id} via the gateway (sealed).")

      {:error, reason} ->
        write_error(socket, reason)
    end
  end

  defp write_defrost(%{assigns: %{mode: :legacy}} = socket, id, action) do
    with %{user: user, password: password} <- socket.assigns.auth do
      result =
        case action do
          :start -> LegacyController.start_defrost(socket.assigns.base_url, user, password, id)
          :stop -> LegacyController.stop_defrost(socket.assigns.base_url, user, password, id)
        end

      case result do
        {:ok, freezer} -> write_ok(socket, freezer, "#{action_label(action)} #{id}.")
        {:error, reason} -> write_error(socket, reason)
      end
    else
      nil -> sign_in_required(socket)
    end
  end

  defp action_label(:start), do: "Started defrost on"
  defp action_label(:stop), do: "Stopped defrost on"

  defp writes_enabled?(:legacy, auth, _mesh_ready?), do: not is_nil(auth)
  defp writes_enabled?(:mesh, _auth, mesh_ready?), do: mesh_ready?

  defp short_id(nil), do: "—"

  defp short_id(id) when is_binary(id) do
    if String.length(id) > 12, do: String.slice(id, 0, 12) <> "…", else: id
  end

  defp short_id(other), do: inspect(other)

  defp write_ok(socket, freezer, message) do
    {:noreply,
     socket
     |> stream_insert(:freezers, freezer)
     |> refresh()
     |> put_flash(:info, message)}
  end

  defp write_error(socket, reason) do
    {:noreply, put_flash(socket, :error, "Command refused: #{format_reason(reason)}")}
  end

  defp sign_in_required(socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "Sign in first. The controller uses one shared password for writes."
     )}
  end

  defp format_reason(:command_replayed),
    do: "command_replayed (the gateway already saw this command id)"

  defp format_reason(:command_expired),
    do: "command_expired (the command timestamp is outside the gateway window)"

  defp format_reason({:call_error, "unauthorized", _detail}),
    do: "unauthorized (this node is not on the gateway's operator list)"

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp refresh(socket) do
    socket =
      socket
      |> assign(:mesh_ready?, MeshClient.status() == :connected)
      |> assign(:operator_node_id, MeshClient.operator_node_id())

    case socket.assigns.mode do
      :legacy -> refresh_legacy(socket)
      :mesh -> refresh_mesh(socket)
    end
  end

  defp refresh_legacy(socket) do
    case LegacyController.list_freezers(socket.assigns.base_url) do
      {:ok, freezers} ->
        socket =
          socket
          |> assign(:freezer_count, length(freezers))
          |> assign(:readings, update_readings(socket.assigns.readings, freezers))
          |> assign(:last_refresh_ms, System.system_time(:millisecond))
          |> assign(:error, nil)
          |> put_freezers(freezers)

        refresh_audit(socket)

      {:error, reason} ->
        assign(socket, :error, reason)
    end
  end

  defp refresh_mesh(socket) do
    case MeshClient.list_freezers() do
      {:ok, freezers, report} ->
        socket
        |> assign(:freezer_count, length(freezers))
        |> assign(:readings, update_readings(socket.assigns.readings, freezers))
        |> assign(:last_refresh_ms, System.system_time(:millisecond))
        |> assign(:error, nil)
        |> assign(:seal_report, report)
        |> put_freezers(freezers)
        |> refresh_gateway_audit()

      {:error, reason} ->
        assign(socket, :error, "mesh: #{inspect(reason)}")
    end
  end

  defp refresh_gateway_audit(socket) do
    case MeshClient.list_freezer_commands() do
      {:ok, commands, _report} ->
        commands =
          commands
          |> Enum.with_index()
          |> Enum.map(fn {command, index} ->
            Map.put(command, "id", "#{command["command_id"]}-#{index}")
          end)

        socket
        |> assign(:gateway_audit_count, length(commands))
        |> stream(:gateway_audit, commands, reset: true)

      {:error, _reason} ->
        socket
    end
  end

  defp put_freezers(socket, freezers) do
    Enum.reduce(freezers, socket, fn freezer, acc ->
      stream_insert(acc, :freezers, freezer)
    end)
  end

  defp refresh_audit(socket) do
    case LegacyController.list_audit(socket.assigns.base_url) do
      {:ok, entries} ->
        entries =
          entries
          |> Enum.with_index()
          |> Enum.map(fn {entry, index} -> Map.put(entry, "id", "#{entry["at_ms"]}-#{index}") end)

        socket
        |> assign(:audit_count, length(entries))
        |> stream(:audit, entries, reset: true)

      {:error, _reason} ->
        socket
    end
  end

  defp update_readings(readings, freezers) do
    Enum.reduce(freezers, readings, fn freezer, acc ->
      id = freezer["id"]
      history = Map.get(acc, id, [])
      Map.put(acc, id, Enum.take([freezer["current_c"] | history], @history_points))
    end)
  end

  defp alarm_label("ok"), do: "nominal"
  defp alarm_label("at_risk"), do: "at risk"
  defp alarm_label("spoiled"), do: "spoiled"
  defp alarm_label(_), do: "unknown"

  defp alarm_border("at_risk"), do: "border-amber-500/40"
  defp alarm_border("spoiled"), do: "border-red-500/50"
  defp alarm_border(_), do: "border-slate-800"

  defp alarm_badge("ok"), do: "border-emerald-500/20 bg-emerald-500/10 text-emerald-300"
  defp alarm_badge("at_risk"), do: "border-amber-500/30 bg-amber-500/10 text-amber-300"
  defp alarm_badge("spoiled"), do: "border-red-500/30 bg-red-500/10 text-red-300"
  defp alarm_badge(_), do: "border-slate-700 bg-slate-800 text-slate-400"

  defp temp_class("at_risk"), do: "text-amber-300"
  defp temp_class("spoiled"), do: "text-red-300"
  defp temp_class(_), do: "text-white"

  defp sparkline_class("at_risk"), do: "text-amber-400/80"
  defp sparkline_class("spoiled"), do: "text-red-400/80"
  defp sparkline_class(_), do: "text-emerald-400/70"

  defp attack_result_class(:success), do: "border-red-400/30 bg-red-500/10 text-red-100"
  defp attack_result_class(:error), do: "border-slate-600/30 bg-slate-800/40 text-slate-300"

  defp mode_label("cooling"), do: "cooling"
  defp mode_label("defrost"), do: "defrost"
  defp mode_label("off"), do: "off"
  defp mode_label(other), do: other

  defp format_time(nil), do: "—"

  defp format_time(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp format_report(report) when is_map(report) do
    sealed = if Map.get(report, :sealed, 0) == 1, do: "sealed", else: "clear"
    provider = report |> Map.get(:provider) |> hex()
    key = report |> Map.get(:seal_key_id) |> hex()
    "#{sealed} · provider #{provider} · key #{key}"
  end

  defp format_report(_other), do: nil

  defp hex(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)
  defp hex(_other), do: "—"

  defp sparkline_points([]), do: "0,16 120,16"

  defp sparkline_points(readings) do
    values = Enum.reverse(readings)
    min = Enum.min(values)
    max = Enum.max(values)
    count = length(values)
    range = max - min

    values
    |> Enum.with_index()
    |> Enum.map(fn {value, index} ->
      x = if count == 1, do: 0.0, else: index / (count - 1) * 120
      y = if range == 0, do: 16.0, else: 28 - (value - min) / range * 24

      "#{Float.round(x, 1)},#{Float.round(y, 1)}"
    end)
    |> Enum.join(" ")
  end

  defp presets(_freezer) do
    [
      %{
        label: "−25",
        value: "-25",
        title: "Set target to −25°C",
        class: "border-sky-500/20 bg-sky-500/10 text-sky-200 hover:bg-sky-500/20"
      },
      %{
        label: "−18",
        value: "-18",
        title: "Set target to −18°C",
        class: "border-cyan-500/20 bg-cyan-500/10 text-cyan-200 hover:bg-cyan-500/20"
      },
      %{
        label: "+4",
        value: "4",
        title: "Set target to +4°C",
        class: "border-teal-500/20 bg-teal-500/10 text-teal-200 hover:bg-teal-500/20"
      },
      %{
        label: "+30",
        value: "30",
        title: "Set target to +30°C",
        class: "border-amber-500/20 bg-amber-500/10 text-amber-200 hover:bg-amber-500/20"
      },
      %{
        label: "+50",
        value: "50",
        title: "Set target to +50°C",
        class: "border-red-500/20 bg-red-500/10 text-red-200 hover:bg-red-500/20"
      }
    ]
  end

  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :tone, :atom, required: true
  attr :detail, :string, required: true

  defp posture_card(assigns) do
    ~H"""
    <article class={["rounded-2xl border bg-slate-900/60 p-4", posture_border(@tone)]}>
      <div class="flex items-center justify-between gap-3">
        <p class="text-[10px] font-medium uppercase tracking-[0.2em] text-slate-500">{@title}</p>
        <span class={["size-2 rounded-full", posture_dot(@tone)]}></span>
      </div>
      <p class={["mt-3 text-lg font-semibold tracking-tight", posture_value(@tone)]}>{@value}</p>
      <p class="mt-2 text-xs leading-5 text-slate-400">{@detail}</p>
    </article>
    """
  end

  defp posture_border(:danger), do: "border-red-500/30"
  defp posture_border(:warning), do: "border-amber-500/30"
  defp posture_border(:success), do: "border-emerald-500/30"

  defp posture_dot(:danger), do: "bg-red-400"
  defp posture_dot(:warning), do: "bg-amber-400"
  defp posture_dot(:success), do: "bg-emerald-400"

  defp posture_value(:danger), do: "text-red-200"
  defp posture_value(:warning), do: "text-amber-200"
  defp posture_value(:success), do: "text-emerald-200"

  attr :freezer, :map, required: true
  attr :readings, :list, required: true
  attr :writes_enabled?, :boolean, default: false

  defp freezer_card(assigns) do
    ~H"""
    <article class={[
      "group relative flex h-full flex-col justify-between overflow-hidden rounded-2xl border bg-slate-900/70 p-4 shadow-lg shadow-black/10 transition duration-200 hover:-translate-y-0.5 hover:shadow-xl",
      alarm_border(@freezer["alarm"])
    ]}>
      <div class="flex items-start justify-between gap-3">
        <div>
          <p class="font-mono text-[11px] uppercase tracking-[0.2em] text-slate-500">
            {@freezer["id"]}
          </p>
          <h3 class="mt-1 text-sm font-semibold text-white">{@freezer["name"]}</h3>
        </div>
        <span class={[
          "rounded-full border px-2 py-0.5 text-[10px] font-medium uppercase tracking-wider",
          alarm_badge(@freezer["alarm"])
        ]}>
          {alarm_label(@freezer["alarm"])}
        </span>
      </div>

      <div class="mt-6 flex items-end justify-between gap-3">
        <div>
          <p class={["text-4xl font-semibold tracking-tight", temp_class(@freezer["alarm"])]}>
            {@freezer["current_c"]}<span class="text-lg text-slate-500">°C</span>
          </p>
          <p class="mt-1 text-xs text-slate-500">
            target <span class="font-medium text-slate-300">{@freezer["target_c"]}°C</span>
            · {mode_label(@freezer["mode"])}
          </p>
        </div>
        <div class="w-24">
          <.sparkline readings={@readings} class={sparkline_class(@freezer["alarm"])} />
        </div>
      </div>

      <div class="mt-4 flex items-center justify-between gap-2 border-t border-slate-800 pt-3 text-xs text-slate-500">
        <span>stock <span class="font-medium text-slate-300">€{@freezer["stock_value_eur"]}</span></span>
        <span>safe {@freezer["safe_min_c"]} … {@freezer["safe_max_c"]}°C</span>
      </div>

      <div class="mt-3 flex flex-wrap gap-1.5">
        <button
          :for={preset <- presets(@freezer)}
          phx-click="set_target"
          phx-value-id={@freezer["id"]}
          phx-value-target={preset.value}
          title={preset.title}
          disabled={!@writes_enabled?}
          class={[
            "rounded-lg border px-2 py-1 text-[11px] font-medium transition disabled:cursor-not-allowed disabled:opacity-40",
            preset.class
          ]}
        >
          {preset.label}
        </button>
        <button
          phx-click="start_defrost"
          phx-value-id={@freezer["id"]}
          disabled={!@writes_enabled?}
          class="rounded-lg border border-amber-500/20 bg-amber-500/10 px-2 py-1 text-[11px] font-medium text-amber-200 transition hover:bg-amber-500/20 disabled:cursor-not-allowed disabled:opacity-40"
        >
          Defrost
        </button>
        <button
          phx-click="stop_defrost"
          phx-value-id={@freezer["id"]}
          disabled={!@writes_enabled?}
          class="rounded-lg border border-slate-700 bg-slate-800/60 px-2 py-1 text-[11px] font-medium text-slate-300 transition hover:bg-slate-800 disabled:cursor-not-allowed disabled:opacity-40"
        >
          Stop
        </button>
      </div>

      <p :if={!@writes_enabled?} class="mt-2 text-[10px] text-slate-600">
        Sign in (Legacy mode) or wait for the Mesh client to enable write controls.
      </p>
    </article>
    """
  end

  attr :readings, :list, required: true
  attr :class, :string, default: nil

  defp sparkline(assigns) do
    ~H"""
    <svg
      viewBox="0 0 120 32"
      class={["h-8 w-full", @class]}
      preserveAspectRatio="none"
      aria-hidden="true"
    >
      <polyline
        points={sparkline_points(@readings)}
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
        vector-effect="non-scaling-stroke"
      />
    </svg>
    """
  end
end
