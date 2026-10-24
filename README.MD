# Qt Development Environment

This repository provides a Docker image for building and developing applications for education/learning purposes using **Qt**, **Qt Creator**, **Vulkan**, **GLFW**, **Dear ImGui**, **CUDA**, and other tools with support for **X11**.

---

## 🧰 Technologies Included

The Docker environment that you can build includes:

* **[CMake](https://github.com/Kitware/CMake)** (Apache 2.0)
* **[GLFW](https://github.com/glfw/glfw)** (zlib/libpng license)
* **[Vulkan SDK](https://vulkan.lunarg.com/sdk/)** (Apache 2.0 / MIT depending on component)
* **[LLVM & Clang](https://llvm.org/)** (Apache 2.0 with LLVM Exception)
* **[FFmpeg](https://ffmpeg.org/)** (LGPL/GPL depending on configuration)
* **[Qt 6](https://www.qt.io/)** (GPLv3 or Commercial License)
* **[Qt Creator](https://www.qt.io/product/development-tools)** (GPLv3)
* **[Dear ImGui](https://github.com/ocornut/imgui)** (MIT)
* **[SDL3](https://github.com/libsdl-org/SDL)** (zlib License)
* **[SDL3_ttf](https://github.com/libsdl-org/SDL_ttf)** (zlib License)
* **[GLAD](https://github.com/Dav1dde/glad)** (Apache 2.0)
* **[GLM](https://github.com/g-truc/glm)** (MIT License)
* **[nlohmann/json](https://github.com/nlohmann/json)** (MIT License)
* **[SQLiteCpp](https://github.com/SRombauts/SQLiteCpp)** (MIT License)
* **[raylib](https://www.raylib.com/)** (zlib License)
* **[libink](https://github.com/Arthu-RL/libink)** (MIT License)
* **[ONNX Runtime](https://github.com/microsoft/onnxruntime)** (MIT License)
* **[stb libraries](https://github.com/nothings/stb)** (Public Domain / MIT License)
* **[Emscripten](https://emscripten.org/)** (MIT / NCSA Open Source License)
* **[Gradle](https://gradle.org/)** (Apache 2.0)

---

## 🔧 Build the Docker Image

To build the Docker image:

```bash
python3 build_run.py --build --base --retry 2 --image_tag="base"
python3 build_run.py --build --retry 2 --image_tag="lts"
```

## 🔧 Run the Docker Image

To run the Docker image:

```bash
python3 build_run.py --run --image_tag="lts"
```

Before starting the container, instead of doing `xhost +` command, do this:

```sh
alias start_vulkan_dev="cat $XAUTHORITY > ~/.docker_xauth && docker start vulkan-dev"
```

`--run` looks at the host and passes only what it has, so the same command works on an older
machine that runs X11 (no Wayland socket, no NVIDIA runtime, no sound card):

| Host has | Container gets |
|---|---|
| a Wayland socket (`$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`) | the socket, `XDG_SESSION_TYPE=wayland`; otherwise `x11` |
| `nvidia-smi` | `--gpus all` and the NVIDIA ICD; otherwise Mesa through `/dev/dri` |
| `/dev/dri`, `/dev/snd` | the devices |
| `$XAUTHORITY` (or `~/.Xauthority`) | a copy at `~/.docker_xauth`; with none, run `xhost +local:docker` once |

A disposable X server for tests and bare-display runs:

```sh
docker exec -d vulkan-dev Xvfb :77 -screen 0 800x600x24 -nolisten tcp
docker exec -e DISPLAY=:77 vulkan-dev <your test>
```

---

## 🖥️ Nested Hyprland

The image ships Hyprland so a desktop shell (AuraShell/AuraBar) can be developed
against a real compositor, nested inside the host's Wayland session.

```sh
docker exec -it vulkan-dev hypr-nested          # a 1600x900 Hyprland window opens

docker exec -it vulkan-dev bash
eval "$(hypr-env)"                              # points clients at the nested session
./libaurashell/build/linux/debug/apps/AuraBar/AuraBar
```

| | |
|---|---|
| `hypr-nested` | starts the nested compositor; seeds `~/.config/hypr/hyprland.conf` on first run |
| `hypr-env` | prints `HYPRLAND_INSTANCE_SIGNATURE` and `WAYLAND_DISPLAY` for the newest instance |
| `ALT+Return` | terminal (foot) · `ALT+1..5` workspaces · `ALT+SHIFT+E` exit |

The nested session's sockets stay inside the container, so it cannot collide
with the host's own compositor.

**GPU is mandatory.** `run()` requests it through CDI (`--device nvidia.com/gpu=all`);
`--gpus all` on a runc daemon injects no driver userspace, and without the NVIDIA
GBM backend the nested output never leaves 0x0. After a driver update:

```sh
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
```

DRM/KMS directly in the container is a different problem (seat, logind, DRM
master) and is not what this setup targets.