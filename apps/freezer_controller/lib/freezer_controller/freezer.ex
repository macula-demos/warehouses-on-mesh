defmodule FreezerController.Freezer do
  @moduledoc false

  @enforce_keys [
    :id,
    :name,
    :kind,
    :current_c,
    :target_c,
    :safe_min_c,
    :safe_max_c,
    :stock_value_eur
  ]

  defstruct [
    :id,
    :name,
    :kind,
    :current_c,
    :target_c,
    :safe_min_c,
    :safe_max_c,
    :stock_value_eur,
    :last_changed_at_ms,
    mode: :cooling,
    door_open: false,
    alarm: :ok,
    at_risk_since: nil
  ]

  @type kind :: :frozen | :chilled
  @type mode :: :cooling | :defrost | :off
  @type alarm :: :ok | :at_risk | :spoiled

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          kind: kind(),
          current_c: float(),
          target_c: float(),
          safe_min_c: float(),
          safe_max_c: float(),
          stock_value_eur: non_neg_integer(),
          mode: mode(),
          door_open: boolean(),
          alarm: alarm(),
          at_risk_since: integer() | nil,
          last_changed_at_ms: integer() | nil
        }

  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{} = freezer) do
    %{
      id: freezer.id,
      name: freezer.name,
      kind: Atom.to_string(freezer.kind),
      current_c: round1(freezer.current_c),
      target_c: round1(freezer.target_c),
      mode: Atom.to_string(freezer.mode),
      door_open: freezer.door_open,
      safe_min_c: freezer.safe_min_c,
      safe_max_c: freezer.safe_max_c,
      alarm: Atom.to_string(freezer.alarm),
      stock_value_eur: freezer.stock_value_eur,
      last_changed_at_ms: freezer.last_changed_at_ms
    }
  end

  defp round1(value), do: Float.round(value * 1.0, 1)
end
