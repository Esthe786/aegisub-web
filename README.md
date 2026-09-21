# Aegisub on Synology (Docker + browser desktop)

Aegisub 3.4.2 is a native desktop app (wxWidgets/GTK), it has no web UI. This
image builds Aegisub from `Aegisub-3.4.2.tar.gz` and runs it inside a small
Debian desktop that's streamed to your browser via
[Selkies](https://github.com/selkies-project) (LinuxServer's
`baseimage-selkies`), with HTTP basic auth in front of it.

## Layout

```
Dockerfile                            multi-stage build (compile -> runtime desktop)
docker-compose.yml                    volumes point at /volume1/DockerV/aegisub
.env.example                          template for CUSTOM_USER/PASSWORD - copy to .env
.github/workflows/build-and-push.yml  CI: builds the image and pushes it to GHCR
root/custom-cont-init.d/10-lock-aegisub-auth.sh   one-time password lock
root/defaults/default.conf            nginx vhost, auth always on, reads /config/.htpasswd
root/defaults/autostart               openbox autostart -> launches aegisub, dark GTK theme
```

Host folders used (already created):
- `/volume1/DockerV/aegisub/appdata` -> `/config` (desktop settings, locked password, Aegisub prefs)
- `/volume1/DockerV/aegisub/media` -> `/config/Projects` (your actual subtitle/video files)

## Build & run (SSH into the NAS, Container Manager also works via "Project" import)

The image is now also built by CI (GitHub Actions, on every push to `main`)
and pushed to `ghcr.io/esthe786/aegisub-web` - a GitHub-hosted runner has
far more CPU than most NAS boxes, so **pulling the finished image is the
recommended path** instead of compiling Aegisub on the NAS itself:

```bash
cd /volume1/DockerV/aegisub   # wherever you copy this project's files to
cp .env.example .env
# edit .env: set PASSWORD (and CUSTOM_USER if you want something other than
# "admin") to a real value - this file is gitignored/dockerignored, so the
# real password never ends up in the compose file or the image
docker compose pull
docker compose up -d
```

`docker compose pull` needs `image:` in `docker-compose.yml` to resolve -
it already points at the GHCR image, so no extra config is needed. The repo
is public, and (confirmed after the first real CI run - GitHub's own docs
say new packages default to private with no way to flip that via push, but
in practice it came up public immediately, inheriting the repo's
visibility) so is the package - the NAS needs no registry login to pull.
If a future push ever produces a private package instead, the fix is the
package page on GitHub -> Settings -> Danger Zone -> Change visibility ->
Public, once.

If you'd rather build locally instead of pulling (e.g. testing an
uncommitted Dockerfile change), `build: .` is still in the compose file:
```bash
docker compose build
docker compose up -d
```
This still compiles Aegisub from source on whatever machine runs it, so
expect it to take a while on NAS-grade CPU. The build itself avoids doing
unnecessary work on top of that CPU ceiling:
- Boost is installed as just the 5 components Aegisub's `meson.build`
  actually asks for (`chrono`/`thread`/`locale`/`regex`/`system`), not the
  `libboost-all-dev` metapackage (every Boost component apt has) - cuts a
  meaningful chunk of apt install time in both stages.
- The compile step builds only the `aegisub` target, not meson's implicit
  "all" set - Aegisub's `meson.build` unconditionally wires up a ~30-file
  gtest suite (`subdir('tests')`) that this image never runs; skipping it
  skips compiling and linking it too.
- `ccache` is wired in via a BuildKit cache mount, so object files persist
  across builds even when unrelated Dockerfile edits (e.g. tweaking stage 2
  packages) invalidate the compile layer's Docker cache - only files that
  actually changed get recompiled next time, instead of a full rebuild.

None of this changes anything at runtime - same Aegisub binary either way.
Local `docker compose build --no-cache`/`--pull` defeats both Docker's and
ccache's caching, same as always.

## First login

Open `https://<nas-ip>:3012` (self-signed cert - browser will warn once, accept it).

- If you set `PASSWORD` in `.env` to a real value, log in with
  `CUSTOM_USER` / `PASSWORD`.
- If you left `PASSWORD` empty **or left it as the shipped placeholder**
  `changeme_on_first_run` (i.e. never created `.env`, or left it unedited),
  the init script refuses to lock that in and generates a random password
  instead, printed **once** in the container log
  (`docker compose logs aegisub | grep -A5 aegisub-auth`).

**The login is then locked**: it's written to `/config/.htpasswd` +
`/config/.aegisub_auth_initialized` on the appdata volume. Editing
`CUSTOM_USER`/`PASSWORD` in `.env` after that has no effect - this
is intentional (matches "setup once").

There is no web setup wizard - the browser's native username/password popup
*is* the login screen. It only ever asks for a credential that was already
decided at the container's first successful boot (from `PASSWORD`, or
auto-generated into the logs). If you're stuck at that popup with no known
password, the lock almost certainly already fired on an earlier boot -
during the troubleshooting/rebuild cycle, for instance - using whatever
`PASSWORD` was in `.env` (or a random one) at that time, and the
proof is sitting in logs you may not have kept.

