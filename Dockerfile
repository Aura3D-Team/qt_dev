FROM arthurrl/vulkan-dev:base

############################################
# Pre-Configs
############################################
WORKDIR /workspace

RUN mkdir -p /home/developer
ENV HOME=/home/developer
WORKDIR /home/developer

###################################
# Unified System Dependencies
###################################
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    # Java 21 LTS (Required for modern Android Tools & SDKs)
    openjdk-21-jdk \
    # ONNX & Pybind
    libonnx-dev pybind11-dev \
    # Wayland (Required for libwma)
    wayland-protocols libwayland-dev \
    # X11 (Required for libwma's X11 backend + running desktop/GUI apps)
    libx11-dev libxext-dev xauth \
    # Vulkan & Mesa
    libvulkan1 libvulkan-dev vulkan-tools mesa-vulkan-drivers && \
    apt-get clean && apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

############################################
# Vulkan SDK Setup
############################################
ENV VULKAN_SDK_VERSION="1.4.350.0"

RUN mkdir -p ${LOCAL_PREFIX}/VulkanSDK && \
    wget -qO /tmp/vulkansdk.tar.xz "https://sdk.lunarg.com/sdk/download/${VULKAN_SDK_VERSION}/linux/vulkansdk-linux-x86_64-${VULKAN_SDK_VERSION}.tar.xz" && \
    tar -xJf /tmp/vulkansdk.tar.xz -C ${LOCAL_PREFIX}/VulkanSDK && \
    rm -f /tmp/vulkansdk.tar.xz

