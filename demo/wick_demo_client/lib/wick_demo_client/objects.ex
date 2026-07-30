defmodule WickDemoClient.Objects do
  @moduledoc """
  The demo client's Object inventory, as a `Wick.Object.Tree`.

  Previously this module answered a handful of hard-coded Reads. Now that Device Management
  is implemented it builds a real value tree, which is what makes the client answerable: a
  server can Read, Write, Discover, Create, and Delete against it.

  Three Objects are provisioned at boot:

  | Object | Name        | Why |
  |--------|-------------|-----|
  | `1`    | Server      | The Server Account. A registered client is required to have one, and it is what a Bootstrap-Write provisions. |
  | `3`    | Device      | Mandatory for every LwM2M client (§C.3). Manufacturer, model, serial, firmware, and an Execute-only Reboot Resource. |
  | `3303` | Temperature | An IPSO sensor, so there is something that *changes* — the point of Observe. `WickDemoClient.Sensor` drives it. |

  Values are `{type, value}` tuples using `Wick.Value`'s tags, because SenML cannot tell an
  Integer from a Float or a String from an Opaque on its own. See `Wick.Object.Tree`.
  """

  alias Wick.Object.Tree

  @manufacturer "Finnlytics"
  @model "WickDemoClient"
  @firmware "0.1.0-dev"

  # Object 3 (Device) Resource IDs, per LwM2M Core §C.3.
  @device_manufacturer 0
  @device_model 1
  @device_serial 2
  @device_firmware 3
  @device_reboot 4
  @device_error_code 11
  @device_timezone 15
  @device_binding 16

  # Object 1 (Server) Resource IDs, per LwM2M Core §C.2.
  @server_short_id 0
  @server_lifetime 1
  @server_notification_storing 6
  @server_binding 7

  # Object 3303 (IPSO Temperature) Resource IDs.
  @sensor_value 5700
  @sensor_units 5701
  @sensor_min_measured 5601
  @sensor_max_measured 5602

  @doc "The Object 3303 path whose value changes — what the sensor writes and servers observe."
  @spec temperature_path() :: Wick.Path.t()
  def temperature_path do
    %Wick.Path{object_id: 3303, object_instance_id: 0, resource_id: @sensor_value}
  end

  @doc "The Object 3 Reboot Resource — Execute-only, no value."
  @spec reboot_path() :: Wick.Path.t()
  def reboot_path do
    %Wick.Path{object_id: 3, object_instance_id: 0, resource_id: @device_reboot}
  end

  @doc """
  Build the tree the client starts life with.

  `lifetime` seeds `/1/0/1` so the Server Object agrees with what the Registrar actually
  puts on the wire — a mismatch there is a classic source of confusion when debugging
  registration lifetimes against a real server.
  """
  @spec initial_tree(pos_integer()) :: Tree.t()
  def initial_tree(lifetime \\ 60) do
    Tree.from_map(%{
      1 => %{
        0 => %{
          @server_short_id => {:integer, 101},
          @server_lifetime => {:integer, lifetime},
          @server_notification_storing => {:boolean, false},
          @server_binding => {:string, "U"}
        }
      },
      3 => %{
        0 => %{
          @device_manufacturer => {:string, @manufacturer},
          @device_model => {:string, @model},
          @device_serial => {:string, serial_number()},
          @device_firmware => {:string, @firmware},
          @device_error_code => {:integer, 0},
          @device_timezone => {:string, "+00:00"},
          @device_binding => {:string, "U"}
        }
      },
      3303 => %{
        0 => %{
          @sensor_value => {:float, 20.0},
          @sensor_units => {:string, "Cel"},
          @sensor_min_measured => {:float, 20.0},
          @sensor_max_measured => {:float, 20.0}
        }
      }
    })
  end

  @doc """
  Links advertised in the Register payload — one per Object Instance the client holds.

  Derived from the tree rather than hard-coded, so a Bootstrap-Write or a Create changes
  what the next Update advertises without anyone remembering to edit a list.
  """
  @spec links(Tree.t()) :: [Wick.CoreLink.Link.t()]
  def links(%Tree{} = tree), do: Tree.links(tree)

  @doc """
  Fold a new temperature reading into the tree, keeping the min/max measured Resources
  honest — a real IPSO sensor is expected to maintain them.
  """
  @spec record_temperature(Tree.t(), float()) :: Tree.t()
  def record_temperature(%Tree{} = tree, reading) when is_float(reading) do
    min_path = %Wick.Path{
      object_id: 3303,
      object_instance_id: 0,
      resource_id: @sensor_min_measured
    }

    max_path = %Wick.Path{
      object_id: 3303,
      object_instance_id: 0,
      resource_id: @sensor_max_measured
    }

    tree
    |> Tree.put(temperature_path(), {:float, reading})
    |> update_extreme(min_path, reading, &min/2)
    |> update_extreme(max_path, reading, &max/2)
  end

  @doc "Stable per-VM serial number so logs and tests can correlate sessions."
  @spec serial_number() :: String.t()
  def serial_number do
    # Derive from the node name + system version so two clients in the same cluster don't
    # collide. Not security-sensitive — just a logical identifier.
    {node(), :erlang.system_info(:system_version)}
    |> :erlang.phash2(1_000_000_000)
    |> Integer.to_string()
  end

  defp update_extreme(tree, path, reading, chooser) do
    case Tree.fetch(tree, path) do
      {:ok, {:float, current}} -> Tree.put(tree, path, {:float, chooser.(current, reading)})
      _unset -> Tree.put(tree, path, {:float, reading})
    end
  end
end
