# Copyright 2026 IsaacBot
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# isaacbot-amr-sensors: the Ardennes sensor payload (GNSS, lidar, RealSense camera) from the
# isaacbot_amr_sensors repo, and the perception on top of it (isaacbot_amr_perception: AprilTag, detection,
# terrain slope, fmoc person tracking), so camera data never leaves this container.
#
# Sibling of isaacbot-amr-platform (base, controller, localization, safety)
# and isaacbot-amr-orchestrator (Nav 2, mission manager, follow-me). The payload is kept in its own
# image so a different GPS, lidar or camera is a change to this image only: its nodes only
# publish (gps/fix, scan, rslidar_points, camera/*, tracked_person, diagnostics). Of isaacbot_amr_ros it
# needs only the isaacbot_amr_msgs interfaces; nothing depends on isaacbot_amr_orchestrator. Joins isaacbot-amr-zenoh-router's Zenoh router over host networking, which is also
# what lets the drivers receive the RUTX11 NMEA (UDP 10110) and the RS16 (UDP 6699/7788).
#
# Deliberately lean apart from two things. An sshd on 23 (22 is isaacbot-amr-platform's, 24 is
# isaacbot-amr-orchestrator's - host networking gives every container one port space). And the Claude
# Code / ros-mcp tooling, kept at parity with the other two ROS images so `claude` behaves the
# same on any of the three shells; as in isaacbot-amr-orchestrator it needs no rosbridge of its
# own, because that shared namespace puts isaacbot-amr-platform's on 127.0.0.1:9090.

# --- Build-only stage: the person detector's model -----------------------------------------
# YOLO11n (Ultralytics, AGPL-3.0: fine for this in-house isaacbot, swap it before shipping isaacbots to
# others) exported to ONNX at 320 px, about 4x cheaper than 640 on the Pi 5 CPU. Torch and
# Ultralytics stay in this stage; only the ~10 MB .onnx reaches the runtime image. CPU torch wheels
# keep the stage small on both arm64 (balena) and x86_64 (dev builds). Versions and the weights
# checksum are pinned so a rebuild exports the same model.
FROM python:3.12-slim-bookworm AS yolo-export
ARG YOLO_WEIGHTS_URL=https://github.com/ultralytics/assets/releases/download/v8.3.0/yolo11n.pt
ARG YOLO_WEIGHTS_SHA256=0ebbc80d4a7680d14987a577cd21342b65ecfd94632bd9a8da63ae6417644ee1
ARG YOLO_IMGSZ=320
# libgl1 / libglib2.0-0: Ultralytics imports OpenCV (opencv-python), which links them.
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu \
       torch==2.14.1 torchvision==0.29.1 \
    && pip install --no-cache-dir ultralytics==8.4.172 onnx==1.23.2 onnxslim==0.1.98
WORKDIR /export
RUN python -c "import urllib.request; urllib.request.urlretrieve('${YOLO_WEIGHTS_URL}', 'yolo11n.pt')" \
    && echo "${YOLO_WEIGHTS_SHA256}  yolo11n.pt" | sha256sum -c -
# YOLO_OFFLINE: no update checks or requirement auto-installs during the export.
RUN YOLO_OFFLINE=1 yolo export model=yolo11n.pt format=onnx imgsz=${YOLO_IMGSZ} \
    && test -s yolo11n.onnx

# --- Runtime image -----------------------------------------------------------------------------
FROM ubuntu:26.04

# Avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=lyrical