**To reset it:**
```bash
docker compose down
rm /volume1/DockerV/aegisub/appdata/.htpasswd \
   /volume1/DockerV/aegisub/appdata/.aegisub_auth_initialized
# edit .env: set PASSWORD to a real value (not the placeholder)
docker compose up -d
```
This only touches files on the appdata volume - no rebuild needed, the image
is unchanged.

## Applying changes: restart vs. rebuild

The whole project is **not** mounted into the container - only two host
paths are:
- `/volume1/DockerV/aegisub/appdata` -> `/config` (persistent app state)
- `/volume1/DockerV/aegisub/media` -> `/config/Projects` (your files)

Everything else that defines the image (the `Dockerfile`, and - until now -
`root/custom-cont-init.d/10-lock-aegisub-auth.sh` and
`root/defaults/default.conf`) got baked in at `docker compose build` time via
`COPY`, so editing those files on disk did nothing until you rebuilt.

That's now split in two:
- **`10-lock-aegisub-auth.sh` and `default.conf` are live bind-mounted**
  (added to `docker-compose.yml`). Edit either file, then just
  `docker compose up -d` (recreates the container, no rebuild) - both are
  read fresh on every container start.
- **Everything else still needs a rebuild.** In particular the Aegisub
  binary itself is compiled C++ baked into the image at build time - there
  is no way to hot-reload that; any Aegisub source or `Dockerfile` change
  needs `docker compose build` again. Same for `root/defaults/autostart`,
  since it's only ever copied into `/config` once, on the very first boot.

One thing to check on the NAS before relying on the bind-mounted script:
`chmod +x root/custom-cont-init.d/10-lock-aegisub-auth.sh` - bind mounts
carry over the host file's permission bits exactly, and the base image
silently skips non-executable init scripts.

## Using it

Aegisub launches automatically, maximized, in a dark GTK theme
(`Arc-Dark`). Use File > Open to browse into `Projects/` - that's your
`/volume1/DockerV/aegisub/media` folder on the NAS.

## Dark mode - scope

This applies a dark GTK theme to the whole desktop session (menus, toolbars,
dialogs) via `GTK_THEME=Arc-Dark` (`root/defaults/autostart`, overridable by
setting `GTK_THEME` in the compose environment). An earlier version used
`Adwaita:dark`, but modern Adwaita only honors the `:dark` variant when a
GNOME session/gsettings daemon tells it to prefer dark - which this minimal
openbox container never does - so it silently rendered light. `Arc-Dark`
(from the `arc-theme` package) is a complete standalone dark theme, not a
variant, so `GTK_THEME` alone is enough to force it with no gsettings/dconf
involved.

Aegisub 3.4.2 itself has no dark-mode setting and doesn't repaint every
custom-drawn control, so a few elements (e.g. some icons) may still look
like their light-theme originals. The subtitle grid colors are untouched
from Aegisub's own defaults, which are configurable from inside the app
(View > Options).

## Streaming smoothness (video playback while editing)

The desktop is streamed with [Selkies](https://docs.linuxserver.io/selkies/)
(H.264 over WebSockets, decoded client-side via the browser's WebCodecs API -
supported in Safari 16.4+/iPadOS 16.4+, so a current iPad should be fine on
the decode side). No GPU is passed into the container, so **encoding runs on
the NAS's CPU** - on underpowered NAS hardware that's the most likely cause
of choppy video playback inside Aegisub, not the client.

`docker-compose.yml` sets a starting tune biased toward smooth motion over
max sharpness (`SELKIES_ENCODER`, `SELKIES_FRAMERATE`, `SELKIES_H264_CRF`,
`SELKIES_MANUAL_WIDTH`/`HEIGHT` - see the comment above them). These are
plain env vars, so changes just need `docker compose up -d` (no rebuild).
To tune further:
- Still choppy: lower `SELKIES_MANUAL_WIDTH`/`HEIGHT` further, or widen
  `SELKIES_H264_CRF` toward its higher (lower-quality/faster) end.
- Too soft/blurry: raise the resolution back up, or tighten `CRF` toward
  its lower (higher-quality) end - at the cost of more NAS CPU per frame.
- Watch `docker stats aegisub` while scrubbing video to see whether CPU is
  actually pegged during playback - confirms the encoder is the bottleneck
  before spending more time tuning it.
- Full list of `SELKIES_*` variables:
  <https://docs.linuxserver.io/selkies/user-guide/configuration/>

## Notes / troubleshooting

- Ports `3011`/`3012` on the host map to the container's `3000` (http) /
  `3001` (https). Change the left-hand side in `docker-compose.yml` if those
  clash with something else on the NAS.
- `PUID=1026` / `PGID=100` matches the `toushirou` account - keep these
  matched to whoever should own files written into `media`/`appdata`.
- If audio preview/waveform doesn't work, check `docker compose logs` for
  PulseAudio errors - the build enables Aegisub's PulseAudio output.
- If the web login always fails with a 500 error: nginx's worker runs as
  `www-data` and needs to at least traverse `/config` to read
  `.htpasswd`. The init script forces `/config` to `755` on every boot to
  cover this, but if `/volume1/DockerV/aegisub/appdata` was created with
  unusual ACLs on the NAS side, check `ls -ld` on it directly.
