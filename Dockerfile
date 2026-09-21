# syntax=docker/dockerfile:1
#
# Aegisub 3.4.2, built from source, served as a browser desktop (Selkies)
# with LinuxServer's baseimage-selkies (Debian Trixie, s6-overlay, nginx auth).
#
# Stage 1: compile Aegisub against the same Debian release used at runtime,
# so the shared libraries produced/linked in both stages are ABI compatible.

FROM debian:trixie-slim AS builder

# meson.build only asks Boost for chrono/thread/locale/regex/system (grep
# `boost_modules` in the top-level meson.build) - libboost-all-dev pulls in
# every Boost component (mpi, python, iostreams, ...) apt has, which is most
# of the builder stage's install time for no benefit. libgtest-dev/
# libgmock-dev stay: meson.build unconditionally does `subdir('tests')` at
# *configure* time, and without a system gtest/gmock it falls back to
# compiling its own bundled gtest subproject - slower than just having apt
# provide it, even though we skip actually building the test binary below.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
      build-essential \
      ccache \
      ninja-build \
      meson \
      pkg-config \
      intltool \
      git \
      ca-certificates \
      libx11-dev \
      libfreetype6-dev \
      libfontconfig1-dev \
      libass-dev \
      libasound2-dev \
      libpulse-dev \
      libffms2-dev \
      libboost-chrono-dev \
      libboost-thread-dev \
      libboost-locale-dev \
      libboost-regex-dev \
      libboost-system-dev \
      libhunspell-dev \
      libcurl4-openssl-dev \
      libuchardet-dev \
      libfftw3-dev \
      libicu-dev \
      zlib1g-dev \
      libwxgtk3.2-dev \
      libgtest-dev \
      libgmock-dev \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/usr/lib/ccache:${PATH}"

# Docker's ADD auto-extracts local tar archives
ADD Aegisub-3.4.2.tar.gz /usr/src/
WORKDIR /usr/src/Aegisub-3.4.2

# This is a plain GitHub tag archive, not the official `meson dist` release
# tarball - it has no .git directory and no pre-baked git_version.h, both of
# which tools/version.sh needs to stamp a version into the build. Supply one
# directly in the format that script itself would generate for tag v3.4.2.
RUN printf '#define BUILD_GIT_VERSION_NUMBER 6962\n#define BUILD_GIT_VERSION_STRING "3.4.2"\n#define TAGGED_RELEASE 1\n#define INSTALLER_VERSION "3.4.2"\n#define RESOURCE_BASE_VERSION 3, 4, 2\n' > git_version.h

# - `meson compile -C build ./aegisub:executable` (not a bare `meson
#   compile`, which builds meson's implicit "all" set) - meson.build
#   unconditionally runs `subdir('tests')`, which links a ~30-file gtest
#   suite against libaegisub. It's never run in this image, so building
#   only this target skips compiling and linking it entirely. The
#   `:executable` suffix disambiguates from libaegisub's own static
#   library target, which is also (confusingly) named `aegisub`. `meson
#   install` afterwards only needs targets that are actually marked
#   install: true, which the test binary isn't, so this doesn't skip
#   anything that ends up in the image.
# - BuildKit cache mount for ccache: object files survive even when an
#   unrelated Dockerfile edit invalidates this layer's Docker cache, so
#   only files that actually changed get recompiled on the next build.
RUN --mount=type=cache,target=/root/.cache/ccache \
    meson setup build \
      --prefix=/usr \
      --buildtype=release \
      -Ddefault_audio_output=PulseAudio \
      -Denable_update_checker=false && \
    meson compile -C build ./aegisub:executable && \
    DESTDIR=/build/install meson install -C build

# Stage 2: runtime desktop image
FROM ghcr.io/linuxserver/baseimage-selkies:debiantrixie

LABEL maintainer="local"

ENV TITLE="Aegisub" \
    GTK_THEME="Arc-Dark" \
    FILE_MANAGER_PATH="/config/Projects"

# Pull in the -dev metapackages rather than guessing exact versioned runtime
# .so package names (e.g. libwxgtk3.2-1) - apt resolves the correct runtime
# libraries as dependencies, at the cost of also carrying unused headers.
# Boost is scoped to the same 5 components actually used (see builder stage
# comment) instead of libboost-all-dev, same reasoning as there.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
      libx11-dev \
      libfreetype6-dev \
      libfontconfig1-dev \
      libass-dev \
      libasound2-dev \
      libpulse-dev \
      libffms2-dev \
      libboost-chrono-dev \
      libboost-thread-dev \
      libboost-locale-dev \
      libboost-regex-dev \
      libboost-system-dev \
      libhunspell-dev \
      libcurl4-openssl-dev \
      libuchardet-dev \
      libfftw3-dev \
      libicu-dev \
      zlib1g-dev \
      libwxgtk3.2-dev \
      hunspell-en-us \
      fonts-dejavu-core \
      arc-theme \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/install/usr/ /usr/
COPY root/ /

RUN chmod +x /custom-cont-init.d/*.sh

VOLUME /config
EXPOSE 3000 3001
