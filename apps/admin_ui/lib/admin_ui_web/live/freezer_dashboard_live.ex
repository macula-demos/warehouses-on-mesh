defmodule AdminUiWeb.FreezerDashboardLive do
  use AdminUiWeb, :live_view

  alias AdminUi.MeshClient

  @tick_ms 1_000
  @history_points 40

  @impl true
  def mount(_params, _session, socket) do
    snapshot = MeshClient.snapshot()

    socket =
      socket
      |> assign(:page_title, "Warehouses on mesh")
      |> assign(:selected_site, "A")
      |> assign(:snapshot, snapshot)
      |> assign(:sites, snapshot.sites)
      |> assign(:providers, snapshot.providers)
      |> assign(:station_ids, snapshot.station_ids)
      |> assign(:version, snapshot.version)
      |> assign(:display_version, -1)
      |> assign(:mesh_ready?, snapshot.status == :connected)
      |> assign(:operator_node_id, snapshot.operator_node_id)
      |> assign(:stranger_node_id, snapshot.stranger_node_id)
      |> assign(:report_override, nil)
      |> assign(:last_report, nil)
      |> assign(:last_action, nil)
      |> assign(:error, snapshot.last_error)
      |> assign(:readings, %{})
      |> assign(:selected_freezers, [])
      |> assign(:selected_audit, [])
      |> stream(:freezers, [], dom_id: &"freezer-#{&1["id"]}")
      |> stream(:gateway_audit, [], dom_id: &"gateway-audit-#{&1["id"]}")

    if connected?(socket), do: Process.send_after(self(), :tick, 0)

    {:ok, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    socket = refresh_from_snapshot(socket, MeshClient.snapshot())
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_site", %{"site" => site}, socket) when site in ["A", "B"] do
    socket =
      socket
      |> assign(:selected_site, site)
      |> assign(:display_version, -1)
      |> assign(:report_override, nil)
      |> assign(:last_action, nil)
      |> refresh_from_snapshot(MeshClient.snapshot())

    {:noreply, socket}
  end

  def handle_event("set_target", %{"id" => id, "target" => target}, socket) do
    case Float.parse(target) do
      {target_c, ""} ->
        case MeshClient.set_freezer_target(socket.assigns.selected_site, id, target_c) do
          {:ok, freezer, report} ->
            write_ok(
              socket,
              freezer,
              report,
              "Gateway accepted #{id} target #{target_c}°C (sealed)."
            )

          {:error, reason} ->
            write_error(socket, reason)
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid target temperature.")}
    end
  end

  def handle_event("start_defrost", %{"id" => id}, socket) do
    case MeshClient.start_defrost(socket.assigns.selected_site, id) do
      {:ok, freezer, report} ->
        write_ok(socket, freezer, report, "Started defrost on #{id} (sealed).")

      {:error, reason} ->
        write_error(socket, reason)
    end
  end

  def handle_event("stop_defrost", %{"id" => id}, socket) do
    case MeshClient.stop_defrost(socket.assigns.selected_site, id) do
      {:ok, freezer, report} ->
        write_ok(socket, freezer, report, "Stopped defrost on #{id} (sealed).")

      {:error, reason} ->
        write_error(socket, reason)
    end
  end

  def handle_event("replay_last", _params, socket) do
    case MeshClient.replay_last() do
      {:ok, freezer, report} ->
        write_ok(socket, freezer, report, "Replayed command accepted (unexpected).")

      {:error, reason} ->
        output =
          socket
          |> put_flash(:error, "Command refused: #{format_reason(reason)}")
          |> assign(:last_action, "replay")
          |> assign(:last_report, nil)

        MeshClient.refresh_now()
        {:noreply, output}
    end
  end

  def handle_event("stranger_write", _params, socket) do
    case stranger_target(socket.assigns.sites, socket.assigns.selected_site) do
      nil ->
        {:noreply, put_flash(socket, :error, "Site B has not resolved a provider yet.")}

      {site, freezer} ->
        case MeshClient.stranger_set_target(site, freezer["id"], 60.0) do
          {:ok, freezer, report} ->
            write_ok(socket, freezer, report, "Stranger write accepted (unexpected).")

          {:error, reason} ->
            output =
              socket
              |> put_flash(
                :error,
                "Stranger #{short_id(MeshClient.stranger_node_id())} on site #{site} refused: #{format_reason(reason)}"
              )
              |> assign(:last_action, "stranger")
              |> assign(:last_report, nil)

            MeshClient.refresh_now()
            {:noreply, output}
        end
    end
  end

  defp refresh_from_snapshot(socket, snapshot) do
    selected_site = socket.assigns.selected_site
    selected = Map.get(snapshot.sites, selected_site)
    version_changed? = snapshot.version != socket.assigns.display_version

    socket =
      socket
      |> assign(:snapshot, snapshot)
      |> assign(:sites, snapshot.sites)
      |> assign(:providers, snapshot.providers)
      |> assign(:station_ids, snapshot.station_ids)
      |> assign(:version, snapshot.version)
      |> assign(:mesh_ready?, snapshot.status == :connected)
      |> assign(:operator_node_id, snapshot.operator_node_id)
      |> assign(:stranger_node_id, snapshot.stranger_node_id)
      |> assign(:error, snapshot.last_error)

    if version_changed? do
      reset? = socket.assigns.display_version == -1
      freezers = if selected, do: selected.freezers, else: []
      audit = if selected, do: selected.audit, else: []

      report =
        cond do
          socket.assigns.report_override -> socket.assigns.report_override
          selected -> selected.report
          true -> nil
        end

      socket =
        socket
        |> assign(:display_version, snapshot.version)
        |> assign(:selected_freezers, freezers)
        |> assign(:selected_audit, audit)
        |> assign(:last_report, report)
        |> assign(:readings, update_readings(socket.assigns.readings, freezers))
        |> put_freezers(freezers, reset?)
        |> put_audit(audit)

      socket
    else
      socket
    end
  end

  defp put_freezers(socket, freezers, reset?) do
    if reset? do
      stream(socket, :freezers, freezers, reset: true)
    else
      Enum.reduce(freezers, socket, fn freezer, acc ->
        stream_insert(acc, :freezers, freezer)
      end)
    end
  end

  defp put_audit(socket, commands) do
    commands =
      commands
      |> Enum.with_index()
      |> Enum.map(fn {command, index} ->
        Map.put(command, "id", "#{command["command_id"]}-#{index}")
      end)

    stream(socket, :gateway_audit, commands, reset: true)
  end

  defp write_ok(socket, freezer, report, message) do
    {:noreply,
     socket
     |> stream_insert(:freezers, freezer)
     |> assign(:report_override, report)
     |> assign(:last_action, message)
     |> assign(:last_report, report)
     |> put_flash(:info, message)}
  end

  defp write_error(socket, reason) do
    output =
      socket
      |> put_flash(:error, "Command refused: #{format_reason(reason)}")
      |> assign(:last_action, "refused")
      |> assign(:last_report, nil)

    MeshClient.refresh_now()
    {:noreply, output}
  end

  defp stranger_target(sites, fallback_site) do
    preferred =
      case Map.get(sites, "B") do
        %{freezers: [freezer | _]} -> {"B", freezer}
        _ -> nil
      end

    preferred ||
      case Map.get(sites, fallback_site) do
        %{freezers: [freezer | _]} -> {fallback_site, freezer}
        _ -> nil
      end
  end

  defp update_readings(readings, freezers) do
    Enum.reduce(freezers, readings, fn freezer, acc ->
      id = freezer["id"]
      history = Map.get(acc, id, [])
      Map.put(acc, id, Enum.take([freezer["current_c"] | history], @history_points))
    end)
  end

  defp format_reason(:command_replayed),
    do: "command_replayed (the gateway already saw this command id)"

  defp format_reason(:command_expired),
    do: "command_expired (the command timestamp is outside the gateway window)"

  defp format_reason(:site_unresolved),
    do: "the site has not resolved a provider yet"

  defp format_reason({:call_error, "command_replayed", _detail}),
    do: "command_replayed (the gateway already saw this command id)"

  defp format_reason({:call_error, "command_expired", _detail}),
    do: "command_expired (the command timestamp is outside the gateway window)"

  defp format_reason({:call_error, "unauthorized", _detail}),
    do: "unauthorized (this node is not on the gateway's operator list)"

  defp format_reason({:call_error, reason, _detail}) when is_binary(reason), do: reason

  defp format_reason({:unresolved, reason}),
    do: "no trusted provider (#{format_reason(reason)})"

  defp format_reason({:dial_refused, reason}),
    do: "dial refused (#{reason})"

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp short_id(nil), do: "—"

  defp short_id(id) when is_binary(id) do
    if String.length(id) > 12, do: String.slice(id, 0, 12) <> "…", else: id
  end

  defp short_id(other), do: inspect(other)

  defp format_time(nil), do: "—"

  defp format_time(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp format_report(nil), do: "—"

  defp format_report(report) when is_map(report) do
    sealed = if Map.get(report, :sealed, 0) == 1, do: "sealed", else: "clear"
    provider = report |> Map.get(:provider) |> hex()
    key = report |> Map.get(:seal_key_id) |> hex()
    "#{sealed} · provider #{provider} · key #{key}"
  end

  defp hex(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)
  defp hex(_other), do: "—"

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

  defp mode_label("cooling"), do: "cooling"
  defp mode_label("defrost"), do: "defrost"
  defp mode_label("off"), do: "off"
  defp mode_label(other), do: other

  defp site_label("A"), do: "Site A"
  defp site_label("B"), do: "Site B"
  defp site_label(_), do: "Site —"

  defp site_path("A"), do: "local station"
  defp site_path("B"), do: "via relay"
  defp site_path(_), do: "unresolved"

  defp site_badge("A"), do: "border-cyan-500/30 bg-cyan-500/10 text-cyan-200"
  defp site_badge("B"), do: "border-violet-500/30 bg-violet-500/10 text-violet-200"
  defp site_badge(_), do: "border-slate-700 bg-slate-800 text-slate-400"

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

  attr :site_id, :string, required: true
  attr :provider, :string, default: nil
  attr :station, :string, default: nil
  attr :freezers, :list, default: []
  attr :selected?, :boolean, default: false

  defp site_card(assigns) do
    ~H"""
    <button
      phx-click="switch_site"
      phx-value-site={@site_id}
      class={[
        "w-full rounded-2xl border p-4 text-left transition",
        if(@selected?,
          do: "border-cyan-400/40 bg-cyan-500/10 shadow-lg shadow-cyan-500/5",
          else: "border-slate-800 bg-slate-900/60 hover:border-slate-700 hover:bg-slate-900"
        )
      ]}
    >
      <div class="flex items-center justify-between gap-3">
        <span class={[
          "rounded-full border px-2 py-0.5 text-[10px] font-medium uppercase tracking-wider",
          site_badge(@site_id)
        ]}>
          {site_label(@site_id)}
        </span>
        <span class="text-[10px] uppercase tracking-[0.2em] text-slate-500">
          {site_path(@site_id)}
        </span>
      </div>
      <p class="mt-3 text-2xl font-semibold tracking-tight text-white">
        {length(@freezers)}<span class="ml-1 text-xs font-normal text-slate-500">freezers</span>
      </p>
      <p class="mt-2 font-mono text-[10px] text-slate-500">
        gateway {@provider || "resolving provider…"}
      </p>
      <p class="mt-1 font-mono text-[10px] text-slate-600">
        station {@station || "—"}
      </p>
    </button>
    """
  end

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
