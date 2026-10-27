# Build containers

Each image here is a toolchain — everything one kind of presentation needs to
turn its sources into a finished artifact. `d2marp` is the d2 + Marp toolchain
used by the current deck; a presentation that needed reveal.js or Typst would
get its own image alongside it.

A presentation selects one by symlinking:

```sh
ln -s ../containers/d2marp my-presentation/container
```

Images are built once per unique target and reused, so several presentations
sharing a toolchain cost one build. That only holds if they symlink to the same
directory — copying the definition gets you a second image with a different tag
and a second build.

## Requirements

An image is not a general-purpose base image. It is run in one specific way and
has to hold up its end of that.

### Run `/src/build.sh`

The presentation directory is bind-mounted at `/src` and its `build.sh` is
executed with no arguments. The image needs a `bash` capable of running it, plus
every tool that script invokes. Nothing is installed at run time — the container
runs with `--network none` and `--read-only`; only `/src`, `/tmp` and
`/home/user` (both tmpfs) are writable.

```dockerfile
WORKDIR /src
```

### Create a user at `BUILD_UID`

The container is started as `BUILD_UID:<host gid>`. The UID must exist as a real
user inside the image with a home directory, or tools that want somewhere to
write caches and config will fail in confusing ways.

```dockerfile
ARG BUILD_UID=4099
RUN useradd -u "$BUILD_UID" -m -s /bin/bash user
USER user
```

`USER` matters as well as the `--user` flag: it fixes `$HOME` and makes the
image behave the same when someone runs it by hand for debugging.

Declare `ARG BUILD_UID` just above this, not at the top: an `ARG` is visible to
every later `RUN`, so changing the UID only invalidates the tail of the build
cache if nothing before it can see it.

### Ship the entrypoint

Copy `entrypoint.sh` from an existing image unless you have a reason not to. It
does three things, all of which are load-bearing:

- **`umask 002`** so files created during the build stay group-writable.
- **`reclaim()`**, run on entry and again from an `EXIT` trap, which regroups and
  re-permissions `/src` so the host user can read and delete the output. Without
  it the build leaves files behind that the host cannot touch.
- **`command "$@" & wait "$!"`**, which runs the build in the background and
  waits on it. A foreground child would block bash from servicing signals, and
  the `EXIT` trap — and so `reclaim` — would not run until the build finished on
  its own. `command` is used rather than a bare call so a task name cannot
  shadow a binary.

```dockerfile
COPY entrypoint.sh /usr/bin/entrypoint
ENTRYPOINT ["/usr/bin/entrypoint"]
```

### Pin your tools

Every tool version goes in an `ARG` at the top of the Dockerfile and is
referenced from the install command. The point is that a rebuild produces the
same artifact, and that the version a deck renders correctly against is written
down somewhere a human will find it.

```dockerfile
ARG MARP_VERSION="4.5.0"
RUN npm install -g "@marp-team/marp-cli@$MARP_VERSION"
```

The base image tag is the weak spot in this — `debian:trixie-slim` moves, as do
the `apt-get` versions underneath it. Pinning by digest closes most of that gap
if a given deck ever needs to be rebuilt byte-for-byte years later.

### Keep it small

Clean up in the same layer that installs, or the cleanup does nothing:

```dockerfile
RUN apt-get update && apt-get -y install --no-install-recommends ... \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN npm install -g ... && npm cache clean --force
```

Build-only toolchains (Go for d2, say) belong in a separate stage, with just
the binary copied into the final image.

## Naming

The image tag is derived from the directory name — lowercased, with anything
outside `[a-z0-9_.-]` replaced — and prefixed with `swiftacular-presentations-`.
`containers/d2marp` becomes `swiftacular-presentations-d2marp`. Keep directory
names short and lowercase and the tag will look like you chose it.

## Gotchas

- **`BUILD_UID` has to agree with `build-all.sh`.** The `ARG` default is there
  for anyone running `docker build` by hand; the orchestrator is the source of
  truth.
- **Test by hand before wiring it up:**

  ```sh
  docker build -t test-image containers/<name>
  docker run --rm -v "$PWD/my-presentation:/src" \
      --network none --read-only \
      --tmpfs /tmp:mode=1777 --tmpfs /home/user:mode=1777 \
      --user "4099:$(id -g)" test-image /src/build.sh
  ```

  Then check that the files it produced are still yours.
