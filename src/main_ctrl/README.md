# main_ctrl

ROS 2 (ament_python) package containing the robot's main teleop/control
loop. Reads joystick input on `/joy` and maps it to:

- ODrive `ControlMessage` commands for the `hip` and `knee` axes
  (`/hip/control_message`, `/knee/control_message`), plus axis-state
  service calls (`/hip/request_axis_state`, `/knee/request_axis_state`)
  to enter/exit closed-loop control.
- AK-V3 (CubeMars) `MotorCommand` commands for two wheel motors
  (`/wheel1/ak_v3_driver_node/cmd`, `/wheel2/ak_v3_driver_node/cmd`).

A single node, `main_ctrl_node`, does all of this; `~/joy` drives a
"safety on/off" state machine (Start button toggles it) and a 200 Hz-ish
(`0.005s`) timer republishes the current commanded state to both ODrive
axes and both wheel motors.

## Package Layout

```
main_ctrl/
├── package.xml
├── setup.py
├── setup.cfg
├── resource/
│   └── main_ctrl
├── main_ctrl/
│   ├── __init__.py
│   └── main_ctrl_node.py
└── launch/
    └── boom_launch.py
```

## Dependencies

ROS message/service packages (resolved via rosdep from `package.xml`):
`rclpy`, `sensor_msgs`, `odrive_can` (ODrive ROS2 driver -- provides
`ControlMessage`/`ControllerStatus`/`ODriveStatus` and the `AxisState`
service), `ak_v3_driver` (this repo's CubeMars driver -- provides
`MotorCommand`/`MotorState`), and `interfaces` (a project-local package
that must define `interfaces/msg/BoomWheelCmds.msg` -- not included here,
since it's referenced but not defined in the source this package was
built from).

Non-ROS Python dependency: **`gpiozero`** (used for the status LEDs and
the demo-mode toggle button on the GPIO header). This is a plain `pip`
package, not resolvable via rosdep, so install it separately:

```bash
pip install gpiozero
```

`gpiozero` talks to real GPIO pins, so this node is only runnable as-is
on hardware with GPIO access (e.g. a Raspberry Pi) unless you mock it out.

## Building

```bash
# from the root of your colcon workspace
colcon build --packages-select main_ctrl
source install/setup.bash
```

## Running

```bash
ros2 run main_ctrl main_ctrl
```

or via the bundled launch file, which also brings up the `hip`/`knee`
ODrive nodes, the wheel controller, and a joystick node:

```bash
ros2 launch main_ctrl boom_launch.py
```

## Notes on the source this was packaged from

A few bugs in the original script would have crashed the node at
runtime; they were fixed while packaging (each is flagged with a
`# FIX:` comment in `main_ctrl/main_ctrl_node.py`):

1. `self.odrive_initialized` was read in `joy_callback()` but never
   assigned anywhere -- added the attribute, set `True` once
   `initialize()` finishes wiring everything up.
2. `self.wheel1_pub` / `self.wheel2_pub` were built with
   `create_subscription(...)` instead of `create_publisher(...)` (and
   were missing a QoS argument) -- `publish_cubemars_commands()` would
   have failed the first time it ran. Switched both to
   `create_publisher(...)`.
3. `self.wheel2_sub` was subscribed to `/wheel1/ak_v3_driver_node/state`
   (the same topic as `wheel1_sub`) instead of `/wheel2/...` -- fixed to
   point at wheel2's own state topic.
4. `self.get_logger.info(...)` was missing the `()` call on
   `get_logger` -- fixed to `self.get_logger().info(...)`.
5. `wheel1_callback` / `wheel2_callback` were declared with no `msg`
   parameter despite being registered as subscription callbacks (rclpy
   passes the received message positionally) -- added the parameter.

Two things worth a look that were **not** changed, since they're
design/logic questions rather than crashes:

- `left_knee_vel` is computed from `self.right_stick_ud` (the original
  file's comment even flags this as the left/right stick), and is never
  actually used anywhere after being computed/clamped -- only
  `right_knee_vel` drives both hip/knee messages below it.
- `main()` calls `main_ctrl_loop.destroy_node()` **after** `rclpy.spin()`
  returns, but `spin()` only returns on shutdown/exception, so this is
  fine as written -- just flagging it since `destroy_node()` also cancels
  `motor_timer`, which is otherwise never explicitly stopped.
