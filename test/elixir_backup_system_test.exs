defmodule ElixirBackupSystemTest do
  use ExUnit.Case
  doctest ElixirBackupSystem

  test "greets the world" do
    assert ElixirBackupSystem.hello() == :world
  end
end
