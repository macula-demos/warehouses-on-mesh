defmodule FreezerController.FreezerSimulatorTest do
  use ExUnit.Case, async: false

  alias FreezerController.FreezerSimulator

  setup do
    :ok = FreezerSimulator.reset()
    :ok
  end

  test "lists the four simulated freezers" do
    assert {:ok, freezers} = FreezerSimulator.list()
    assert length(freezers) == 4
    assert Enum.any?(freezers, &(&1.id == "FZ-A1"))
    assert Enum.any?(freezers, &(&1.id == "FZ-A4"))
  end

  test "sets a target and returns to cooling" do
    assert {:ok, freezer} = FreezerSimulator.set_target("FZ-A1", 50)
    assert freezer.target_c == 50.0
    assert freezer.mode == "cooling"
  end

  test "rejects a target outside the controller's range" do
    assert {:error, :invalid_target} = FreezerSimulator.set_target("FZ-A1", 100)
    assert {:error, :invalid_target} = FreezerSimulator.set_target("FZ-A1", "cold")
  end

  test "returns not_found for an unknown freezer" do
    assert {:error, :not_found} = FreezerSimulator.get("FZ-A99")
    assert {:error, :not_found} = FreezerSimulator.set_target("FZ-A99", 4)
  end

  test "starts and stops a defrost" do
    assert {:ok, freezer} = FreezerSimulator.start_defrost("FZ-A1")
    assert freezer.mode == "defrost"

    assert {:ok, freezer} = FreezerSimulator.stop_defrost("FZ-A1")
    assert freezer.mode == "cooling"
    assert freezer.target_c == -18.0
  end
end
