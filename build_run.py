import argparse
import subprocess as sp
import logging as log
import os
import shlex
import shutil

from typing import Dict, List, Optional

log.basicConfig(level=log.INFO, format='%(levelname)s: %(message)s')


def parse_build_args(build_args: str) -> Dict[str, str]:
    build_args_dict: Dict[str, str] = {}
    args_list = build_args.split()

    for arg in args_list:
        key, value = arg.split('=')
        build_args_dict.update({key: value})
    
    return build_args_dict

def build(image: str, dockerfile: str, build_args: Optional[str], retry: int) -> None:
    build_args_cmd: str = ""
    if build_args:
        build_args_dict = parse_build_args(build_args)
        for key, value in build_args_dict.items():
            build_args_cmd += f"--build-arg {key.upper()}=\"{value}\" "

    build_command: str = f"docker build {build_args_cmd} -t {image} -f {dockerfile} .".strip()

    log.info(f"Running build command: {build_command}")

    for _ in range(retry):
        try:
            result = sp.run(build_command, shell=True, check=True, capture_output=True, text=True)
            log.info(f"Build output:\n{result.stderr}")

            break
        except sp.CalledProcessError as e:
            log.error(f"Build failed with error:\n{e.stderr}")

def run(project_path: str, image: str, container_name: str) -> None:
    """
    Runs the container of arthurrl/vulkan-dev:lts image, this will run correctly. 
    Only nvidia graphics cards are supported, if you use AMD graphics card, 
    you wil need to change things, in docker run, and Dockerfile too probably, building new images

    GPU is requested through CDI (--device nvidia.com/gpu=all), not --gpus all.
    With the daemon on runc, --gpus all sets a device request the nvidia hook
    never reads: the container comes up with /dev/dri but no driver userspace,
    so Vulkan quietly falls back to Mesa and, more visibly, the NVIDIA GBM
    backend is missing and a nested Hyprland cannot allocate a single buffer.
    CDI reads /etc/cdi/nvidia.yaml and mounts the driver in. Regenerate that
    spec after a driver update: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

    Only the host's own Wayland socket is bind-mounted, not the whole runtime
    dir: a nested compositor started inside the container then creates its
    sockets in the container's own /run/user, where they cannot collide with
    the host session's or outlive the container.

    Notes:
        The qtcreator volume works because of the dockerfile file config of the container HOME variable

        RUN mkdir -p /home/developer
        ENV HOME=/home/developer
        WORKDIR /home/developer    
    """ 
    home: str = os.getenv("HOME", "")
    display: str = os.getenv("DISPLAY", ":0")
    runtime_dir: str = os.getenv("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    wayland_display: str = os.getenv("WAYLAND_DISPLAY", "")
    wayland_socket: str = os.path.join(runtime_dir, wayland_display) if wayland_display else ""

    # Every optional piece below is added only if this host has it. A bind mount whose source is missing makes
    # Docker create a directory in its place (or refuse to start), and --gpus needs the NVIDIA runtime, so an older
    # X11-only machine would otherwise fail on flags it never needed.
    has_wayland: bool = bool(wayland_socket) and os.path.exists(wayland_socket)
    has_nvidia: bool = shutil.which("nvidia-smi") is not None

    # The X authority the container presents; the alias in README.MD refreshes it before `docker start`.
    xauth_source: str = os.getenv("XAUTHORITY") or os.path.join(home, ".Xauthority")
    xauth_copy: str = os.path.join(home, ".docker_xauth")
    if os.path.isfile(xauth_source):
        shutil.copyfile(xauth_source, xauth_copy)
    elif not os.path.exists(xauth_copy):
        log.warning("No X authority file found; X11 apps in the container need `xhost +local:docker` on the host")
        open(xauth_copy, "a").close()

    flags: List[str] = [
        "-d", "--name", container_name, "--ipc=host",
        "-e", f"DISPLAY={display}",
        "-e", f"XDG_SESSION_TYPE={'wayland' if has_wayland else 'x11'}",
        "-v", "/tmp/.X11-unix:/tmp/.X11-unix",
        "-v", f"{xauth_copy}:/home/developer/.Xauthority:ro",
        "-v", f"{project_path}:/home/developer/workspace",
        "-v", f"{project_path}/qtcreator_config:/home/developer/.config/QtProject",
        "-w", "/home/developer/workspace",
    ]
    if has_wayland:
        flags += ["-e", f"XDG_RUNTIME_DIR={runtime_dir}", "-e", f"WAYLAND_DISPLAY={wayland_display}",
                  "-v", f"{wayland_socket}:{wayland_socket}"]
    if has_nvidia:
        flags += ["--gpus", "all", "-e", "NVIDIA_VISIBLE_DEVICES=all", "-e", "NVIDIA_DRIVER_CAPABILITIES=all"]
        if os.path.exists("/usr/share/vulkan/icd.d/nvidia_icd.json"):
            flags += ["-v", "/usr/share/vulkan/icd.d/nvidia_icd.json:/usr/share/vulkan/icd.d/nvidia_icd.json:ro"]
    for device in ("/dev/dri", "/dev/snd"):
        if os.path.exists(device):
            flags += ["--device", f"{device}:{device}"]

    sp.run(["docker", "rm", "-f", container_name], capture_output=True)
    run_command = shlex.join(["docker", "run", *flags, image])

    log.info(f"Run command:\n{run_command}")

    try:
        result = sp.run(["docker", "run", *flags, image], check=True, capture_output=True, text=True)
        log.info(f"Run output:\n{result.stdout}")
    except sp.CalledProcessError as e:
        log.error(f"Run failed with error:\n{e.stderr}")
        exit(1)

def push(image: str) -> None:
    run_command: str = f"""
        docker push {image}
    """

    log.info(f"Run command:\n{run_command}")

    try:
        result = sp.run(run_command, shell=True, check=True, capture_output=True, text=True)
        log.info(f"Push output:\n{result.stdout}")
    except sp.CalledProcessError as e:
        log.error(f"Push failed with error:\n{e.stderr}")
        exit(1)


parser: argparse.ArgumentParser = argparse.ArgumentParser(description="Build Vulkan dev image")

parser.add_argument('--run', dest='run', action='store_true', help='Run container instead of building', required=False)
parser.add_argument('--build', dest='build', action='store_true', help='Build docker image', required=False)
parser.add_argument('-r', '--retry', dest='retry', type=int, help='Build docker image', required=False, default=1)
parser.add_argument('--base', dest='base', action='store_true', help='Build docker image Base/Derived', required=False)
parser.add_argument('--push', dest='push', action='store_true', help='Push image to dockerhub after building', required=False)
parser.add_argument('-p', '--project_path', dest='project_path', type=str, help='Path to the project', default=f"{os.getenv('HOME')}/dev")
parser.add_argument('-ir', '--image_repo', dest='image_repo', type=str, help='Tag of the dev image', default='arthurrl')
parser.add_argument('-in', '--image_name', dest='image_name', type=str, help='Name of the dev image', default='vulkan-dev')
parser.add_argument('-it', '--image_tag', dest='image_tag', type=str, help='Tag of the dev image', default='latest')
parser.add_argument('-c', '--container_name', dest='container_name', type=str, help='Name of the dev container', default='vulkan-dev')
parser.add_argument('-ba', '--build_args', dest='build_args', type=str, help="Docker Build args container passed in StringList formatter sep=' '", default=None)

args: argparse.Namespace = parser.parse_args()

if not os.path.isdir(args.project_path):
    os.makedirs(args.project_path, exist_ok=True)

if not (len(args.image_name) > 0):
    log.error(f"image_name parameter required!")
    parser.print_help()
    exit(1)

image: str = f"{args.image_repo}/{args.image_name}:{args.image_tag}"
image = image.removeprefix('/')

if args.build:
    build(image=image, dockerfile='Dockerfile.base' if args.base else 'Dockerfile', build_args=args.build_args, retry=args.retry)

if args.run:
    run(project_path=args.project_path, image=image, container_name=args.container_name)

if args.push:
    push(image=image)