RUN apt-get update && apt-get install -y \
    curl wget gnupg2 lsb-release software-properties-common \
    build-essential git locales \
    && rm -rf /var/lib/apt/lists/*

##################################### SSH ################################################

# Above the ROS and workspace layers so the expensive clone / rosdep / colcon steps below
# keep their cache. Same arrangement as isaacbot-amr-orchestrator: root password login through an
# sshd_config.d drop-in, only the port differs. See README.md "Sensors SSH".
RUN apt-get update && apt-get install -y openssh-server \
    && mkdir -p /var/run/sshd \
    && rm -rf /var/lib/apt/lists/*

RUN echo 'root:root' | chpasswd \
    && printf 'Port 23\nPermitRootLogin yes\nUsePAM no\n' \
       > /etc/ssh/sshd_config.d/isaacbot_amr_sensors.conf

# Documentation only - host networking ignores EXPOSE.
EXPOSE 23

##################################### Claude Code CLI ####################################

# Node.js (LTS) via NodeSource, then the Claude Code CLI - the same pair isaacbot-amr-platform and
# isaacbot-amr-orchestrator install. Above the ROS and workspace layers for the reason the sshd
# block gives: the git clone / rosdep / colcon build steps below are the expensive ones. The
# cost of that placement is that bumping either tool invalidates those layers under it.
#
# The NodeSource setup script runs its own apt-get update, so this works even though the
# layer above ends with `rm -rf /var/lib/apt/lists/*`.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

##################################### ros-mcp-server #####################################

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# Baked into the image at build time, so the robot needs no PyPI fetch at runtime. fastmcp is
# held below 4 deliberately: ros-mcp 3.1.0 asks only for `fastmcp>=2.11.3`, but fastmcp 4 moved
# `fastmcp.tools.tool` to `fastmcp.tools.base`, so an unconstrained install resolves fastmcp 4
# and ros-mcp dies on import with ModuleNotFoundError - which Claude Code reports only as a
# CONNECTION_CLOSED server. Drop the constraint once ros-mcp ships fastmcp 4 support; ros-mcp
# itself stays unpinned, so rebuilds still pick up new releases.
RUN uv tool install ros-mcp --with "fastmcp<4"

# Registered at user scope so it is available no matter which directory `claude` is started
# from over SSH. ros-mcp reaches rosbridge at 127.0.0.1:9090, which runs in isaacbot-amr-platform -
# all three ROS services are network_mode: host and share one network namespace. This image
# runs no rosbridge of its own and needs none.
RUN claude mcp add ros-mcp --scope user -- ros-mcp --transport=stdio

##########################################################################################

RUN add-apt-repository universe

# Set up locale
RUN locale-gen en_US en_US.UTF-8 && update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
ENV LANG=en_US.UTF-8

##################################### ROS2 install #######################################

# Add ROS 2 apt repository
RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg
RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" | tee /etc/apt/sources.list.d/ros2.list > /dev/null

SHELL ["/bin/bash", "-c"]

# ros-base, not desktop: no GUI here. rmw_zenoh_cpp matches the middleware isaacbot-amr-zenoh-router
# speaks. libpcap-dev: isaacbot_amr_rs16_lidar's pcap replay input (rosdep would also install
# it; listed so the dependency is visible here).
RUN apt-get update && apt-get install -y \
    ros-dev-tools \
    ros-${ROS_DISTRO}-ros-base \
    ros-${ROS_DISTRO}-rmw-zenoh-cpp \
    ros-${ROS_DISTRO}-ament-cmake \
    python3-colcon-common-extensions \
    libpcap-dev \
    && rm -rf /var/lib/apt/lists/*

RUN echo "source /opt/ros/${ROS_DISTRO}/setup.bash" >> /root/.bashrc
# No ZENOH_ROUTER_CONFIG_URI: this container is a Zenoh session, not a router. The router
# runs in isaacbot-amr-zenoh-router and every service shares the host network namespace.
RUN echo "export RMW_IMPLEMENTATION=rmw_zenoh_cpp" >> /root/.bashrc
# ros2 CLI over SSH: the Zenoh client settings start.sh writes
# (empty with ISAACBOT_AMR_ZENOH_MODE_SENSORS=peer).
RUN echo '[ -r /tmp/isaacbot_amr_zenoh_cli.env ] && . /tmp/isaacbot_amr_zenoh_cli.env' >> /root/.bashrc
# ENV PATH above reaches `docker exec`, but sshd builds a fresh environment for login shells,
# so without this `ros-mcp` is off PATH over SSH and Claude fails to spawn the MCP server.
RUN echo "export PATH=\"\$PATH:/root/.local/bin\"" >> /root/.bashrc

##################################### Sensors workspace ##################################

RUN mkdir -p ~/ros2_ws/ardennes
WORKDIR /root/ros2_ws/ardennes

# Tracks main by default, so every `--nocache` build picks up the latest commit; pin with
# --build-arg ISAACBOT_AMR_SENSORS_REF=<ref>.
ARG ISAACBOT_AMR_SENSORS_REF=main
RUN git clone https://github.com/isaacbotsrl/isaacbot_amr_sensors.git src/isaacbot_amr_sensors \
    && git -C src/isaacbot_amr_sensors checkout ${ISAACBOT_AMR_SENSORS_REF}

# Perception nodes (AprilTag, YOLO detection, terrain slope, fmoc person tracking);
# isaacbot_amr_sensors_bringup includes its launch file, which does nothing until ISAACBOT_AMR_SYSTEM_USE_CAMERA /
# ISAACBOT_AMR_SENSORS_TERRAIN / ISAACBOT_AMR_SYSTEM_FOLLOW_ME_ENABLE is true. Pin with --build-arg ISAACBOT_AMR_PERCEPTION_REF=<ref>.
ARG ISAACBOT_AMR_PERCEPTION_REF=main
RUN git clone https://github.com/isaacbotsrl/isaacbot_amr_perception.git src/isaacbot_amr_perception \
    && git -C src/isaacbot_amr_perception checkout ${ISAACBOT_AMR_PERCEPTION_REF}

# isaacbot_amr_ros is cloned only for isaacbot_amr_msgs (TrackedPerson); nothing else of it is built or
# rosdep-resolved. Keep ISAACBOT_AMR_ROS_REF equal in isaacbot_amr_platform, isaacbot_amr_orchestrator,
# isaacbot_amr_vda5050 and here.
ARG ISAACBOT_AMR_ROS_REF=main
RUN git clone https://github.com/isaacbotsrl/isaacbot_amr_ros.git src/isaacbot_amr_ros \
    && git -C src/isaacbot_amr_ros checkout ${ISAACBOT_AMR_ROS_REF}

RUN vcs import src < src/isaacbot_amr_sensors/sensors_deps.repos

RUN rosdep init
RUN rosdep update --rosdistro "${ROS_DISTRO}"
# apt-get update in the same RUN: the layers above end with `rm -rf /var/lib/apt/lists/*`,
# and rosdep shells out to a bare `apt-get install` that needs the index. Everything in src
# except isaacbot_amr_ros, of which only isaacbot_amr_msgs is built (its hardware and Gazebo dependencies
# are not wanted here).
RUN apt-get update \
    && rosdep install \
       --from-paths $(find src -mindepth 1 -maxdepth 1 -type d ! -name isaacbot_amr_ros) src/isaacbot_amr_ros/isaacbot_amr_msgs \
       --rosdistro "${ROS_DISTRO}" -y -i \
    && rm -rf /var/lib/apt/lists/*

# CPU ONNX Runtime for isaacbot_amr_perception_detection (not a rosdep key); ~15 MB, loaded only when
# ISAACBOT_AMR_SENSORS_CAMERA_DETECTION=true.
RUN uv pip install --system --break-system-packages onnxruntime

RUN source /opt/ros/${ROS_DISTRO}/setup.bash \
    && colcon build --symlink-install --packages-up-to isaacbot_amr_sensors_bringup \
       --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
RUN echo "source /root/ros2_ws/ardennes/install/setup.bash" >> /root/.bashrc

# The person detector's model (stage yolo-export above). start.sh points
# ISAACBOT_AMR_SENSORS_CAMERA_DETECTION_MODEL here when the variable is unset or empty.
COPY --from=yolo-export /export/yolo11n.onnx /opt/models/yolo11n.onnx

WORKDIR /root

COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh
CMD ["/usr/local/bin/start.sh"]
