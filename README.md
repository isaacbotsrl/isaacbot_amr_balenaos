<p align="center">
  <img src="icons/Logo-Arm-WhiteOrange-372x372-1.png" alt="Mechatronics Academy" width="140">
</p>

# isaacbot_amr_balenaos

Docker files to build the ARM64 balena application release for the Ardennes.
The application uses ROS 2 Lyrical on Ubuntu 26.04; the balenaOS host image
is managed separately.

Four services are deployed to the balenaCloud fleet `g_potlog_radu/rovera1`.
Each has its own folder holding its Dockerfile and any scripts, which is the
service's build context in `docker-compose.yml`:

| Service            | Folder              | Contents                                                                   |
|--------------------|---------------------|----------------------------------------------------------------------------|
| `isaacbot-amr-zenoh-router`  | `isaacbot_amr_zenoh_router/`  | Ubuntu 26.04 + `rmw_zenoh_cpp` only: the Zenoh router (`rmw_zenohd`) on 7447 that every ROS process connects to, as the container's only process. Its own service so platform restarts and releases leave the ROS graph up. See [ROS 2 over the isaacbot LAN](#ros-2-over-the-isaacbot-lan-zenoh) |
| `isaacbot-amr-platform`      | `isaacbot_amr_platform/`      | Ubuntu 26.04 + ROS 2 Lyrical + isaacbot firmware (sshd, `isaacbot_amr_bringup`, rosbridge, foxglove_bridge); `start.sh` is the entrypoint |
| `isaacbot-amr-orchestrator` | `isaacbot_amr_orchestrator/` | Ubuntu 26.04 + ROS 2 Lyrical + [`isaacbot_amr_orchestrator`](https://github.com/isaacbotsrl/isaacbot_amr_orchestrator) — the autonomy stack (Nav 2 via `isaacbot_amr_navigation`, plus `isaacbot_amr_mission_manager` and follow-me's `isaacbot_amr_follow_me`), plus an sshd on port 24 and the Claude Code CLI with `ros-mcp` registered; `start.sh` is the entrypoint. Idle unless enabled, see [Where the orchestrator runs](#where-the-orchestrator-runs) |
| `isaacbot-amr-sensors` | `isaacbot_amr_sensors/` | Ubuntu 26.04 + ROS 2 Lyrical + [`isaacbot_amr_sensors`](https://github.com/isaacbotsrl/isaacbot_amr_sensors) — the sensor payload: RUTX11 GNSS driver (`gps/fix`), RoboSense RS16 lidar driver (`scan`, `rslidar_points`) and RealSense D435i driver (`camera/*`), with their diagnostics, and [`isaacbot_amr_perception`](https://github.com/isaacbotsrl/isaacbot_amr_perception) on top of them (AprilTag, detection, terrain slope, fmoc person tracking), plus an sshd on port 23 and the Claude Code CLI with `ros-mcp` registered. Drivers only publish, so a different sensor changes this image only; `start.sh` is the entrypoint |
| `isaacbot-amr-drive-interface` | `isaacbot_amr_drive_interface/` | nginx + [`isaacbot_amr_drive_interface`](https://github.com/isaacbotsrl/isaacbot_amr_drive_interface) — Boxer / IndoorNav-style drive UI on port 5000 behind a login; nginx proxies `/ws` to foxglove_bridge (no ROS inside). Plus an sshd on port 25 and the Claude Code CLI with `ros-mcp` registered. See [Drive interface](#drive-interface) |
| `isaacbot-amr-vda5050` | `isaacbot_amr_vda5050/` | Ubuntu 26.04 + ROS 2 Lyrical + [`isaacbot_amr_vda5050`](https://github.com/isaacbotsrl/isaacbot_amr_vda5050) — the VDA 5050 2.0 fleet interface (InOrbit's MQTT connector, vendored, driving the isaacbot through `isaacbot_amr_mission_manager`), an optional Mosquitto broker (1883, WebSockets 9001), plus an sshd on port 26 and the Claude Code CLI with `ros-mcp` registered. Idle unless enabled, see [VDA 5050](#vda-5050) |
| `isaacbot-amr-network` | `isaacbot_amr_network/` | Python + [`rover_networking`](https://github.com/RaduPotlog/rover_networking) (`rutx11/`): web page on port 5080 (behind a login) that switches the RUTX11's Wi-Fi uplink in place and keeps the router's firewall/NAT consistent (no ROS, no sshd). See [Network uplink page](#network-uplink-page) |

```
isaacbot_amr_balenaos/
├── docker-compose.yml
├── isaacbot_amr_zenoh_router/
│   ├── Dockerfile
│   ├── healthcheck.sh
│   └── start.sh
├── isaacbot_amr_platform/
│   ├── Dockerfile
│   └── start.sh
├── isaacbot_amr_orchestrator/
│   ├── Dockerfile
│   └── start.sh
├── isaacbot_amr_sensors/
│   ├── Dockerfile
│   └── start.sh
├── isaacbot_amr_drive_interface/
│   ├── Dockerfile
│   ├── nginx.conf.template
│   ├── healthcheck.sh
│   └── start.sh
└── isaacbot_amr_network/
    ├── Dockerfile
    ├── healthcheck.sh
    └── start.sh
```

## Build and validate for ARM64

Run commands from `isaacbot_amr_balenaos/`. Use a Docker Buildx builder that supports
`linux/arm64`, either natively or through emulation. In WSL, enable Docker
Desktop integration for the distribution first.

```bash
bash -n isaacbot_amr_platform/start.sh
bash -n isaacbot_amr_orchestrator/start.sh
bash -n isaacbot_amr_sensors/start.sh
bash -n isaacbot_amr_drive_interface/start.sh
bash -n isaacbot_amr_drive_interface/healthcheck.sh
docker compose config --quiet
docker buildx inspect --bootstrap
docker buildx build --platform linux/arm64 --pull --no-cache --load \
  -t isaacbot-amr-platform:lyrical ./isaacbot_amr_platform
docker buildx build --platform linux/arm64 --pull --no-cache --load \
  -t isaacbot-amr-orchestrator:lyrical ./isaacbot_amr_orchestrator
docker buildx build --platform linux/arm64 --pull --no-cache --load \
  -t isaacbot-amr-sensors:lyrical ./isaacbot_amr_sensors
docker buildx build --platform linux/arm64 --pull --no-cache --load \
  -t isaacbot-amr-drive-interface:lyrical ./isaacbot_amr_drive_interface
```

The application build defaults to the `isaacbot_amr_ros` **main** branch and
imports its `hardware_deps.repos`, including the receiver and transport
dependencies. `ROS_DISTRO=lyrical` is baked into the image and
used for package installation, rosdep, compilation, and startup; do not
override it with a different distribution at runtime.

Check the built image without starting hardware bringup:

```bash
docker run --rm --platform linux/arm64 --entrypoint /bin/bash \
  isaacbot-amr-platform:lyrical -ec '
    test "$(dpkg --print-architecture)" = arm64
    test "$ROS_DISTRO" = lyrical
    source /opt/ros/$ROS_DISTRO/setup.bash
    source /root/ros2_ws/ardennes/install/setup.bash
    for package in isaacbot_amr_bringup rmw_zenoh_cpp rosbridge_server rosapi foxglove_bridge; do
      ros2 pkg prefix "$package"
    done
  '
```

The orchestrator image builds `isaacbot_amr_orchestrator` (plus the parts of `isaacbot_amr_ros` it
depends on) with `colcon build --packages-up-to isaacbot_amr_autonomy`, so the hardware packages
are never compiled there. Every `nav2_*` package, `nav2_smac_planner` included, comes from
the arm64 debs, so its prefix below is `/opt/ros/lyrical`. Check it the same way:

```bash
docker run --rm --platform linux/arm64 --entrypoint /bin/bash \
  isaacbot-amr-orchestrator:lyrical -ec '
    test "$(dpkg --print-architecture)" = arm64
    source /opt/ros/$ROS_DISTRO/setup.bash
    source /root/ros2_ws/ardennes/install/setup.bash
    for package in isaacbot_amr_autonomy isaacbot_amr_navigation isaacbot_amr_mission_manager \
                   nav2_lifecycle_manager nav2_smac_planner slam_toolbox \
                   spatio_temporal_voxel_layer rmw_zenoh_cpp; do
      ros2 pkg prefix "$package"
    done
    ros2 launch isaacbot_amr_navigation bringup.launch.py --show-args > /dev/null
  '
```

Before deployment, smoke-test `rmw_zenohd`, rosbridge, and Foxglove in an
isolated container with the entrypoint overridden (no hardware bringup),
and check workspace shared libraries with `ldd` for missing dependencies.
On the isaacbot, verify hardware bringup, the LAN Zenoh connection, and bridge ports after
deployment. A successful image build alone does not validate hardware.

See the [Docker multi-platform build documentation](https://docs.docker.com/build/building/multi-platform/)
for builder setup.

## Deploy

The fleet must use an ARM64 device type. This command builds and deploys
all services to the fleet; local validation above does not deploy them.

```bash
balena push g_potlog_radu/rovera1 --nocache
```

`--nocache` matters: every service fetches its application source with
`git clone` during the build (`isaacbot_amr_ros`; `isaacbot_amr_ros` + `isaacbot_amr_orchestrator`;
`isaacbot_amr_sensors`; `isaacbot_amr_drive_interface`; and
`rover_networking` respectively). Those
clones sit in cached layers, so a plain `balena push` will happily ship stale application
code.

Select specific application commits instead of branch tips with:

```bash
balena push g_potlog_radu/rovera1 \
  --build-arg ISAACBOT_AMR_ROS_REF=<sha> \
  --build-arg ISAACBOT_AMR_ORCHESTRATOR_REF=<sha> \
  --build-arg ISAACBOT_AMR_SENSORS_REF=<sha> \
  --build-arg ISAACBOT_AMR_NETWORKING_REF=<sha>
```

`ISAACBOT_AMR_ROS_REF` is consumed by both `isaacbot-amr-platform` and `isaacbot-amr-orchestrator`, so the
two stay on the same `isaacbot_amr_ros` commit. `ISAACBOT_AMR_SENSORS_REF` pins `isaacbot_amr_sensors` in
`isaacbot-amr-sensors`. The sensors and the platform share only topic names (`gps/fix`, `scan`,
`rslidar_points`, `diagnostics`), so their commits can move independently as long as that
contract holds.

> **Renaming note.** This repository was imported from `rover_docker`: the services were
> `rover-a1-*` (and `isaacbot-amr-platform` before that `rovera1-app`), the variables `ROVER_*`.
> balena treats a renamed service as a new one, so any *service-scoped* device or fleet variable
> set on a `rover-a1-*` service no longer applies, and the containers no longer read `ROVER_*`
> names at all. Re-create them as `ISAACBOT_AMR_*` against the new service
> (`balena env set … --service isaacbot-amr-platform`) or as all-services variables. The old
> services and their images are removed from the device on the next push.

Use a Lyrical-compatible commit for `ISAACBOT_AMR_ROS_REF`. These overrides pin
only the application repositories: imported dependency branches, base
image tags, apt packages, and npm/uv tool versions can still change. Use
`--nocache` when refreshing those dependencies even with pinned application
commits.

## Ports

All containers use host networking, so these bind directly to the device:

| Port   | Service                        |
|--------|--------------------------------|
| 22     | sshd (`isaacbot-amr-platform`)           |
| 23     | sshd (`isaacbot-amr-sensors`)            |
| 24     | sshd (`isaacbot-amr-orchestrator`)       |
| 25     | sshd (`isaacbot-amr-drive-interface`)    |
| 26     | sshd (`isaacbot-amr-vda5050`)            |
| 1883   | MQTT, VDA 5050 (`isaacbot-amr-vda5050`'s Mosquitto, with `ISAACBOT_AMR_VDA5050_LOCAL_BROKER=true`; anonymous, LAN only) |
| 5000   | Drive interface (`isaacbot-amr-drive-interface`, plain http, basic-auth login; `/ws` is proxied to 8765) |
| 5080   | Network page: switch the router's Wi-Fi uplink (`isaacbot-amr-network`, plain http, basic-auth login) |
| 7447   | Zenoh router (`isaacbot-amr-zenoh-router`; loopback + isaacbot LAN only, see below) |
| 8765   | foxglove_bridge                |
| 9001   | MQTT over WebSockets (`isaacbot-amr-vda5050`'s Mosquitto), for browser tools such as vda5050_visualizer |
| 9090   | rosbridge websocket (ros-mcp-server only; dashboards use 8765) — served by `isaacbot-amr-platform`, used by the `ros-mcp` in **every** container |
| 10110/udp | RUTX11 NMEA forwarding → GNSS driver (`isaacbot-amr-sensors`) |
| 10111/udp | RUTX11 Serial Utilities → ELRS CRSF → RC teleop (`isaacbot-amr-platform`, `isaacbot_amr_crsf_udp_receiver`; accepts `192.168.1.1` only) |
| 6699/udp, 7788/udp | RoboSense RS16 MSOP / DIFOP → lidar driver (`isaacbot-amr-sensors`) |
| 48484  | balena supervisor              |

Host networking gives every container a single port space, so each sshd has its own port —
platform **22**, sensors **23**, orchestrator **24**, drive-interface **25**, vda5050 **26**.
No ROS container runs a Zenoh router of its own: they all join `isaacbot-amr-zenoh-router` on 7447 (see
[ROS 2 over the isaacbot LAN](#ros-2-over-the-isaacbot-lan-zenoh)).

That sshd takes the same credentials as `isaacbot-amr-platform`'s — root password login, baked
into the image. Only the port differs: `ssh -p 24 root@<isaacbot-lan-ip>`. See
[Orchestrator SSH](#orchestrator-ssh).

## Orchestrator SSH

`isaacbot-amr-orchestrator` runs its own sshd on **24**, configured in the image
(`isaacbot_amr_orchestrator/Dockerfile`) exactly as `isaacbot-amr-platform`'s is on 22 — `root:root`,
`PermitRootLogin yes`, `UsePAM no` — through a `/etc/ssh/sshd_config.d/` drop-in.

```bash
ssh root@<isaacbot-lan-ip>             # 22  platform: drivers, bringup, web bridges
ssh -p 23 root@<isaacbot-lan-ip>       # 23  sensors: GNSS + lidar drivers
ssh -p 24 root@<isaacbot-lan-ip>       # 24  orchestrator: Nav 2 + mission manager
ssh -p 25 root@<isaacbot-lan-ip>       # 25  drive interface: nginx
ssh -p 26 root@<isaacbot-lan-ip>       # 26  vda5050: VDA 5050 connector + Mosquitto
```

`start.sh` starts sshd ahead of the enable/disable gate, so the container is reachable even
when the autonomy stack is idling — which is when a shell is most useful. sshd is supervised
alongside Nav 2: if it dies the service tears down and `restart: always` brings it back.

Two caveats, both inherited from `isaacbot-amr-platform` and neither specific to this port:

- The password is the image default. Anything that can reach the isaacbot LAN can reach both
  shells, so treat that LAN as the security boundary, and change the password in the
  Dockerfile before any deployment that is not on a trusted network.
- Host keys are generated when `openssh-server` installs at **build** time, so every device
  from one image build shares them. Regenerating per device (`rm -f /etc/ssh/ssh_host_*` in
  the Dockerfile plus `ssh-keygen -A` in `start.sh`) is the fix if that matters.

Neither is a regression — it is the arrangement port 22 has always had — but every extra
shell (23–26) widens the surface, so it is worth stating.

After an image rebuild the host keys change, so `ssh` warns "host key changed" once per port;
clear the old entry with `ssh-keygen -R '[<isaacbot-lan-ip>]:<port>'` (plain `<isaacbot-lan-ip>` for 22).

### Claude Code and ros-mcp on every shell

Every image carries the same Claude tooling: the `@anthropic-ai/claude-code` CLI plus `ros-mcp`
(with the `fastmcp<4` pin), registered at user scope at build time. So `claude` works
identically on all five SSH shells: platform 22, sensors 23, orchestrator 24,
drive-interface 25 and vda5050 26. Use the shell of the container you are debugging:
- port 24 for Nav 2, the costmaps or the mission manager;
- port 23 for the GNSS or lidar payload;
- port 22 for the drivers and bringup.

- **One-time login.** `claude` prompts for authentication on first run. The credential is
  written to `/root/.claude.json` **inside the container**, so it does not survive a container
  recreate — every balena release means logging in again. If that friction bites, declare an
  unset `ANTHROPIC_API_KEY` on every service in `docker-compose.yml` and set it as a
  balenaCloud variable instead.
- **ros-mcp needs `isaacbot-amr-platform` running.** It reaches rosbridge at `127.0.0.1:9090`,
  which is served by that container — host networking gives every service one namespace,
  which is why no other container runs a rosbridge of its own. With the
  platform stopped, `claude mcp list` shows ros-mcp failing to connect.

## Sensors SSH

`isaacbot-amr-sensors` runs its own sshd on **23**, set up like the orchestrator's (same
`root:root` credentials, `/etc/ssh/sshd_config.d/` drop-in); only the port differs.

```bash
ssh -p 23 root@<isaacbot-lan-ip>       # sensors: GNSS + lidar drivers
```

As in the orchestrator, `start.sh` starts sshd ahead of the `ISAACBOT_AMR_SENSORS_ENABLE` gate, so the
shell is up while the payload idles, and a dead sshd restarts the service. The caveats above
(image-default password, host keys shared per build) apply here too, as does everything in
[Claude Code and ros-mcp on every shell](#claude-code-and-ros-mcp-on-every-shell): this image
carries the same `claude` and `ros-mcp` as the others.

## Drive interface

`isaacbot-amr-drive-interface` serves a Clearpath Boxer / IndoorNav-style drive UI from
[`isaacbot_amr_drive_interface`](https://github.com/isaacbotsrl/isaacbot_amr_drive_interface). Open
`http://<isaacbot-lan-ip>:5000/` (the Boxer's OTTO App and IndoorNav use the same port) and log
in. It is built for one isaacbot and indoor navigation.

- **Transport:** nginx serves the page and proxies the same-origin websocket `/ws` to
  foxglove_bridge on `127.0.0.1:8765`. Both sit behind the same basic-auth login, because
  foxglove_bridge itself has no authentication. The container runs no ROS.
- **Driving modes** (owned by `isaacbot_amr_drive_mode` in `isaacbot-amr-orchestrator`, shared by every
  browser; the isaacbot boots in `ISAACBOT_AMR_ORCH_DRIVE_DEFAULT_MODE`, `assisted` by default):
  - **Manual:** the joystick goes straight to the platform, no obstacle check.
  - **Assisted:** the joystick goes through a lidar collision monitor that slows the isaacbot
    down and then stops it in front of an obstacle. With no lidar data it blocks all motion.
  - **Automatic:** Nav 2 drives (**Go to**). Moving the joystick takes over: the isaacbot
    switches to Assisted and the mission is cancelled.
  The joystick publishes `<ns>/teleop_web_cmd_vel_stamped` at 10 Hz; `isaacbot_amr_drive_mode`
  routes it onto `<ns>/teleop_driver_interface_cmd_vel_stamped` (twist_mux priority 8). The RC
  transmitter and the Foxglove joystick bypass the modes and always override.
- **Joystick on/off:** per browser, the page starts with the joystick off and publishes
  nothing. Hiding the tab, losing focus or losing the connection stops publishing and turns
  it off again; twist_mux's timeout stops the isaacbot.
- **Gamepad:** a pad drives only while L1/LB is held.
- **Other controls:** e-stop buttons call the `hardware_interface/sw_*` Trigger services.
- **Top bar:** safety (e-stop, latch, `motion_lock`), diagnostics, battery and
  link latency (a round trip through `/rosapi/get_time`).
- **Map view:** shows the occupancy map, the lidar scan, the Nav 2 plan and the isaacbot. Tools:
  **Set pose** (AMCL `initialpose`) and **Go to** (`isaacbot_amr_mission_manager` `set_mission`), plus
  **Stop**. These need `ISAACBOT_AMR_ORCH_NAVIGATION=true` and `ISAACBOT_AMR_ORCH_MISSION_MANAGER=true`,
  and Go to needs the Automatic driving mode.
- **Places and Facility** (indoor mode only, `ISAACBOT_AMR_ORCH_LOCALIZATION_SOURCE=indoor`):
  1. Record a map with **Start mapping**.
  2. **Save map as…** a name.
  3. **Load** it (AMCL).
  4. Save named places on it, then send the isaacbot to one place or run a workflow through
     several.

### Drive interface SSH

`isaacbot-amr-drive-interface` runs its own sshd on **25**. It is set up like the other containers'
(same `root:root` credentials, `/etc/ssh/sshd_config.d/` drop-in); only the port differs.

```bash
ssh -p 25 root@<isaacbot-lan-ip>       # drive interface: nginx, /tmp/nginx.conf, /tmp/drive-config.json
```

`start.sh` starts sshd before its gates and supervises it together with nginx: if either
exits, the container restarts.

When `ISAACBOT_AMR_UI_ENABLE=false`, or `ISAACBOT_AMR_UI_PASSWORD` is unset, the container **idles**
with only sshd running instead of exiting. It leaves `/tmp/drive-interface-idle`, which the
healthcheck accepts, so balenaEngine does not restart the idle container as unhealthy. The
caveats of the other shells apply here too: an image-default password, and host keys shared
per build. The image runs no ROS itself, but carries `claude` and `ros-mcp` like the others (see [Claude Code and ros-mcp on every shell](#claude-code-and-ros-mcp-on-every-shell)).

### Drive interface variables

| Variable | Default | Effect |
|----------|---------|--------|
| `ISAACBOT_AMR_UI_ENABLE` | `true` | `false` = the container idles (sshd on 25 only). |
| `ISAACBOT_AMR_UI_PORT` | `5000` | Port nginx binds (plain http). |
| `ISAACBOT_AMR_UI_USER` | `isaacbot` | Login user. |
| `ISAACBOT_AMR_UI_PASSWORD` | *(unset)* | Required. Without it nginx is not started and the container idles (sshd only), logging an error. |
| `ISAACBOT_AMR_UI_MAX_LINEAR` / `_ANGULAR` | `1.0` / `1.0` | 100 % speed preset in m/s / rad/s; the presets are 20/50/80/100 % of it. The drive controller clamps at 1.2 m/s, 1.0 rad/s. |
| `ISAACBOT_AMR_UI_MAX_RIM_SPEED` / `_TRACK_WIDTH` | `1.7` / `1.0204` | Outer-wheel rim-speed budget (m/s) and effective track width (m), as `max_wheel_rim_speed` / `effective_track_width` in isaacbot_amr_crsf_teleop.yaml: above the budget v and w are scaled together, keeping the arc. `0` disables the limit. |
| `ISAACBOT_AMR_UI_EXPO_LINEAR` / `_ANGULAR` | `0.3` / `0.5` | Stick expo per axis, `0` (linear) to `1` (softest): small stick moves give much less speed, full stick is still full speed. Out-of-range values fall back to the default. |
| `ISAACBOT_AMR_UI_AUX_OUTPUT_NAMES` / `ISAACBOT_AMR_UI_AUX_INPUT_NAMES` | unset | Names for the six aux outputs (PLC DIO00..05) and inputs (DIO06..11) in the Aux IO popup, comma-separated in order, e.g. `Beacon,Tool power,,,,`. A blank or missing entry keeps the default name ("Output 3" and so on). |

Limitations:

- The balena Public Device URL only forwards port 80, which nothing serves, so the drive
  interface is reachable on the isaacbot LAN only.
- A page served over https would need `wss`; nginx already builds the websocket URL from the
  page scheme, so a TLS proxy in front of port 5000 works unchanged.

## Network uplink page

`isaacbot-amr-network` serves `http://<isaacbot-lan-ip>:5080/`, with login `NETUI_USER` (default `root`) and
`NETUI_PASSWORD`. The page switches the RUTX11's Wi-Fi uplink to another network **in place**,
keeping the router's firewall zones, NAT and forwarding valid, so the wired LAN and the isaacbot AP
keep internet. It also repairs the damage a RutOS *Scan → Join* does. Every change is rolled
back by the router itself if the new uplink doesn't come up.

The application and all its documentation live in the `rutx11/` folder of
[rover_networking](https://github.com/RaduPotlog/rover_networking/tree/master/rutx11): usage,
checks, the rollback design, running it from a laptop, and troubleshooting. This directory
holds only the container glue. The Dockerfile clones rover_networking at
`ISAACBOT_AMR_NETWORKING_REF` (default `master`), runs the tests in `rutx11/`, and fails the build if
any test fails.

Set both passwords as **service** variables of `isaacbot-amr-network`. Don't set them fleet-wide,
or every container would see the router's root password:

```bash
balena env set RUTX11_PASSWORD '<router root password>' --device <uuid> --service isaacbot-amr-network
balena env set NETUI_PASSWORD '<page password>' --device <uuid> --service isaacbot-amr-network
```

| Variable | Default | Effect |
|----------|---------|--------|
| `ISAACBOT_AMR_NETWORK_ENABLE` | `true` | `false` = the container idles. |
| `NETUI_PORT` / `NETUI_USER` | `5080` / `isaacbot` | Port and login user. |
| `NETUI_PASSWORD` | *(unset)* | Required; without it the container idles and logs an error. |
| `RUTX11_HOST` / `RUTX11_USER` / `RUTX11_PASSWORD` | `192.168.1.1` / `root` / *(unset)* | Router SSH login; the password is required. |
| `UPLINK_IFACE` | `auto` | uci network of the Wi-Fi uplink; `auto` detects it (RutOS names it `WWAN1`, `wan1`, …). |
| `UPLINK_ZONE` / `LAN_ZONE` / `CLIENT_NETS` | `wwan` / `lan` / `lan WWAN` | Zones and the client networks that must reach the internet. |

The router's host key and the job log persist in the volume `isaacbot-network` (`/data`).
Without either password the container idles and leaves `/tmp/network-idle`, which the
healthcheck accepts. The service runs as an unprivileged user and has no sshd.

## Device variables

Each service in `docker-compose.yml` declares only the variables it reads. An all-services
fleet or device variable reaches every container either way. Defaults come from
`docker-compose.yml` or from each service's `start.sh`. Override them per device
(balenaCloud → device → **Device Variables**) or per fleet (**Fleet Variables**).

Names follow `ISAACBOT_AMR_<SCOPE>_<THING>`:

- **SCOPE = a container** (`PLATFORM`, `ORCH`, `SENSORS`, `UI` for the drive interface, `VDA5050`,
  `NETWORK`): that container acts on it. Another container may read it too; the *Also read by*
  column says so where it matters.
- **SCOPE = `SYSTEM`**: several containers act on it. Always set an `ISAACBOT_AMR_SYSTEM_*` variable for
  **all services**, never scoped to one, so they agree.
- The prefix follows the container that *runs* the thing, not the code's layer: terrain and
  camera perception (`isaacbot_amr_perception`) run in `isaacbot-amr-sensors`, next to the drivers, so they
  are `ISAACBOT_AMR_SENSORS_*`.
- One exception: the Zenoh session mode is `ISAACBOT_AMR_ZENOH_MODE_<CONTAINER>`, one per container,
  grouped by name.

The variables were renamed on 2026-10-10; see [Migrating from the old names](#migrating-from-the-old-names).
Booleans accept `true`/`1`/`yes`/`on` in any case; anything else means false.

### System (`ISAACBOT_AMR_SYSTEM_*`, all services)

| Variable | Default | Read by | Effect |
|----------|---------|---------|--------|
| `ISAACBOT_AMR_SYSTEM_NAMESPACE` | `isaacbot` | all | ROS namespace (see [ROS namespace](#ros-namespace)). Keep it equal across services. |
| `ISAACBOT_AMR_SYSTEM_USE_GPS` | `false` | sensors, platform, orchestrator | One switch for GPS. `true`: `isaacbot-amr-sensors` starts the RUTX11 GNSS driver (`gps/fix`, `GPS fix` diagnostics) and the platform fuses it (`isaacbot_amr_gps_heading` alignment, `navsat_transform`, global EKF; it publishes `map → odom` only with `ISAACBOT_AMR_SYSTEM_GPS_MAP_TF=true`). `false`: no GPS driver, EKF on wheel odometry + IMU only. In the orchestrator it selects Nav 2's `localization_source` (`gps` vs `odom`). |
| `ISAACBOT_AMR_SYSTEM_GPS_MAP_TF` | `false` | platform, orchestrator | Only matters with `ISAACBOT_AMR_SYSTEM_USE_GPS=true`. `true`: the global EKF broadcasts `map → odom`. `false`: it keeps fusing GPS and publishing `odometry/global` but leaves `map → odom` to slam_toolbox or AMCL. The orchestrator warns when this is `false` with `localization_source=gps`, since then nothing publishes `map → odom`. Set it as an all-services variable. |
| `ISAACBOT_AMR_SYSTEM_USE_LIDAR` | `false` | sensors, orchestrator, platform (Lidar diagnostics group) | Starts the RoboSense RS16 driver in `isaacbot-amr-sensors`. Leave `false` on isaacbots with no lidar fitted. The orchestrator logs a warning when it is false: both Nav 2 costmaps mark and clear from `<namespace>/scan`, so navigation would drive blind. |
| `ISAACBOT_AMR_SYSTEM_USE_CAMERA` | `false` | sensors, orchestrator | Starts the RealSense D435i driver (`isaacbot_amr_sensors`' `isaacbot_amr_realsense`) and the camera perception nodes in `isaacbot-amr-sensors` (see [isaacbot_amr_perception](../src/isaacbot_amr_perception/README.md)), and, with `ISAACBOT_AMR_SENSORS_CAMERA_DEPTH_CLOUD=true`, its depth cloud (`camera/depth/points`). It does not change Nav 2: the cloud joins the costmap only with `ISAACBOT_AMR_ORCH_NAV_USE_CAMERA`; the orchestrator reads this variable just to warn about that combination. Counts as a driver for `ISAACBOT_AMR_SENSORS_ENABLE`, so a camera-only payload does not idle. Needs USB access to the camera in the container. |
| `ISAACBOT_AMR_SYSTEM_FOLLOW_ME_ENABLE` | `false` | sensors, orchestrator | `true` starts follow-me: the `fmoc` person tracker in `isaacbot-amr-sensors` (needs `ISAACBOT_AMR_SYSTEM_USE_CAMERA=true` and the depth cloud, `ISAACBOT_AMR_SENSORS_CAMERA_DEPTH_CLOUD=true`; off by default) and the `follow_me` node in `isaacbot-amr-orchestrator`. Following drives through Nav 2's Following server, so it needs `ISAACBOT_AMR_ORCH_NAVIGATION=true` and `ISAACBOT_AMR_ORCH_MISSION_MANAGER=true` (AUTOMATIC needs the mission manager); the orchestrator warns when the mission manager or the camera is off. |
| `ISAACBOT_AMR_SYSTEM_LAN_IP` | `192.168.1.201` | zenoh-router | Isaacbot LAN address `isaacbot-amr-zenoh-router` binds. Not in `docker-compose.yml`; set it in balenaCloud to change it. |
| `ISAACBOT_AMR_SYSTEM_LOG_MAX_MB` / `ISAACBOT_AMR_SYSTEM_LOG_BACKUPS` | `20` / `3` | platform, orchestrator, sensors, vda5050 | Size at which a container's process log in `/tmp` is rotated, and the rotated copies kept per log. Not in `docker-compose.yml`. |
| `ISAACBOT_AMR_SYSTEM_ROS_LOG_MAX_MB` / `ISAACBOT_AMR_SYSTEM_ROS_LOG_KEEP_DAYS` | `300` / `7` | platform, orchestrator, sensors, vda5050 | `~/.ros/log` is trimmed at start: entries older than the days, then the oldest until under the size. Not in `docker-compose.yml`. |
| `ISAACBOT_AMR_SYSTEM_USE_SIM_TIME` | `false` | orchestrator | `true` only when the platform is `isaacbot_amr_gazebo` (Gazebo publishes `/clock`); never on the isaacbot. Not in `docker-compose.yml`. |

See [Follow-me](#follow-me) for `ISAACBOT_AMR_SYSTEM_FOLLOW_ME_ENABLE`.

#### Sensor mount poses (`ISAACBOT_AMR_SYSTEM_MOUNT_*`)

Read by `isaacbot_amr_description` in `isaacbot-amr-platform`, relative to `body_link`
(x forward, y left, z up). Declared in `docker-compose.yml` but left **unset**, so the URDF
defaults apply until a balenaCloud variable defines one. A non-numeric value is ignored with a
warning in `/tmp/isaacbot_amr_bringup.log`.

| Variable | Default |
|----------|---------|
| `ISAACBOT_AMR_SYSTEM_MOUNT_IMU_X` / `_Y` / `_Z` [m] | `-0.09` / `0.0` / `0.2` |
| `ISAACBOT_AMR_SYSTEM_MOUNT_IMU_ROLL` / `_PITCH` / `_YAW` [rad] | `3.14159` / `0` / `0` (mounted upside down) |
| `ISAACBOT_AMR_SYSTEM_MOUNT_GPS_X` / `_Y` / `_Z` [m] | `0` |
| `ISAACBOT_AMR_SYSTEM_MOUNT_GPS_ROLL` / `_PITCH` / `_YAW` [rad] | `0` |
| `ISAACBOT_AMR_SYSTEM_MOUNT_LIDAR_X` / `_Y` / `_Z` [m] | `0` |
| `ISAACBOT_AMR_SYSTEM_MOUNT_LIDAR_ROLL` / `_PITCH` / `_YAW` [rad] | `0` |
| `ISAACBOT_AMR_SYSTEM_MOUNT_CAMERA_X` / `_Y` / `_Z` [m] | `0.25` / `0.0` / `0.2` (assumed, not measured) |
| `ISAACBOT_AMR_SYSTEM_MOUNT_CAMERA_ROLL` / `_PITCH` / `_YAW` [rad] | `0` |

### Zenoh session mode (`ISAACBOT_AMR_ZENOH_MODE_*`)

| Variable | Default | Effect |
|----------|---------|--------|
| `ISAACBOT_AMR_ZENOH_MODE_PLATFORM` / `_ORCH` / `_SENSORS` / `_VDA5050` | `peer` / `client` / `client` / `client` | How that container's ROS processes join the graph. `peer`: direct links between processes, plus one to the router. `client`: one link each, to `isaacbot-amr-zenoh-router`. The split keeps the platform's control loops independent of the router, which stalls for up to a minute while cleaning up after an orchestrator restart. See [ROS 2 over the isaacbot LAN](#ros-2-over-the-isaacbot-lan-zenoh) before changing one. |

### Platform (`ISAACBOT_AMR_PLATFORM_*`)

| Variable | Default | Also read by | Effect |
|----------|---------|--------------|--------|
| `ISAACBOT_AMR_PLATFORM_ENABLE` | `true` | orchestrator | `false` skips `ros2 launch isaacbot_amr_bringup isaacbot_amr_bringup.launch.py`. sshd and the web bridges still run (and the Zenoh router, in its own service). The orchestrator also stays idle, since there is no platform to drive, so set it for **all services**. |
| `ISAACBOT_AMR_PLATFORM_FOXGLOVE_TOPIC_WHITELIST` | *(unset)* | | `foxglove_bridge`'s `topic_whitelist`. Unset: only the topics the drive UI uses (listed in `isaacbot_amr_bringup/launch/isaacbot_amr_web_bridges.launch.py`), because anything a browser subscribes to crosses the Zenoh router at full rate. Set `['.*']` to see the whole graph in Foxglove Studio while debugging. |
| `ISAACBOT_AMR_PLATFORM_FOXGLOVE_SERVICE_WHITELIST` | *(unset)* | | `foxglove_bridge`'s `service_whitelist`. Unset: only the services the drive UI calls (listed in `isaacbot_amr_bringup/launch/isaacbot_amr_web_bridges.launch.py`). Otherwise the bridge advertises every service on the graph and logs a warning for each one whose package isn't in the platform image (slam_toolbox, the voxel layer). A UI can only call a service the bridge advertises. Set `['.*']` to reach every service from Foxglove Studio while debugging. |

### Orchestrator (`ISAACBOT_AMR_ORCH_*`)

| Variable | Default | Also read by | Effect |
|----------|---------|--------------|--------|
| `ISAACBOT_AMR_ORCH_NAVIGATION` | `false` | | `true` starts the autonomy stack (`isaacbot_amr_navigation` → Nav 2) on this device. Requires `ISAACBOT_AMR_PLATFORM_ENABLE=true`. Leave `false` when a companion controller runs the stack. |
| `ISAACBOT_AMR_ORCH_MISSION_MANAGER` | `false` | vda5050 | `true` also starts `isaacbot_amr_mission_manager` on top of Nav 2. Only consulted when the orchestrator stack starts at all. The Automatic driving mode is refused without it. |
| `ISAACBOT_AMR_ORCH_DRIVE_MODE` | `true` | | Starts `isaacbot_amr_drive_mode` (driving modes + the Assisted lidar guard), even when `ISAACBOT_AMR_ORCH_NAVIGATION=false`. `false` leaves the drive UI's joystick connected to nothing. Requires `ISAACBOT_AMR_PLATFORM_ENABLE=true`. |
| `ISAACBOT_AMR_ORCH_DRIVE_DEFAULT_MODE` | `assisted` | | Driving mode at boot: `assisted` or `manual`. Never `automatic`. |
| `ISAACBOT_AMR_ORCH_LOCALIZATION_SOURCE` | *(unset)* | sensors, vda5050 | Optional. `odom`, `gps`, `slam`, `amcl` or `indoor`, overriding the `ISAACBOT_AMR_SYSTEM_USE_GPS` mapping. `slam` (slam_toolbox), `amcl` (nav2_amcl) and `indoor` all require `ISAACBOT_AMR_SYSTEM_USE_GPS=false` or `ISAACBOT_AMR_SYSTEM_GPS_MAP_TF=false` — exactly one process may publish `map → odom`. `amcl` localizes on a fixed `ISAACBOT_AMR_ORCH_NAV_MAP` and needs `ISAACBOT_AMR_SYSTEM_USE_LIDAR=true`. **`indoor`** is the mode for the [drive interface](#drive-interface): `isaacbot_amr_indoor_nav_manager` runs slam_toolbox while you record a map and map_server + AMCL on a saved one, switching at runtime; maps, places and the last pose live in the `isaacbot-maps` volume (`/maps/<name>/`), and `ISAACBOT_AMR_ORCH_NAV_MAP` / `ISAACBOT_AMR_ORCH_AMCL_INITIAL_POSE_*` are ignored. An unrecognized value is ignored with a warning. |
| `ISAACBOT_AMR_ORCH_NAV_MAP` | *(unset)* | | Optional path to a map yaml inside the container; defaults to `isaacbot_amr_navigation`'s `empty_world.yaml`. **Required with `ISAACBOT_AMR_ORCH_LOCALIZATION_SOURCE=amcl`** — AMCL cannot localize against the empty default, so build a map with `=slam` first and point this at `/maps/map.yaml`. |
| `ISAACBOT_AMR_ORCH_NAV_USE_CAMERA` | `false` | | Adds the depth cloud (`camera/depth/points`) as a second source of the **local** Nav 2 costmap. Needs `ISAACBOT_AMR_SYSTEM_USE_CAMERA=true` (the orchestrator warns otherwise) and `ISAACBOT_AMR_SENSORS_CAMERA_DEPTH_CLOUD=true` (`isaacbot-amr-sensors`). Leave it off until the camera mount (`ISAACBOT_AMR_SYSTEM_MOUNT_CAMERA_*`) is measured: with a wrong mount the camera marks obstacles in the wrong place. `false` keeps the lidar scan as the only source. |
| `ISAACBOT_AMR_ORCH_AMCL_INITIAL_POSE_X` / `_Y` / `_YAW` | `0.0` | | Pose AMCL is seeded with at startup, in the map frame. The default is correct only when the map origin is where the isaacbot parks, i.e. the slam run started there. Find it with `ros2 run tf2_ros tf2_echo isaacbot/map isaacbot/base_link`. |

### Sensors (`ISAACBOT_AMR_SENSORS_*`)

| Variable | Default | Effect |
|----------|---------|--------|
| `ISAACBOT_AMR_SENSORS_ENABLE` | `false` | `true` starts the sensor payload in `isaacbot-amr-sensors` (GNSS with `ISAACBOT_AMR_SYSTEM_USE_GPS`, lidar with `ISAACBOT_AMR_SYSTEM_USE_LIDAR`). `false` idles the container. It also idles when both `ISAACBOT_AMR_SYSTEM_USE_GPS` and `ISAACBOT_AMR_SYSTEM_USE_LIDAR` are false, since there is no driver to run. |
| `ISAACBOT_AMR_SENSORS_CAMERA_DEPTH_CLOUD` | `false` | With `ISAACBOT_AMR_SYSTEM_USE_CAMERA=true`: publish the depth image as a `PointCloud2` (`camera/depth/points`). Needed by the costmap with `ISAACBOT_AMR_ORCH_NAV_USE_CAMERA` and by follow-me's person tracker (`ISAACBOT_AMR_SYSTEM_FOLLOW_ME_ENABLE`); off by default to save the CPU it costs. |
| `ISAACBOT_AMR_SENSORS_CAMERA_FIDUCIALS` | `false` | With `ISAACBOT_AMR_SYSTEM_USE_CAMERA=true`: AprilTag (36h11) detection on the colour stream. The tag size in `isaacbot_amr_perception_bringup/config/apriltag.yaml` is an assumption until measured. |
| `ISAACBOT_AMR_SENSORS_CAMERA_DETECTION` | `false` | With `ISAACBOT_AMR_SYSTEM_USE_CAMERA=true`: YOLO object detection on the colour stream (`detections`, `vision_msgs/Detection2DArray`). Needs `ISAACBOT_AMR_SENSORS_CAMERA_DETECTION_MODEL`. |
| `ISAACBOT_AMR_SENSORS_CAMERA_DETECTION_MODEL` | *(unset)* | Path inside the container of a YOLOv8/v11 `.onnx` file. Unset or empty: `/opt/models/yolo11n.onnx`, YOLO11n at 320 px exported while the image is built (Ultralytics, AGPL-3.0; swap it before shipping isaacbots to others). |
| `ISAACBOT_AMR_SENSORS_CAMERA_DETECTION_LABELS` | `person` | Classes the detector publishes, comma-separated; empty publishes all 80 COCO classes. |
| `ISAACBOT_AMR_SENSORS_PERSON_DETECTION` | `off` | `required`: follow-me's person tracker (fmoc) picks up only depth clusters inside a detected person, not any person-sized object (box, chair, pole). Needs `ISAACBOT_AMR_SENSORS_CAMERA_DETECTION=true`; without detections nobody is picked up. `off`: anything person-sized, as before. |
| `ISAACBOT_AMR_SENSORS_CAMERA_DETECTION_GPU` | `false` | `true` asks ONNX Runtime for CUDA. The isaacbot image ships CPU `onnxruntime` only, so this is for a GPU host. |
| `ISAACBOT_AMR_SENSORS_CAMERA_FPS` | `15` | Frame rate of the colour and depth streams; the D435i only accepts `6`, `15` or `30` at these resolutions. The first knob to lower on a loaded controller, since every consumer scales with it. On the dev laptop `6` with `ISAACBOT_AMR_SENSORS_CAMERA_FIDUCIALS_DECIMATE=4.0` cut the stack from 20.6 % to 7.0 % of one core. |
| `ISAACBOT_AMR_SENSORS_CAMERA_DEPTH_PROFILE` | `424x240` | Depth resolution. The point cloud, and with it the Nav 2 costmap work (with `ISAACBOT_AMR_ORCH_NAV_USE_CAMERA`), grows with the pixel count: `424x240` is about 100 k points, `848x480` four times that. |
| `ISAACBOT_AMR_SENSORS_CAMERA_FIDUCIALS_DECIMATE` | `2.0` | AprilTag image decimation; higher is cheaper and detects at shorter range. About half a core on a Pi 5 at 15 fps and `2.0` (estimate). |
| `ISAACBOT_AMR_SENSORS_CAMERA_DETECTION_MAX_RATE` | `3.0` | Upper bound on detections per second (Hz). The default suits a CPU-only controller; raise it on a GPU host. The input resolution comes from the exported `.onnx` model, so export a 320 px model for a cheaper detector. |
| `ISAACBOT_AMR_SENSORS_TERRAIN` | `false` | Ground slope from the lidar cloud (`terrain/incline`, `terrain/ground_confidence`). Independent of the camera; needs `ISAACBOT_AMR_SYSTEM_USE_LIDAR=true`. |

### Drive interface (`ISAACBOT_AMR_UI_*`)

See [Drive interface variables](#drive-interface-variables).

### VDA 5050 (`ISAACBOT_AMR_VDA5050_*`)

| Variable | Default | Effect |
|----------|---------|--------|
| `ISAACBOT_AMR_VDA5050_ENABLE` | `false` | `true` starts the VDA 5050 connector. Orders drive through `isaacbot_amr_mission_manager`, so they also need `ISAACBOT_AMR_ORCH_NAVIGATION=true` and `ISAACBOT_AMR_ORCH_MISSION_MANAGER=true` on the orchestrator, and the isaacbot in the Automatic driving mode. |
| `ISAACBOT_AMR_VDA5050_LOCAL_BROKER` | `true` | Run Mosquitto in the container (1883, WebSockets 9001, anonymous). `false` when master control brings its own broker. |
| `ISAACBOT_AMR_VDA5050_BROKER_HOST` / `_PORT` | `127.0.0.1` / `1883` | The broker the connector uses. |
| `ISAACBOT_AMR_VDA5050_BROKER_USER` / `_PASSWORD` | unset | Broker login. A user also switches the connector to TLS (CA bundle from `VDA5050_CONNECTOR_TLS_CA_CERT`, default the system bundle). |
| `ISAACBOT_AMR_VDA5050_BROKER_TLS` | `auto` | `auto`: TLS when a user is set. `false`: user/password without TLS, for a broker reached through WireGuard. `true`: always TLS. |
| `ISAACBOT_AMR_VDA5050_MANUFACTURER` / `_SERIAL_NUMBER` | `MechatronicsAcademy` / `ardennes` | VDA 5050 identity; topics are `uagv/v2/<manufacturer>/<serial>/…`. |
| `ISAACBOT_AMR_VDA5050_MAP_FRAME` | unset | Nav 2 frame the order coordinates are in (prefixed with the namespace). Unset follows the orchestrator's localization source like its `start.sh` does: `odom` for odom, `map` for gps/slam/amcl/indoor. |

See [VDA 5050](#vda-5050) for what the interface supports.

### Network (`ISAACBOT_AMR_NETWORK_*`)

See [Network uplink page](#network-uplink-page). Its variables are scoped to
`isaacbot-amr-network` only.

### Setting variables

```bash
balena env set ISAACBOT_AMR_PLATFORM_ENABLE false --device <device-uuid>
balena env set ISAACBOT_AMR_ORCH_NAVIGATION true --device <device-uuid> --service isaacbot-amr-orchestrator
```

Changing a variable restarts the affected containers automatically, and `start.sh` re-reads
the value on the next start. There is no image rebuild, but expect roughly 15–30 s of downtime
for `isaacbot-amr-platform`, with its web bridges down during that time. A variable scoped to one
service restarts only that service; an all-services device variable restarts every service.

Note that `ISAACBOT_AMR_PLATFORM_ENABLE` is read by two services. Scoping it to `isaacbot-amr-platform`
alone stops the bringup but leaves the orchestrator believing it is still running — set it as
an all-services variable, or set `ISAACBOT_AMR_ORCH_NAVIGATION=false` alongside it. Every
`ISAACBOT_AMR_SYSTEM_*` variable is read by several services (`ISAACBOT_AMR_SYSTEM_USE_GPS`: sensors driver,
platform fusion, orchestrator `localization_source`), so set each as an all-services variable.

With the defaults only `isaacbot-amr-platform` runs its stack; the orchestrator and the sensor
payload idle until `ISAACBOT_AMR_ORCH_NAVIGATION` / `ISAACBOT_AMR_SENSORS_ENABLE` are set to `true`.

### Managing variables with `tools/balena_env.py`

`tools/balena_env.yaml` lists every variable `docker-compose.yml` declares, one line per
(name, level, service), with `value` (what to set; `null` = not managed, the compose default
applies) next to the compose `default`. `tools/balena_env.py` keeps it in step with balenaCloud
through the balena CLI (installed and `balena login`; Python 3 with PyYAML):

```bash
tools/balena_env.py                    # interactive menu: show, dump, diff, write, edit, set a secret, remove
tools/balena_env.py dump               # balenaCloud -> YAML
tools/balena_env.py diff               # YAML vs balenaCloud
tools/balena_env.py write --dry-run    # what a write would set; drop --dry-run to set it (asks first)
tools/balena_env.py init               # after editing docker-compose.yml; keeps your values
tools/balena_env.py migrate --dry-run  # old variable names still on balenaCloud -> new names
```

`device: null` in the YAML means the fleet's only device; `--device`/`--fleet` override it.
A write sets only entries whose value differs from balenaCloud and never removes anything, so
expect the restarts described above. Passwords are never stored in the file: set them with
**Set a secret** in the menu, which hands the value to the CLI through its environment, not its
command line. Tests: `python3 -m pytest tools/test_balena_env.py`.

### Migrating from the old names

<!-- env-renames:begin -->
On 2026-10-10 every variable moved to the `ISAACBOT_AMR_<SCOPE>_<THING>` names above, as a hard rename:
the containers no longer read the old names, so a device keeps an old variable's value only
once it is renamed on balenaCloud. `tools/env_renames.yaml` is the map (it also drives
`tools/rename_env_vars.py`, which did the rename in the source repos).

1. Before deploying, `tools/balena_env.py dump` records what balenaCloud holds (old names).
2. Push the release. Until step 3 the containers run on the compose defaults.
3. `tools/balena_env.py migrate --dry-run`, then `tools/balena_env.py migrate`. For each old
   variable it sets the new one with the same value, level and service (secrets through the
   CLI's environment), then asks before removing the old ones. A new name that already holds a
   different value is a *conflict*: both are kept, and the old one is not removed, until you
   settle it. `ISAACBOT_AMR_ZENOH_MODE` becomes the four `ISAACBOT_AMR_ZENOH_MODE_*`: an all-services value
   goes to each, a service-scoped one to that container's.

| Old name | New name |
|----------|----------|
| `ISAACBOT_AMR_NAMESPACE` | `ISAACBOT_AMR_SYSTEM_NAMESPACE` |
| `ISAACBOT_AMR_LAN_IP` | `ISAACBOT_AMR_SYSTEM_LAN_IP` |
| `ISAACBOT_AMR_USE_GPS` | `ISAACBOT_AMR_SYSTEM_USE_GPS` |
| `ISAACBOT_AMR_USE_LIDAR` | `ISAACBOT_AMR_SYSTEM_USE_LIDAR` |
| `ISAACBOT_AMR_USE_CAMERA` | `ISAACBOT_AMR_SYSTEM_USE_CAMERA` |
| `ISAACBOT_AMR_USE_SIM_TIME` | `ISAACBOT_AMR_SYSTEM_USE_SIM_TIME` |
| `ISAACBOT_AMR_LOG_MAX_MB` | `ISAACBOT_AMR_SYSTEM_LOG_MAX_MB` |
| `ISAACBOT_AMR_LOG_BACKUPS` | `ISAACBOT_AMR_SYSTEM_LOG_BACKUPS` |
| `ISAACBOT_AMR_ROS_LOG_MAX_MB` | `ISAACBOT_AMR_SYSTEM_ROS_LOG_MAX_MB` |
| `ISAACBOT_AMR_ROS_LOG_KEEP_DAYS` | `ISAACBOT_AMR_SYSTEM_ROS_LOG_KEEP_DAYS` |
| `ISAACBOT_AMR_START_FOLLOW_ME` | `ISAACBOT_AMR_SYSTEM_FOLLOW_ME_ENABLE` |
| `ISAACBOT_AMR_IMU_LOCALIZATION_X` | `ISAACBOT_AMR_SYSTEM_MOUNT_IMU_X` |
| `ISAACBOT_AMR_IMU_LOCALIZATION_Y` | `ISAACBOT_AMR_SYSTEM_MOUNT_IMU_Y` |
| `ISAACBOT_AMR_IMU_LOCALIZATION_Z` | `ISAACBOT_AMR_SYSTEM_MOUNT_IMU_Z` |
| `ISAACBOT_AMR_IMU_ORIENTATION_R` | `ISAACBOT_AMR_SYSTEM_MOUNT_IMU_ROLL` |
| `ISAACBOT_AMR_IMU_ORIENTATION_P` | `ISAACBOT_AMR_SYSTEM_MOUNT_IMU_PITCH` |
| `ISAACBOT_AMR_IMU_ORIENTATION_Y` | `ISAACBOT_AMR_SYSTEM_MOUNT_IMU_YAW` |
| `ISAACBOT_AMR_GPS_LOCALIZATION_X` | `ISAACBOT_AMR_SYSTEM_MOUNT_GPS_X` |
| `ISAACBOT_AMR_GPS_LOCALIZATION_Y` | `ISAACBOT_AMR_SYSTEM_MOUNT_GPS_Y` |
| `ISAACBOT_AMR_GPS_LOCALIZATION_Z` | `ISAACBOT_AMR_SYSTEM_MOUNT_GPS_Z` |
| `ISAACBOT_AMR_GPS_ORIENTATION_R` | `ISAACBOT_AMR_SYSTEM_MOUNT_GPS_ROLL` |
| `ISAACBOT_AMR_GPS_ORIENTATION_P` | `ISAACBOT_AMR_SYSTEM_MOUNT_GPS_PITCH` |
| `ISAACBOT_AMR_GPS_ORIENTATION_Y` | `ISAACBOT_AMR_SYSTEM_MOUNT_GPS_YAW` |
| `ISAACBOT_AMR_LIDAR_LOCALIZATION_X` | `ISAACBOT_AMR_SYSTEM_MOUNT_LIDAR_X` |
| `ISAACBOT_AMR_LIDAR_LOCALIZATION_Y` | `ISAACBOT_AMR_SYSTEM_MOUNT_LIDAR_Y` |
| `ISAACBOT_AMR_LIDAR_LOCALIZATION_Z` | `ISAACBOT_AMR_SYSTEM_MOUNT_LIDAR_Z` |
| `ISAACBOT_AMR_LIDAR_ORIENTATION_R` | `ISAACBOT_AMR_SYSTEM_MOUNT_LIDAR_ROLL` |
| `ISAACBOT_AMR_LIDAR_ORIENTATION_P` | `ISAACBOT_AMR_SYSTEM_MOUNT_LIDAR_PITCH` |
| `ISAACBOT_AMR_LIDAR_ORIENTATION_Y` | `ISAACBOT_AMR_SYSTEM_MOUNT_LIDAR_YAW` |
| `ISAACBOT_AMR_CAMERA_LOCALIZATION_X` | `ISAACBOT_AMR_SYSTEM_MOUNT_CAMERA_X` |
| `ISAACBOT_AMR_CAMERA_LOCALIZATION_Y` | `ISAACBOT_AMR_SYSTEM_MOUNT_CAMERA_Y` |
| `ISAACBOT_AMR_CAMERA_LOCALIZATION_Z` | `ISAACBOT_AMR_SYSTEM_MOUNT_CAMERA_Z` |
| `ISAACBOT_AMR_CAMERA_ORIENTATION_R` | `ISAACBOT_AMR_SYSTEM_MOUNT_CAMERA_ROLL` |
| `ISAACBOT_AMR_CAMERA_ORIENTATION_P` | `ISAACBOT_AMR_SYSTEM_MOUNT_CAMERA_PITCH` |
| `ISAACBOT_AMR_CAMERA_ORIENTATION_Y` | `ISAACBOT_AMR_SYSTEM_MOUNT_CAMERA_YAW` |
| `ISAACBOT_AMR_ZENOH_MODE` | `ISAACBOT_AMR_ZENOH_MODE_PLATFORM`, `ISAACBOT_AMR_ZENOH_MODE_ORCH`, `ISAACBOT_AMR_ZENOH_MODE_SENSORS`, `ISAACBOT_AMR_ZENOH_MODE_VDA5050` |
| `ISAACBOT_AMR_START_ROS_PLATFORM` | `ISAACBOT_AMR_PLATFORM_ENABLE` |
| `ISAACBOT_AMR_GPS_PUBLISH_MAP_TF` | `ISAACBOT_AMR_SYSTEM_GPS_MAP_TF` (`ISAACBOT_AMR_PLATFORM_GPS_MAP_TF` until the follow-up rename) |
| `ISAACBOT_AMR_PLATFORM_GPS_MAP_TF` | `ISAACBOT_AMR_SYSTEM_GPS_MAP_TF` (follow-up: the orchestrator reads it too) |
| `ISAACBOT_AMR_FOXGLOVE_TOPIC_WHITELIST` | `ISAACBOT_AMR_PLATFORM_FOXGLOVE_TOPIC_WHITELIST` |
| `ISAACBOT_AMR_FOXGLOVE_SERVICE_WHITELIST` | `ISAACBOT_AMR_PLATFORM_FOXGLOVE_SERVICE_WHITELIST` |
| `ISAACBOT_AMR_START_NAVIGATION` | `ISAACBOT_AMR_ORCH_NAVIGATION` |
| `ISAACBOT_AMR_START_MISSION_MANAGER` | `ISAACBOT_AMR_ORCH_MISSION_MANAGER` |
| `ISAACBOT_AMR_START_DRIVE_MODE` | `ISAACBOT_AMR_ORCH_DRIVE_MODE` |
| `ISAACBOT_AMR_DRIVE_DEFAULT_MODE` | `ISAACBOT_AMR_ORCH_DRIVE_DEFAULT_MODE` |
| `ISAACBOT_AMR_LOCALIZATION_SOURCE` | `ISAACBOT_AMR_ORCH_LOCALIZATION_SOURCE` |
| `ISAACBOT_AMR_NAV_MAP` | `ISAACBOT_AMR_ORCH_NAV_MAP` |
| `ISAACBOT_AMR_NAV_USE_CAMERA` | `ISAACBOT_AMR_ORCH_NAV_USE_CAMERA` |
| `ISAACBOT_AMR_AMCL_INITIAL_POSE_X` | `ISAACBOT_AMR_ORCH_AMCL_INITIAL_POSE_X` |
| `ISAACBOT_AMR_AMCL_INITIAL_POSE_Y` | `ISAACBOT_AMR_ORCH_AMCL_INITIAL_POSE_Y` |
| `ISAACBOT_AMR_AMCL_INITIAL_POSE_YAW` | `ISAACBOT_AMR_ORCH_AMCL_INITIAL_POSE_YAW` |
| `ISAACBOT_AMR_START_SENSORS` | `ISAACBOT_AMR_SENSORS_ENABLE` |
| `ISAACBOT_AMR_CAMERA_DEPTH_CLOUD` | `ISAACBOT_AMR_SENSORS_CAMERA_DEPTH_CLOUD` |
| `ISAACBOT_AMR_CAMERA_DEPTH_PROFILE` | `ISAACBOT_AMR_SENSORS_CAMERA_DEPTH_PROFILE` |
| `ISAACBOT_AMR_CAMERA_FPS` | `ISAACBOT_AMR_SENSORS_CAMERA_FPS` |
| `ISAACBOT_AMR_CAMERA_FIDUCIALS` | `ISAACBOT_AMR_SENSORS_CAMERA_FIDUCIALS` |
| `ISAACBOT_AMR_CAMERA_FIDUCIALS_DECIMATE` | `ISAACBOT_AMR_SENSORS_CAMERA_FIDUCIALS_DECIMATE` |
| `ISAACBOT_AMR_CAMERA_DETECTION` | `ISAACBOT_AMR_SENSORS_CAMERA_DETECTION` |
| `ISAACBOT_AMR_CAMERA_DETECTION_MODEL` | `ISAACBOT_AMR_SENSORS_CAMERA_DETECTION_MODEL` |
| `ISAACBOT_AMR_CAMERA_DETECTION_GPU` | `ISAACBOT_AMR_SENSORS_CAMERA_DETECTION_GPU` |
| `ISAACBOT_AMR_CAMERA_DETECTION_MAX_RATE` | `ISAACBOT_AMR_SENSORS_CAMERA_DETECTION_MAX_RATE` |
| `ISAACBOT_AMR_USE_TERRAIN` | `ISAACBOT_AMR_SENSORS_TERRAIN` |
| `ISAACBOT_AMR_DRIVE_ENABLE` | `ISAACBOT_AMR_UI_ENABLE` |
| `ISAACBOT_AMR_DRIVE_PORT` | `ISAACBOT_AMR_UI_PORT` |
| `ISAACBOT_AMR_DRIVE_USER` | `ISAACBOT_AMR_UI_USER` |
| `ISAACBOT_AMR_DRIVE_PASSWORD` | `ISAACBOT_AMR_UI_PASSWORD` |
| `ISAACBOT_AMR_DRIVE_MAX_LINEAR` | `ISAACBOT_AMR_UI_MAX_LINEAR` |
| `ISAACBOT_AMR_DRIVE_MAX_ANGULAR` | `ISAACBOT_AMR_UI_MAX_ANGULAR` |
| `ISAACBOT_AMR_DRIVE_MAX_RIM_SPEED` | `ISAACBOT_AMR_UI_MAX_RIM_SPEED` |
| `ISAACBOT_AMR_DRIVE_TRACK_WIDTH` | `ISAACBOT_AMR_UI_TRACK_WIDTH` |
| `ISAACBOT_AMR_DRIVE_EXPO_LINEAR` | `ISAACBOT_AMR_UI_EXPO_LINEAR` |
| `ISAACBOT_AMR_DRIVE_EXPO_ANGULAR` | `ISAACBOT_AMR_UI_EXPO_ANGULAR` |
| `ISAACBOT_AMR_DRIVE_AUX_OUTPUT_NAMES` | `ISAACBOT_AMR_UI_AUX_OUTPUT_NAMES` |
| `ISAACBOT_AMR_DRIVE_AUX_INPUT_NAMES` | `ISAACBOT_AMR_UI_AUX_INPUT_NAMES` |
| `ISAACBOT_AMR_DRIVE_BRIDGE` | `ISAACBOT_AMR_UI_BRIDGE` |
| `ISAACBOT_AMR_DRIVE_ROBOT_NAME` | `ISAACBOT_AMR_UI_ROBOT_NAME` |
| `ISAACBOT_AMR_START_VDA5050` | `ISAACBOT_AMR_VDA5050_ENABLE` |
<!-- env-renames:end -->

## Where the orchestrator runs

`isaacbot-amr-orchestrator` holds the autonomy stack from
[`isaacbot_amr_orchestrator`](https://github.com/isaacbotsrl/isaacbot_amr_orchestrator): `isaacbot_amr_navigation`
(Nav 2 configuration — costmaps, MPPI controller, Smac 2D planner, behavior trees, map
server, SLAM map autosaver) and `isaacbot_amr_mission_manager` (behavior-tree mission supervision
dispatching Nav 2 actions).

It also holds `isaacbot_amr_drive_mode`, the driving modes the drive UI switches between (Manual,
Assisted, Automatic). That starts whenever `ISAACBOT_AMR_PLATFORM_ENABLE` and
`ISAACBOT_AMR_ORCH_DRIVE_MODE` (default `true`) are both true, independent of Nav 2, because the drive
UI's joystick reaches the platform only through it. Nav 2 starts only when **both** hold:

| `ISAACBOT_AMR_PLATFORM_ENABLE` | `ISAACBOT_AMR_ORCH_NAVIGATION` | Result |
|---|---|---|
| `true` | `true` | Nav 2 starts (+ mission manager with `ISAACBOT_AMR_ORCH_MISSION_MANAGER=true`) |
| `true` | `false` | drive modes only — Manual and Assisted work, Automatic is refused. When a companion controller runs the stack, run `isaacbot_amr_drive_mode` on exactly one of the two devices (`ISAACBOT_AMR_ORCH_DRIVE_MODE=false` on the other): two managers would both route the joystick |
| `false` | *any* | idle — no platform bringup to drive or navigate with |

The table assumes `ISAACBOT_AMR_ORCH_DRIVE_MODE=true` (the default). With it `false`, the second row
idles too, and the first runs Nav 2 without driving modes: the drive UI cannot drive, and the
mission manager refuses every mission, because nothing ever reports AUTOMATIC.

When idle the container does **not** exit — it sleeps, so `restart: always` cannot crash-loop
it, and the balena logs carry a single line naming the reason. sshd starts ahead of that
gate, so an idle container is still reachable on 24 — which is when a shell tends to be
most useful. Changing any of the variables restarts the container, which re-evaluates them.

To run the stack on a companion controller, leave `ISAACBOT_AMR_ORCH_NAVIGATION=false` on the isaacbot,
then build and run `isaacbot_amr_autonomy` on the companion computer and join the isaacbot's Zenoh
router over the isaacbot LAN (see [ROS 2 over the isaacbot LAN](#ros-2-over-the-isaacbot-lan-zenoh)). Keep `ISAACBOT_AMR_SYSTEM_NAMESPACE` and the
chosen `localization_source` identical on both sides.

The container runs no Zenoh router of its own: host networking puts it in the same network
namespace as `isaacbot-amr-zenoh-router`, so `rmw_zenoh_cpp` connects to `tcp/127.0.0.1:7447`.
`start.sh` waits up to 60 s for that port before launching (`depends_on` orders the start, but
not readiness).

## VDA 5050

`isaacbot-amr-vda5050` connects Ardennes to a VDA 5050 **2.0** master control over MQTT. The code lives
in [`isaacbot_amr_vda5050`](https://github.com/isaacbotsrl/isaacbot_amr_vda5050): InOrbit's open-source
connector ([`ros_amr_interop`](https://github.com/inorbit-ai/ros_amr_interop), vendored as a git
subtree with a short list of patches) plus the isaacbot's adapter plugins. Orders become
`isaacbot_amr_mission_manager` missions, so every guard GoTo has applies to them too: the Automatic
driving mode, the motion lock, a dead lidar, low battery. See that repository's README for the
supported actions, the state mapping and how to test with its `fake_master.py`.

Enable it with `ISAACBOT_AMR_VDA5050_ENABLE=true` on a isaacbot that also runs
`ISAACBOT_AMR_ORCH_NAVIGATION=true` and `ISAACBOT_AMR_ORCH_MISSION_MANAGER=true`, then put the isaacbot in
Automatic from the drive UI. Master control publishes to `uagv/v2/<manufacturer>/<serial>/order`
on the isaacbot's broker (port 1883), or on its own broker with `ISAACBOT_AMR_VDA5050_LOCAL_BROKER=false` and
`ISAACBOT_AMR_VDA5050_BROKER_HOST`. SSH: `ssh -p 26 root@<isaacbot-lan-ip>`; the connector logs to
`/tmp/isaacbot_amr_vda5050.log`, Mosquitto to `/tmp/isaacbot_amr_mosquitto.log`.

The isaacbot's broker is anonymous and unencrypted: fine on the isaacbot LAN, not beyond it.

## Follow-me

Follow-me spans two containers, by layer. In `isaacbot-amr-sensors`, `isaacbot_amr_perception`'s `fmoc` tracks
a person (a Python port of Intel's ADBSCAN follow-me clustering on the RealSense depth cloud) and
publishes `tracked_person`, so the depth cloud never leaves the container. In
`isaacbot-amr-orchestrator`, `isaacbot_amr_orchestrator`'s `isaacbot_amr_follow_me` runs following as one
`FollowObject` goal of Nav 2's Following server, next to Nav 2 and the mission manager. The server keeps
1.2 m from the person, turning to face them, and its velocity goes through the velocity smoother,
the collision monitor, drive mode and the motion lock like any Nav 2 motion; follow-me never
publishes `cmd_vel`.

Enable it with `ISAACBOT_AMR_SYSTEM_FOLLOW_ME_ENABLE=true`, `ISAACBOT_AMR_SYSTEM_USE_CAMERA=true` and `ISAACBOT_AMR_SENSORS_CAMERA_DEPTH_CLOUD=true` on a isaacbot that runs Nav 2
and the mission manager, in Automatic. Stand about 1.5 m in front of the stopped isaacbot, then start
following from the drive UI (Navigate tab, *Follow me*), with the VDA 5050 instant action
`startFollowing` from fleet control, or with
`ros2 service call /isaacbot/follow_me/start std_srvs/srv/Trigger`. Following stops on
`follow_me/stop` (or `stopFollowing`), when the isaacbot leaves Automatic, when a mission starts, and
when the Following server gives up searching for a lost person. `follow_me/status` says what it is
doing. Logs: the `follow_me` node in `/tmp/isaacbot_amr_follow_me.log` on the orchestrator
(`ssh -p 24 root@<isaacbot-lan-ip>`), `fmoc` in `/tmp/isaacbot_amr_sensors.log` on the sensors container
(`ssh -p 23`).

## ROS namespace

`isaacbot-amr-platform` runs every isaacbot node under the namespace in `ISAACBOT_AMR_SYSTEM_NAMESPACE`
(default `isaacbot`, set in `docker-compose.yml`, overridable as a balenaCloud
variable), so isaacbot topics and services are `/isaacbot/cmd_vel`,
`/isaacbot/odom`, `/isaacbot/led/state`, `/isaacbot/hardware_interface/gpio_state`, …
and TF frames are `isaacbot/odom`, `isaacbot/base_link`. `/tf`, `/tf_static`,
`/rosout` and `/parameter_events` stay global, as do the web bridges
(`/rosapi/*`, `/client_count`). `isaacbot-amr-orchestrator` and
`isaacbot-amr-sensors` read the same variable as the platform, so change it on all three together — an
all-services balenaCloud variable is the safe way to do that.

## ROS 2 over the isaacbot LAN (Zenoh)

The ROS 2 graph runs on `rmw_zenoh_cpp`. The Zenoh router runs in its own service,
`isaacbot-amr-zenoh-router`, as that container's only process. A platform restart or a balena
release that doesn't touch its image leaves it (and so the graph) up. It listens on loopback
and on the isaacbot LAN address only (default `192.168.1.201`, override with the balenaCloud
variable `ISAACBOT_AMR_SYSTEM_LAN_IP`). balenaVPN and GSM are deliberately not bound. The router has no
authentication, so any host on the isaacbot LAN can join the graph. It is configured with
`ZENOH_CONFIG_OVERRIDE` on top of `rmw_zenoh_cpp`'s packaged router defaults, not with a json5
file, which would replace those defaults wholesale.

If the LAN address isn't on the device within ~10 s of startup, the router
falls back to loopback-only (logged as a `WARNING`) until the container
restarts.

The isaacbot mixes the two ways a ROS process can join Zenoh, one variable per container
(`ISAACBOT_AMR_ZENOH_MODE_PLATFORM`, `_ORCH`, `_SENSORS`, `_VDA5050`):

- **`isaacbot-amr-platform`: `peer`** (rmw_zenoh's default). Its processes link directly to each
  other, so the control loops (IMU → EKF, `cmd_vel` → twist_mux → ros2_control, safety) never
  wait on the router. They also link to the router, for everything crossing containers.
- **`isaacbot-amr-orchestrator`, `isaacbot-amr-sensors`, `isaacbot-amr-vda5050`: `client`.** One TCP link each, to the router,
  which carries all their traffic. These are the containers whose processes come and go (Nav 2
  restarts, indoor mapping ↔ localization switches). When a group of clients stops, only the
  router cleans up after it, not every process on the isaacbot.

Why the split, measured on the isaacbot on 2026-09-26. After an orchestrator restart the router
spends up to a minute at 100 % of one core cleaning up. It forwards nothing meanwhile.

| Setup | Platform topics (`imu/data`, `odom`, `/tf`) during an orchestrator restart |
|---|---|
| All peers (the old default) | 1–4 s stalls; ~600 loopback links |
| All clients | stopped for 31–58 s |
| Platform peers, the rest clients | worst gap 0.15 s; 0.13 s over six mapping ↔ localization switches |

Traffic between containers still waits on the router during such a restart (`scan` into Nav 2,
Nav 2's `cmd_vel`), which only matters while navigation is down anyway.

`start.sh` exports the client settings as `ZENOH_CONFIG_OVERRIDE` for everything it launches in
client mode:

- `connect/timeout_ms=-1`: a process started before the router waits for it rather than
  aborting with `RCLBadAlloc` (peers wait by default).
- `connect/retry` backs off from 0.5 s to 2 s, so after a router restart every process
  reconnects and re-declares its publishers and subscriptions. Platform peers keep talking to
  each other meanwhile; cross-container traffic resumes when the router is back.

`ros2` in an SSH shell is always a client, with a 5 s timeout, in every container: a command
fails fast while the router is down and stays out of the platform's mesh. `.bashrc` sources it
from `/tmp/isaacbot_amr_zenoh_cli.env`, which `start.sh` writes. Count the links with
`awk 'FNR>1 && $4=="01"' /proc/net/tcp /proc/net/tcp6 | wc -l`: about 390 socket ends with the
default split, and 70 if every process were a client.

To join from a LAN host running ROS 2 Lyrical with `rmw_zenoh_cpp`, run a local
router that dials the isaacbot, then start nodes as usual:

```bash
# on the LAN host
source /opt/ros/lyrical/setup.bash
cat > ~/isaacbot_amr_router.json5 << 'CFG'
{
  mode: "router",
  listen:  { endpoints: ["tcp/127.0.0.1:7447"] },
  connect: { endpoints: ["tcp/192.168.1.201:7447"] },
  scouting: { multicast: { enabled: false } }
}
CFG
export RMW_IMPLEMENTATION=rmw_zenoh_cpp
ZENOH_ROUTER_CONFIG_URI=~/isaacbot_amr_router.json5 ros2 run rmw_zenoh_cpp rmw_zenohd &
ros2 topic list   # in another shell with RMW_IMPLEMENTATION set
```

`ROS_DOMAIN_ID` must match on both sides (the isaacbot uses the default, `0`).

## Remote access over WireGuard

For remote work, SSH, the web UIs, Foxglove and MQTT reach the controller through a WireGuard
VPN. Nothing VPN-related runs on the device. The RUTX11 is a WireGuard peer and routes into
the isaacbot LAN, so the controller is reached at its usual LAN address, `192.168.1.201`.

```
laptop 10.8.0.4 ──wg──> server 10.8.0.1 ──wg──> RUTX11 10.8.0.5 ──firewall──> controller 192.168.1.201
```

- **Server** (`/etc/wireguard/wg0.conf`): the RUTX11 peer has
  `AllowedIPs = 10.8.0.5/32, 192.168.1.0/24`, and `PostUp` allows forwarding `wg0 → wg0`.
- **RUTX11**: interface `wg0`, peer `roverser`. Its settings:
  - Split tunnel: `allowed_ips=10.8.0.0/24`, so the isaacbot's internet traffic doesn't go through
    the server.
  - `route_allowed_ips=1`, which gives the controller's replies a way back. The controller's
    default route is the RUTX11.
  - `mtu=1380`, `persistent_keepalive=25`.
- **Laptop peer**: `AllowedIPs = 10.8.0.0/24, 192.168.1.201/32`, `MTU = 1380`. Turn the tunnel
  off while on the isaacbot LAN or AP, or isaacbot traffic hairpins through the server.

The RUTX11 firewall zone `wireguard` lets only the laptop (`10.8.0.4`) through, and only to
these ports on `192.168.1.201`:

| Port | Service |
|---|---|
| 22–26 | SSH into the containers |
| 80, 5000 | Drive UI (`ISAACBOT_AMR_UI_PORT`; the fleet variable sets 80) |
| 5080 | Uplink page |
| 8765 | foxglove_bridge |
| 1883, 9001 | MQTT, MQTT over WebSockets |
| ICMP echo | ping |

The router itself answers ping, SSH (22) and HTTPS (443) on `10.8.0.5`. A final rule,
`VPN-reject-everything-else`, rejects the rest, Zenoh 7447 and rosbridge 9090 included. It is
required: RutOS's default forward policy is ACCEPT, and the zone's `forward=REJECT` only covers
traffic leaving `wg0`. To let in another VPN peer or port, copy a `VPN-laptop-ctrl-*` rule and
`uci reorder` it before the reject.

On the SIM uplink, keep data down:

- Foxglove sends exactly what a panel subscribes to. Leave point clouds, images and costmaps
  closed.
- Subscribe MQTT to specific topics, not `#`.
- Deploy (`balena push` image pulls) only on Wi-Fi.
