# syntax=docker/dockerfile:1.7-labs
##
## Android SDK + Gradle + pinned toolchain, optimized for caching
##

# --- Pin the base JDK -----------------------------------
ARG BASE_IMAGE=eclipse-temurin@sha256:00545bed5b57e0799fd32cdaea73ba171e826dce68c522ad0ef6888a7818a412
FROM ${BASE_IMAGE} AS base

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Fast apt with BuildKit caches
RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/var/lib/apt/lists \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      wget \
      unzip \
      git \
      locales \
      tzdata \
      libstdc++6 \
      zlib1g \
      openssh-client \
      bash-completion \
    && rm -rf /var/lib/apt/lists/*

# --- Stage: install pinned Android SDK components ------------------------------
FROM base AS android-sdk

# ---- Pinned versions (override with --build-arg in CI when you need to bump) --
# Android platform + build tools
ARG ANDROID_API_LEVEL=35         
ARG BUILD_TOOLS_VERSION=35.0.0
# NDK + CMake (set INSTALL_NDK/CMAKE=false if you don't need them)
ARG INSTALL_NDK=true
ARG NDK_VERSION=26.2.11394342
ARG INSTALL_CMAKE=true
ARG CMAKE_VERSION=3.22.1

# Commandline tools (Google zip) — numeric rev; deterministic
ARG CMDLINE_TOOLS_VERSION=11076708
# Optional integrity check (recommended in CI). Leave blank to skip.
ARG CMDLINE_TOOLS_SHA256=""

# Platform-tools (Google zip) — explicit version; deterministic
ARG PLATFORM_TOOLS_VERSION=35.0.0
ARG PLATFORM_TOOLS_SHA256=""

# SDK home
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV ANDROID_HOME=/opt/android-sdk

# We'll expose the selected Build-Tools on PATH in the final stage.
ENV PATH=${PATH}:${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin

# Create layout
RUN mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools" "${ANDROID_SDK_ROOT}/licenses"

# --- Install Android commandline-tools (pinned by rev + optional SHA) ----------
RUN --mount=type=cache,target=/root/.android \
    cd /tmp && \
    wget -q "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_VERSION}_latest.zip" -O clt.zip && \
    if [ -n "${CMDLINE_TOOLS_SHA256}" ]; then echo "${CMDLINE_TOOLS_SHA256}  clt.zip" | sha256sum -c -; fi && \
    unzip -q clt.zip -d "${ANDROID_SDK_ROOT}/cmdline-tools" && \
    mv "${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools" "${ANDROID_SDK_ROOT}/cmdline-tools/latest" && \
    rm -f clt.zip

# --- Install platform-tools via pinned zip (deterministic; not auto-updated) ---
RUN cd /tmp && \
    wget -q "https://dl.google.com/android/repository/platform-tools_r${PLATFORM_TOOLS_VERSION}-linux.zip" -O pt.zip && \
    if [ -n "${PLATFORM_TOOLS_SHA256}" ]; then echo "${PLATFORM_TOOLS_SHA256}  pt.zip" | sha256sum -c -; fi && \
    rm -rf "${ANDROID_SDK_ROOT}/platform-tools" && \
    unzip -q pt.zip -d "${ANDROID_SDK_ROOT}" && \
    rm -f pt.zip

# --- Accept licenses non-interactively (cached) --------------------------------
RUN set +o pipefail; --mount=type=cache,target=/root/.android \
    yes | sdkmanager --sdk_root="${ANDROID_SDK_ROOT}" --licenses >/dev/null; set -o pipefail 

# --- Install pinned SDK packages with cache for downloads ----------------------
RUN --mount=type=cache,target=/root/.android \
    PKGS=( \
      "build-tools;${BUILD_TOOLS_VERSION}" \
      "platforms;android-${ANDROID_API_LEVEL}" \
    ) && \
    if [ "${INSTALL_CMAKE}" = "true" ]; then PKGS+=("cmake;${CMAKE_VERSION}"); fi && \
    if [ "${INSTALL_NDK}" = "true" ];   then PKGS+=("ndk;${NDK_VERSION}");   fi && \
    sdkmanager --sdk_root="${ANDROID_SDK_ROOT}" --install "${PKGS[@]}"

# Small sanity check that also helps cache debugging if package resolution changes.
RUN set +o pipefail; yes | sdkmanager --sdk_root="${ANDROID_SDK_ROOT}" --list | sed -n '1,80p'; set -o pipefail

# --- Stage: install Gradle ------------------------------------------------------
FROM android-sdk AS gradle-install

# Pin Gradle version - this is just the gradle command itself
ARG GRADLE_VERSION=8.7
ARG GRADLE_SHA256=""

# Install Gradle distribution
RUN cd /tmp && \
    wget -q "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" -O gradle.zip && \
    if [ -n "${GRADLE_SHA256}" ]; then echo "${GRADLE_SHA256}  gradle.zip" | sha256sum -c -; fi && \
    unzip -q gradle.zip -d /opt && \
    ln -s "/opt/gradle-${GRADLE_VERSION}" /opt/gradle && \
    rm -f gradle.zip

ENV GRADLE_HOME=/opt/gradle
ENV PATH=${PATH}:${GRADLE_HOME}/bin

# --- Stage: Build project and cache dependencies ------------------------------
FROM gradle-install AS project-builder

# Create android user early so we can build as non-root
RUN groupadd -g 1000 android && \
    useradd -m -u 1000 -g android -s /bin/bash android && \
    mkdir -p /home/android/.android /home/android/.gradle && \
    chown -R android:android /home/android "${ANDROID_SDK_ROOT}"

# Set Gradle cache location
ENV GRADLE_USER_HOME=/home/android/.gradle

# Switch to android user early
USER android

# Accept licenses as android user (needed because we switched users)
RUN yes | sdkmanager --sdk_root="${ANDROID_SDK_ROOT}" --licenses || true

WORKDIR /workspace

# Copy only Gradle configuration files first - this allows Docker to cache the dependency download layer
COPY --chown=android:android ./project/build.gradle* ./project/settings.gradle* ./project/gradle.properties ./project/*.gradle* /workspace/
COPY --chown=android:android ./project/gradle /workspace/gradle/
COPY --chown=android:android ./project/gradlew* /workspace/

# Copy module build files (needed for Gradle 9+ project structure validation)
RUN --mount=type=bind,source=./project,target=/tmp/project \
    echo "==> Copying module build files..." && \
    find /tmp/project -maxdepth 2 -type f \( -name "build.gradle.kts" -o -name "build.gradle" \) | while read file; do \
        module_dir=$(dirname "$file" | sed "s|/tmp/project/||"); \
        if [ "$module_dir" != "." ] && [ "$module_dir" != "build-logic" ] && [ "$module_dir" != "buildSrc" ]; then \
            echo "  Copying build file for: $module_dir"; \
            mkdir -p "/workspace/$module_dir" && \
            cp "$file" "/workspace/$module_dir/" || true; \
        fi; \
    done && \
    echo "==> Module build files copied"

# Conditionally copy build-logic if it exists
RUN --mount=type=bind,source=./project,target=/tmp/project \
    if [ -d /tmp/project/build-logic ]; then \
        echo "==> Copying build-logic directory" && \
        mkdir -p /workspace/build-logic && \
        cp -r /tmp/project/build-logic/. /workspace/build-logic/; \
    else \
        echo "==> No build-logic directory, skipping"; \
    fi

# Conditionally copy buildSrc if it exists
RUN --mount=type=bind,source=./project,target=/tmp/project \
    if [ -d /tmp/project/buildSrc ]; then \
        echo "==> Copying buildSrc directory" && \
        mkdir -p /workspace/buildSrc && \
        cp -r /tmp/project/buildSrc/. /workspace/buildSrc/; \
    else \
        echo "==> No buildSrc directory, skipping"; \
    fi

# Check if gradlew exists, generate if needed, then download dependencies
RUN if [ -f "gradlew" ]; then \
        echo "==> Using existing Gradle wrapper" && \
        chmod +x gradlew; \
    else \
        echo "==> No gradlew found, generating wrapper..." && \
        gradle wrapper && \
        chmod +x gradlew; \
    fi && \
    echo "==> Downloading dependencies..." && \
    ./gradlew --version && \
    ./gradlew dependencies --no-daemon && \
    echo "==> ✅ Dependencies downloaded"

# Copy whole project (need to do here for multi-module projects)
COPY --chown=android:android ./project /workspace/

# Fix permissions (gradlew was overwritten)
RUN if [ -f gradlew ]; then chmod +x gradlew; fi

# === Copy tests before building, so Gradle knows about them ===
COPY --chown=android:android ./tests /workspace/tests/

# Recursively copy tests to match project structure
RUN echo "==> Copying tests into modules..." && \
    if [ -d /workspace/tests ]; then \
        cd /workspace/tests && \
        find . -type d -name "src" | while read src_dir; do \
            # Get module path (remove ./src from end)
            module_path=$(dirname "$src_dir" | sed 's|^\./||'); \
            echo "  Processing tests for: $module_path"; \
            \
            # Copy unit tests if they exist
            if [ -d "$src_dir/test" ]; then \
                target_dir="/workspace/$module_path/src/test"; \
                mkdir -p "$target_dir" && \
                cp -R "$src_dir/test/"* "$target_dir/" 2>/dev/null || true; \
                echo "    ✓ Copied unit tests"; \
            fi; \
            \
            # Copy instrumented tests if they exist
            if [ -d "$src_dir/androidTest" ]; then \
                target_dir="/workspace/$module_path/src/androidTest"; \
                mkdir -p "$target_dir" && \
                cp -R "$src_dir/androidTest/"* "$target_dir/" 2>/dev/null || true; \
                echo "    ✓ Copied instrumented tests"; \
            fi; \
        done; \
    fi && \
    echo "==> ✅ All tests copied"

# ===== 🚨 CUSTOMIZE FOR YOUR PROJECT 🚨 =====
# If your project has product flavors, set FLAVOR (e.g., Demo, Prod)
# If no flavors, leave empty
ARG FLAVOR=
# =====================================

# Now build the project with tests (downloads all dependencies including test deps)
RUN echo "==> Building Debug..." && \
    ./gradlew assemble${FLAVOR}Debug --no-daemon --stacktrace && \
    echo "==> Compiling tests..." && \
    ./gradlew compileDebugUnitTestKotlin compileDebugAndroidTestKotlin --no-daemon --stacktrace && \
    echo "==> Downloading test runtime dependencies..." && \
    ./gradlew test${FLAVOR}DebugUnitTestRuntimeClasspath --no-daemon || true && \
    echo "==> Running tests once to cache everything..." && \
    ./gradlew test${FLAVOR}DebugUnitTest --no-daemon --continue || true && \
    echo "==> Building test APKs..." && \
    ./gradlew assemble${FLAVOR}DebugAndroidTest --no-daemon --stacktrace && \
    echo "==> ✅ Build complete! All dependencies cached."
    
# --- Final image: starts from project-builder which has everything -------------
FROM project-builder AS final

# Copy run_tests.sh into the image so it can be executed from within the container
COPY --chown=android:android run_tests.sh /workspace/run_tests.sh
RUN chmod +x /workspace/run_tests.sh
RUN if [ -f /workspace/gradlew ]; then chmod +x /workspace/gradlew; fi

# Make sure we're the android user and in the right directory
USER android
WORKDIR /workspace