"""Launches the hip/knee ODrive axes, two CubeMars AK-V3 wheel motors
(AK60-6 model), and the main_ctrl teleop node, as a single bringup.

Nodes:
    hip        -- odrive_can/odrive_can_node,  namespace 'hip',    node_id 0
    knee       -- odrive_can/odrive_can_node,  namespace 'knee',   node_id 1
    wheel1     -- ak_v3_driver/motor_driver_node, namespace 'wheel1', can_id 1
    wheel2     -- ak_v3_driver/motor_driver_node, namespace 'wheel2', can_id 2
    main_ctrl  -- main_ctrl/main_ctrl, unnamespaced

NOTE: main_ctrl_node subscribes to '/joy' (sensor_msgs/Joy) but no
joystick driver is started here -- run `ros2 run joy joy_node` (or add it
to this launch file) separately, or the node will just sit idle since
joy_callback() never fires.

Both wheel motors are on the same physical CAN bus (can0) -- this is fine,
each ak_v3_driver node instance filters to its own can_id in software (see
ak_v3_driver's README, "Multiple Motors" section) so they don't interfere
with each other.

Per-node topics/services come out node-relative under each namespace, e.g.:
    /hip/control_message,    /hip/controller_status, ...
    /knee/control_message,   /knee/controller_status, ...
    /wheel1/ak_v3_driver_node/cmd, /wheel1/ak_v3_driver_node/state, ...
    /wheel2/ak_v3_driver_node/cmd, /wheel2/ak_v3_driver_node/state, ...
which matches what main_ctrl_node.py subscribes/publishes to.

NOTE: the wheel motors' CAN interface must already be brought up
externally before launching (ak_v3_driver does not configure bitrate or
bring the link up itself):
    sudo ip link set can0 up type can bitrate 1000000

Hip/knee are set to 'can0' below to match the interface used in the
original boom_launch.py -- if your ODrive axes and AK-V3 wheel
controllers are actually wired to separate physical CAN buses, change
their 'interface' params to whichever SocketCAN interface (e.g. 'can1')
the ODrives are really on.
"""

from launch import LaunchDescription
from launch_ros.actions import Node
from launch.actions import TimerAction
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
import launch


def generate_launch_description():
    # --- ODrive hip/knee axes ---
    hip = Node(
        package="odrive_can",
        executable="odrive_can_node",
        name="hip",
        namespace="hip",
        parameters=[
            {
                "node_id": 0,
                "interface": "can0",
                "axis_idle_on_shutdown": True,
            }
        ],
    )

    knee = Node(
        package="odrive_can",
        executable="odrive_can_node",
        name="knee",
        namespace="knee",
        parameters=[
            {
                "node_id": 1,
                "interface": "can0",
                "axis_idle_on_shutdown": True,
            }
        ],
    )

    # --- CubeMars AK-V3 wheel motors (AK60-6) ---
    # Both share can0; each node only reacts to its own can_id.
    wheel1 = Node(
        package="ak_v3_driver",
        executable="motor_driver_node",
        name="ak_v3_driver_node",
        namespace="wheel1",
        parameters=[
            {
                "can_interface": "can0",
                "can_id": 2,
                "joint_name": "wheel1",
                "motor_type": "AK60-6",
                "invert_direction": False,
            }
        ],
    )

    wheel2 = Node(
        package="ak_v3_driver",
        executable="motor_driver_node",
        name="ak_v3_driver_node",
        namespace="wheel2",
        parameters=[
            {
                "can_interface": "can0",
                "can_id": 3,
                "joint_name": "wheel2",
                "motor_type": "AK60-6",
                "invert_direction": False,
            }
        ],
    )

    # --- Main teleop/control loop ---
    main_ctrl_node = Node(
        package="main_ctrl",
        executable="main_ctrl",
        name="main_ctrl_node",
    )

    joy_node = Node(
        package="joy",
        executable="joy_node",
        name="joy_node",
        parameters=[
            {
                "deadzone": 0.1,
                "dev": "/dev/input/js0",
                "coalesce_interval": 0.05,
            }
        ],
    )

    return LaunchDescription(
        [
            hip,
            knee,
            wheel1,
            wheel2,
            main_ctrl_node,
            joy_node,
        ]
    )