ENV VMA_VERSION=3.4.0
RUN wget "https://github.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator/archive/refs/tags/v${VMA_VERSION}.tar.gz" -O /tmp/vma.tar.gz && \
    tar -xzf /tmp/vma.tar.gz -C /tmp && \
    cp /tmp/VulkanMemoryAllocator-${VMA_VERSION}/include/* ${LOCAL_PREFIX}/include/ && \
    rm -rf /tmp/vma.tar.gz /tmp/VulkanMemoryAllocator-${VMA_VERSION}

ENV VULKAN_SDK="${LOCAL_PREFIX}/VulkanSDK/${VULKAN_SDK_VERSION}/x86_64"
ENV VK_ADD_LAYER_PATH="${VULKAN_SDK}/share/vulkan/explicit_layer.d"
ENV PKG_CONFIG_PATH="${VULKAN_SDK}/share/pkgconfig:${VULKAN_SDK}/lib/pkgconfig:${PKG_CONFIG_PATH}"

############################################
# Android SDK, NDK, and Gradle Setup
############################################
ENV JAVA_HOME="/usr/lib/jvm/java-21-openjdk-amd64"
ENV ANDROID_HOME="/opt/android-sdk"
ENV ANDROID_SDK_ROOT=${ANDROID_HOME}
ENV ANDROID_NDK_VERSION="28.0.13004108"
ENV ANDROID_NDK_HOME="${ANDROID_HOME}/ndk/${ANDROID_NDK_VERSION}"

RUN mkdir -p ${ANDROID_HOME}/cmdline-tools && \
    wget -q \
      https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
      -O /tmp/cmdline-tools.zip && \
    unzip -q /tmp/cmdline-tools.zip -d /tmp && \
    mv /tmp/cmdline-tools ${ANDROID_HOME}/cmdline-tools/latest && \
    rm -f /tmp/cmdline-tools.zip

ENV PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${PATH}"
ENV PATH="${ANDROID_HOME}/platform-tools:${PATH}"

RUN yes | sdkmanager --licenses >/dev/null && \
    sdkmanager \
        "platform-tools" \
        "platforms;android-35" \
        "build-tools;35.0.0" \
        "ndk;${ANDROID_NDK_VERSION}"

ENV GRADLE_VERSION="9.6.0"
ENV GRADLE_HOME="/opt/gradle/gradle-${GRADLE_VERSION}"
RUN wget -q "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" -O /tmp/gradle.zip && \
    mkdir -p /opt/gradle && \
    unzip -q /tmp/gradle.zip -d /opt/gradle && \
    rm /tmp/gradle.zip

############################################
# Emscripten (WebAssembly) Setup
############################################
ENV EMSDK="/opt/emsdk"
ENV EMSCRIPTEN_VERSION="6.0.0"
RUN git clone "https://github.com/emscripten-core/emsdk.git" ${EMSDK} && \
    cd ${EMSDK} && \
    git fetch --tags && \
    ./emsdk install ${EMSCRIPTEN_VERSION} && \
    ./emsdk activate ${EMSCRIPTEN_VERSION}

# Globally inject cross-compiler paths into image environment
ENV PATH="${ANDROID_HOME}/platform-tools:${GRADLE_HOME}/bin:${EMSDK}:${EMSDK}/upstream/emscripten:${VULKAN_SDK}/bin:${PATH}"

###################################
# C++ Libraries
###################################

ENV GLFW_VERSION="3.4"
RUN wget "https://github.com/glfw/glfw/archive/refs/tags/${GLFW_VERSION}.tar.gz" -O /tmp/glfw-${GLFW_VERSION}.tar.gz && \
    tar -xzf /tmp/glfw-${GLFW_VERSION}.tar.gz -C /tmp/ && \
    rm -rf /tmp/glfw-${GLFW_VERSION}.tar.gz && \
    cmake -S /tmp/glfw-${GLFW_VERSION} -B /tmp/glfw-${GLFW_VERSION}/build_static \
        -DCMAKE_INSTALL_PREFIX=${LOCAL_PREFIX} \
        -DBUILD_SHARED_LIBS=OFF && \
    cmake --build /tmp/glfw-${GLFW_VERSION}/build_static --target install --parallel $(( ($(nproc)+1)/2 )) && \
    rm -rf /tmp/glfw-${GLFW_VERSION}

ENV SDL_VERSION="3.4.10"
RUN wget "https://github.com/libsdl-org/SDL/releases/download/release-${SDL_VERSION}/SDL3-${SDL_VERSION}.tar.gz" -O /tmp/SDL3-${SDL_VERSION}.tar.gz && \
    tar -xzf /tmp/SDL3-${SDL_VERSION}.tar.gz -C /tmp/ && \
    rm -rf /tmp/SDL3-${SDL_VERSION}.tar.gz && \
    cmake -S /tmp/SDL3-${SDL_VERSION} -B /tmp/SDL3-${SDL_VERSION}/build_static \
        -DCMAKE_INSTALL_PREFIX=${LOCAL_PREFIX} \
        -DBUILD_SHARED_LIBS=OFF \
        -DSDL_ALSA=ON \
        -DSDL_OPENGL=ON \
        -DSDL_VULKAN=ON \
        -DSDL_X11_XSCRNSAVER=OFF && \
    cmake --build /tmp/SDL3-${SDL_VERSION}/build_static --target install --parallel $(( ($(nproc)+1)/2 )) && \
    rm -rf /tmp/SDL3-${SDL_VERSION}

# libwma's android/wasm presets resolve SDL3 via CMAKE_PREFIX_PATH=${LOCAL_PREFIX}/<target>,
# so it needs its own cross-compiled install per target (the host build above isn't ABI-compatible).
#
# The wasm build below adds -pthread: libink's ThreadPool/WorkerThread require
# it on Emscripten (ink/src/CMakeLists.txt exports it PUBLIC, so it propagates
# into wma and then any app linking Aura3D). Without it here, SDL_atomic.c.o
# links without shared-memory support while ink/wma's objects require it
# wasm-ld then refuses the final link with "--shared-memory is disallowed by
# SDL_atomic.c.o". Every static lib in the wasm dependency chain must agree on
# this, since it's a whole-module setting, not a per-object one.
RUN wget "https://github.com/libsdl-org/SDL/releases/download/release-${SDL_VERSION}/SDL3-${SDL_VERSION}.tar.gz" -O /tmp/SDL3-${SDL_VERSION}.tar.gz && \
    tar -xzf /tmp/SDL3-${SDL_VERSION}.tar.gz -C /tmp/ && \
    rm -rf /tmp/SDL3-${SDL_VERSION}.tar.gz && \
    cmake -S /tmp/SDL3-${SDL_VERSION} -B /tmp/SDL3-${SDL_VERSION}/build_android \
        -DCMAKE_TOOLCHAIN_FILE=${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake \
        -DANDROID_ABI=arm64-v8a \
        -DANDROID_PLATFORM=android-29 \
        -DANDROID_STL=c++_shared \
        -DCMAKE_INSTALL_PREFIX=${LOCAL_PREFIX}/android \
        -DBUILD_SHARED_LIBS=OFF \
        -DSDL_OPENGL=OFF \
        -DSDL_OPENGLES=ON \
        -DSDL_VULKAN=ON && \
    cmake --build /tmp/SDL3-${SDL_VERSION}/build_android --target install --parallel $(( ($(nproc)+1)/2 )) && \
    cmake -S /tmp/SDL3-${SDL_VERSION} -B /tmp/SDL3-${SDL_VERSION}/build_wasm \
        -DCMAKE_TOOLCHAIN_FILE=${EMSDK}/upstream/emscripten/cmake/Modules/Platform/Emscripten.cmake \
        -DCMAKE_INSTALL_PREFIX=${LOCAL_PREFIX}/wasm \
        -DBUILD_SHARED_LIBS=OFF \
        -DSDL_OPENGL=OFF \
        -DSDL_OPENGLES=ON \
        -DSDL_VULKAN=OFF \
        -DCMAKE_C_FLAGS="-pthread" && \
    cmake --build /tmp/SDL3-${SDL_VERSION}/build_wasm --target install --parallel $(( ($(nproc)+1)/2 )) && \
    rm -rf /tmp/SDL3-${SDL_VERSION}

ENV SDL_TTF_VERSION="3.2.2"
RUN wget "https://github.com/libsdl-org/SDL_ttf/releases/download/release-${SDL_TTF_VERSION}/SDL3_ttf-${SDL_TTF_VERSION}.tar.gz" -O /tmp/SDL3_ttf-${SDL_TTF_VERSION}.tar.gz && \
    tar -xzf /tmp/SDL3_ttf-${SDL_TTF_VERSION}.tar.gz -C /tmp/ && \
    rm -rf /tmp/SDL3_ttf-${SDL_TTF_VERSION}.tar.gz && \
    cmake -S /tmp/SDL3_ttf-${SDL_TTF_VERSION} -B /tmp/SDL3_ttf-${SDL_TTF_VERSION}/build_static \
        -DCMAKE_INSTALL_PREFIX=${LOCAL_PREFIX} \
        -DBUILD_SHARED_LIBS=OFF && \
    cmake --build /tmp/SDL3_ttf-${SDL_TTF_VERSION}/build_static --target install --parallel $(( ($(nproc)+1)/2 )) && \
    rm -rf /tmp/SDL3_ttf-${SDL_TTF_VERSION}

RUN pip install --no-cache-dir glad && python3 -m glad --generator=c --api="gl=4.6" --out-path=/tmp/glad
RUN mkdir -p ${LOCAL_PREFIX}/lib ${LOCAL_PREFIX}/include ${LOCAL_PREFIX}/src/glad && \
    mv /tmp/glad/include/glad ${LOCAL_PREFIX}/include/ && mv /tmp/glad/src/* ${LOCAL_PREFIX}/src/glad/ && rm -rf /tmp/glad
RUN cd ${LOCAL_PREFIX}/src/glad && gcc -fPIC -I${LOCAL_PREFIX}/include -c glad.c -o glad.o && ar rcs ${LOCAL_PREFIX}/lib/libglad.a glad.o && \
    gcc -shared -fPIC glad.c -I${LOCAL_PREFIX}/include -o ${LOCAL_PREFIX}/lib/libglad.so.1.0.0 && \
    ln -sf libglad.so.1.0.0 ${LOCAL_PREFIX}/lib/libglad.so.1 && ln -sf libglad.so.1 ${LOCAL_PREFIX}/lib/libglad.so && rm glad.o

ENV DEARIMGUI_VERSION="1.92.6"
RUN wget "https://github.com/ocornut/imgui/archive/refs/tags/v${DEARIMGUI_VERSION}.tar.gz" -O /tmp/imgui-${DEARIMGUI_VERSION}.tar.gz && \
    tar -xzf /tmp/imgui-${DEARIMGUI_VERSION}.tar.gz -C /tmp/ && rm /tmp/imgui-${DEARIMGUI_VERSION}.tar.gz && \
    mkdir -p ${LOCAL_PREFIX}/include/imgui && mv /tmp/imgui-${DEARIMGUI_VERSION}/* ${LOCAL_PREFIX}/include/imgui/ && rm -rf /tmp/imgui-${DEARIMGUI_VERSION}

ENV GLM_VERSION="1.0.3"
RUN wget "https://github.com/g-truc/glm/archive/refs/tags/${GLM_VERSION}.tar.gz" -O /tmp/glm-${GLM_VERSION}.tar.gz && \
    tar -xzf /tmp/glm-${GLM_VERSION}.tar.gz -C /tmp/ && rm /tmp/glm-${GLM_VERSION}.tar.gz && \
    mv /tmp/glm-${GLM_VERSION}/glm ${LOCAL_PREFIX}/include && rm -rf /tmp/glm-${GLM_VERSION}

ENV NLOHMANN_JSON="3.12.0"
RUN wget "https://github.com/nlohmann/json/releases/download/v${NLOHMANN_JSON}/json.tar.xz" -O /tmp/json.tar.xz && \
    tar -xf /tmp/json.tar.xz -C /tmp/ && rm /tmp/json.tar.xz && \
    cmake -S /tmp/json -B /tmp/json/build \
        -DCMAKE_INSTALL_PREFIX=${LOCAL_PREFIX} \
        -DJSON_BuildTests=OFF && \
    cmake --build /tmp/json/build --target install && \
    rm -rf /tmp/json

ENV SQLITECPP_VERSION="3.3.3"
RUN wget -q "https://github.com/SRombauts/SQLiteCpp/archive/refs/tags/${SQLITECPP_VERSION}.tar.gz" -O /tmp/SQLiteCpp-${SQLITECPP_VERSION}.tar.gz && \
    tar -xzf /tmp/SQLiteCpp-${SQLITECPP_VERSION}.tar.gz -C /tmp/ && rm -rf /tmp/SQLiteCpp-${SQLITECPP_VERSION}.tar.gz && \
    cmake -S /tmp/SQLiteCpp-${SQLITECPP_VERSION} -B /tmp/SQLiteCpp-${SQLITECPP_VERSION}/build_static \
        -DCMAKE_INSTALL_PREFIX=${LOCAL_PREFIX} \
        -DBUILD_SHARED_LIBS=OFF \
        -DSQLITECPP_INTERNAL_SQLITE=ON && \
    cmake --build /tmp/SQLiteCpp-${SQLITECPP_VERSION}/build_static --target install --parallel $(( ($(nproc)+1)/2 )) && \
    rm -rf /tmp/SQLiteCpp-${SQLITECPP_VERSION}

ENV RAYLIB_VERSION="6.0"
RUN wget "https://github.com/raysan5/raylib/releases/download/${RAYLIB_VERSION}/raylib-${RAYLIB_VERSION}_linux_amd64.tar.gz" -O /tmp/raylib-${RAYLIB_VERSION}_linux_amd64.tar.gz && \
    tar -xzf /tmp/raylib-${RAYLIB_VERSION}_linux_amd64.tar.gz -C /tmp/ && rm -rf /tmp/raylib-${RAYLIB_VERSION}_linux_amd64.tar.gz && \
    cp -r /tmp/raylib-${RAYLIB_VERSION}_linux_amd64/lib/* ${LOCAL_PREFIX}/lib && cp -r /tmp/raylib-${RAYLIB_VERSION}_linux_amd64/include/* ${LOCAL_PREFIX}/include/ && rm -rf /tmp/raylib-${RAYLIB_VERSION}_linux_amd64

ENV JWTCPP_VERSION="0.7.2"
RUN wget "https://github.com/Thalhammer/jwt-cpp/releases/download/v${JWTCPP_VERSION}/jwt-cpp-v${JWTCPP_VERSION}.tar.gz" -O /tmp/jwt-cpp-v${JWTCPP_VERSION}.tar.gz && \
    mkdir -p /tmp/jwt-cpp-v${JWTCPP_VERSION} && tar -xvf /tmp/jwt-cpp-v${JWTCPP_VERSION}.tar.gz -C /tmp/jwt-cpp-v${JWTCPP_VERSION} --strip-components=1 && rm -rf /tmp/jwt-cpp-v${JWTCPP_VERSION}.tar.gz && \
    cmake -S /tmp/jwt-cpp-v${JWTCPP_VERSION} -B /tmp/jwt-cpp-v${JWTCPP_VERSION}/build \
        -DCMAKE_INSTALL_PREFIX=${LOCAL_PREFIX} && \
    cmake --build /tmp/jwt-cpp-v${JWTCPP_VERSION}/build --target install --parallel $(( ($(nproc)+1)/2 )) && \
    rm -rf /tmp/jwt-cpp-v${JWTCPP_VERSION}

ENV ORT_VERSION="1.26.0"
RUN wget "https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}/onnxruntime-linux-x64-gpu-${ORT_VERSION}.tgz" -O /tmp/ort.tgz && \
    tar -xzf /tmp/ort.tgz -C /tmp/ && cp -r /tmp/onnxruntime-linux-x64-gpu-${ORT_VERSION}/include/* ${LOCAL_PREFIX}/include/ && cp -r /tmp/onnxruntime-linux-x64-gpu-${ORT_VERSION}/lib/* ${LOCAL_PREFIX}/lib/ && rm -rf /tmp/ort.tgz /tmp/onnxruntime*

RUN wget "https://raw.githubusercontent.com/nothings/stb/master/stb_image.h" -O ${LOCAL_PREFIX}/include/stb_image.h && \
    wget "https://raw.githubusercontent.com/nothings/stb/master/stb_image_write.h" -O ${LOCAL_PREFIX}/include/stb_image_write.h && \
    wget "https://raw.githubusercontent.com/nothings/stb/master/stb_image_resize2.h" -O ${LOCAL_PREFIX}/include/stb_image_resize2.h && \
    wget "https://raw.githubusercontent.com/nothings/stb/master/stb_vorbis.c" -O ${LOCAL_PREFIX}/include/stb_vorbis.c && \
    wget "https://raw.githubusercontent.com/nothings/stb/master/stb_include.h" -O ${LOCAL_PREFIX}/include/stb_include.h && chmod 644 ${LOCAL_PREFIX}/include/stb_*

# Linux, Android and WASM, all into ${LOCAL_PREFIX}: headers install once and
# each library carries its ABI tag (libink_wasm32.a, ...). Release only --
# a debug build of a dependency has no place in a distributed image.
ENV LIBINK_VERSION="0.5.0"
RUN cd /tmp && wget "https://github.com/Arthu-RL/libink/archive/refs/tags/v${LIBINK_VERSION}.tar.gz" -O libink.tar.gz && \
    mkdir -p libink && tar -xzf libink.tar.gz -C libink --strip-components=1 && rm -rf libink.tar.gz && \
    cd libink && \
    cmake --preset linux-release && cmake --build --preset linux-release --target install && \
    cmake --preset android && cmake --build --preset android --target install && \
    cmake --preset wasm && cmake --build --preset wasm --target install && \
    rm -rf /tmp/libink

# Compile libwma for Linux, Android, and WASM
ENV LIBWMA_VERSION="0.4.0"
RUN cd /tmp && wget "https://github.com/Arthu-RL/libwma/archive/refs/tags/v${LIBWMA_VERSION}.tar.gz" -O libwma.tar.gz && \
    mkdir -p libwma && tar -xzf libwma.tar.gz -C libwma --strip-components=1 && rm -rf libwma.tar.gz && \
    cd libwma && \
    cmake --preset linux-release && cmake --build --preset linux-release --target install && \
    cmake --preset android && cmake --build --preset android --target install && \
    cmake --preset wasm && cmake --build --preset wasm --target install && \
    rm -rf /tmp/libwma

# Compile Aura3D for Linux, Android, and WASM
ENV AURA3D_VERSION="0.3.0"
RUN cd /tmp && wget "https://github.com/Aura3D-Team/Aura3D/archive/refs/tags/v${AURA3D_VERSION}.tar.gz" -O aura3d.tar.gz && \
    mkdir -p aura3d && tar -xzf aura3d.tar.gz -C aura3d --strip-components=1 && rm -rf aura3d.tar.gz && \
    cd aura3d && \
    cmake --preset linux-release && cmake --build --preset linux-release --target install && \
    cmake --preset android && cmake --build --preset android --target install && \
    cmake --preset wasm && cmake --build --preset wasm --target install && \
    rm -rf /tmp/aura3d

############################################
# Hyprland: the compositor AuraShell targets
############################################
# Runs nested inside the host's Wayland session (see scripts/hypr-nested), so a
# shell surface can be developed against a real compositor, real layer-shell,
# real IPC, real workspaces, without the container needing DRM master or a
# seat of its own. hyprland-protocols installs its XML under a pkg-config
# pkgdatadir, the same way wayland-protocols does, so a client can generate
# bindings for focus-grab and friends when it needs them.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    hyprland hyprland-protocols \
    # Xwayland so X11 clients (and libwma's X11 backend) run inside the session
    xwayland \
    # A terminal, or the nested session has no way to launch anything by hand
    foot \
    # Portals: screenshare, file pickers, and what a shell's own UI will need
    xdg-desktop-portal xdg-desktop-portal-hyprland \
    # Diagnosis: wayland-info answers "is this protocol even advertised"
    wayland-utils wl-clipboard \
    seatd dbus-x11 \
    fonts-dejavu-core && \
    apt-get clean && apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

COPY ./scripts/hypr-nested ./scripts/hypr-env /usr/local/bin/
COPY ./scripts/hyprland-nested.conf /usr/share/aurashell/hyprland-nested.conf
RUN chmod +x /usr/local/bin/hypr-nested /usr/local/bin/hypr-env

############################################
# Verification
############################################
# Hyprland aborts on a missing XDG_RUNTIME_DIR before it ever prints a version,
# and a build has no runtime dir -- /tmp is enough to get past the check.
RUN sdkmanager --version && adb version && gradle --version && \
    XDG_RUNTIME_DIR=/tmp Hyprland --version

############################################
# Monitor Execution Target
############################################
RUN mkdir -p /app
COPY ./monitor.py /app/monitor.py

SHELL ["/bin/bash", "-c"]
ENTRYPOINT ["python3", "-u", "/app/monitor.py"]