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

# isaacbot-amr-vda5050: the VDA 5050 fleet interface of Ardennes.
#
# Master control (MQTT/JSON, VDA 5050 2.0) -> InOrbit's connector (vendored in isaacbot_amr_vda5050)
# -> isaacbot_amr_vda5050_adapter -> isaacbot_amr_mission_manager (isaacbot-amr-orchestrator) -> Nav 2. Plus a
# Mosquitto broker for master controls that bring none (ISAACBOT_AMR_VDA5050_LOCAL_BROKER). Like the
# other ROS services it joins isaacbot-amr-zenoh-router over host networking, runs an sshd on its own
# port (26) and carries the Claude Code / ros-mcp tooling for parity with them.
FROM ubuntu:26.04

# Avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=lyrical

RUN apt-get update && apt-get install -y \
    curl wget gnupg2 lsb-release software-properties-common \
    build-essential git locales \
    && rm -rf /var/lib/apt/lists/*

##################################### SSH ################################################

# Above the workspace layers, which are the expensive ones (see isaacbot_amr_orchestrator).
#
# Port 26, not 22: every service in docker-compose.yml is network_mode: host, so they share
# one port space and each sshd gets its own port - platform 22, sensors 23, orchestrator 24,
# drive-interface 25, vda5050 26.
RUN apt-get update && apt-get install -y openssh-server \
    && mkdir -p /var/run/sshd \
    && rm -rf /var/lib/apt/lists/*

# Root password login, the same arrangement as isaacbot-amr-platform and isaacbot-amr-orchestrator.
RUN echo 'root:root' | chpasswd \
    && printf 'Port 26\nPermitRootLogin yes\nUsePAM no\n' \
       > /etc/ssh/sshd_config.d/isaacbot_amr_vda5050.conf

# Documentation only - host networking ignores EXPOSE. 1883/9001: Mosquitto (MQTT / WebSockets).
EXPOSE 26 1883 9001

##################################### MQTT broker ########################################

# Started by start.sh only with ISAACBOT_AMR_VDA5050_LOCAL_BROKER=true, with the configuration in
# isaacbot_amr_vda5050_bringup (config/mosquitto.conf). The Debian service is never used.
RUN apt-get update && apt-get install -y mosquitto mosquitto-clients \
    && rm -rf /var/lib/apt/lists/*

##################################### Claude Code CLI ####################################

# Same pair as isaacbot-amr-orchestrator, above the workspace layers for the same reason.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

##################################### ros-mcp-server #####################################

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# fastmcp < 4: ros-mcp 3.1.0 dies on import with fastmcp 4 (see isaacbot_amr_orchestrator).
RUN uv tool install ros-mcp --with "fastmcp<4"

# ros-mcp reaches rosbridge at 127.0.0.1:9090, served by isaacbot-amr-platform (shared host network).
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

# ros-base: no GUI. rmw_zenoh_cpp matches the middleware isaacbot-amr-zenoh-router speaks.
RUN apt-get update && apt-get install -y \
    ros-dev-tools \
    ros-${ROS_DISTRO}-ros-base \
    ros-${ROS_DISTRO}-rmw-zenoh-cpp \
    ros-${ROS_DISTRO}-ament-cmake \
    python3-colcon-common-extensions \
    && rm -rf /var/lib/apt/lists/*

RUN echo "source /opt/ros/${ROS_DISTRO}/setup.bash" >> /root/.bashrc
# No ZENOH_ROUTER_CONFIG_URI: this container is a Zenoh client, not a router.
RUN echo "export RMW_IMPLEMENTATION=rmw_zenoh_cpp" >> /root/.bashrc
# ros2 CLI over SSH: the Zenoh client settings start.sh writes.
RUN echo '[ -r /tmp/isaacbot_amr_zenoh_cli.env ] && . /tmp/isaacbot_amr_zenoh_cli.env' >> /root/.bashrc
# sshd builds a fresh environment for login shells; keep ros-mcp on PATH there too.
RUN echo "export PATH=\"\$PATH:/root/.local/bin\"" >> /root/.bashrc

##################################### VDA 5050 workspace #################################

RUN mkdir -p ~/ros2_ws/ardennes
WORKDIR /root/ros2_ws/ardennes

# isaacbot_amr_vda5050 carries everything VDA 5050: the InOrbit connector (third_party/, a git subtree)
# and the isaacbot's adapter and bringup. isaacbot_amr_ros is cloned only for isaacbot_amr_msgs (mission, drive
# mode and safety messages); nothing else of it is built or rosdep-resolved.
# Keep ISAACBOT_AMR_ROS_REF equal in isaacbot_amr_platform, isaacbot_amr_orchestrator and here.
ARG ISAACBOT_AMR_ROS_REF=feat/automatic-localization
ARG ISAACBOT_AMR_VDA5050_REF=feat/automatic-localization
RUN git clone https://github.com/isaacbotsrl/isaacbot_amr_ros.git src/isaacbot_amr_ros \
    && git -C src/isaacbot_amr_ros checkout ${ISAACBOT_AMR_ROS_REF}
RUN git clone https://github.com/isaacbotsrl/isaacbot_amr_vda5050.git src/isaacbot_amr_vda5050 \
    && git -C src/isaacbot_amr_vda5050 checkout ${ISAACBOT_AMR_VDA5050_REF}

RUN rosdep init
RUN rosdep update --rosdistro "${ROS_DISTRO}"
# Only the packages built here: isaacbot_amr_ros's hardware packages would otherwise pull their apt
# dependencies too. apt-get update in the same RUN - rosdep does not refresh the index itself
# (see isaacbot_amr_orchestrator). Brings python3-paho-mqtt, pluginlib, tf2_ros, ...
RUN apt-get update \
    && rosdep install --from-paths src/isaacbot_amr_vda5050 src/isaacbot_amr_ros/isaacbot_amr_msgs \
       --rosdistro "${ROS_DISTRO}" -y -i \
    && rm -rf /var/lib/apt/lists/*

RUN source /opt/ros/${ROS_DISTRO}/setup.bash \
    && colcon build --symlink-install --packages-up-to isaacbot_amr_vda5050 \
       --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
RUN echo "source /root/ros2_ws/ardennes/install/setup.bash" >> /root/.bashrc

WORKDIR /root

COPY start.sh /usr/local/bin/start.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/healthcheck.sh
CMD ["/usr/local/bin/start.sh"]
