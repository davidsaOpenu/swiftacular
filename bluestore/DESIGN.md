# Design

## Overview

This directory contains a storage engine for Swift objects.

Swift's object server does not write object data itself. It delegates that
work to a class it is willing to have replaced, so a cluster can store
objects some way other than the standard one without altering Swift. That is
what this project does. The engine is C++; the code here wraps it, installs
it next to Swift, and arranges for Swift to use it.

Four concerns follow from that, one per section below.

- [Building](#building) — the engine and its Python layer have to be
  compiled and installed onto a machine running Swift.
- [Interface](#interface) — the replacement has to behave the way Swift
  expects a storage backend to behave.
- [Policy](#policy) — Swift has to be told the backend exists and directed to
  use it, which turns out to be the least obvious part.
- [Testing](#testing) — "behaves the way Swift expects" has to mean
  something checkable.

Code comments point back here by section, as `see DESIGN.md#policy`.

### Layout

```
bluestore/
  pyproject.toml      project description: metadata, dependencies, build
  CMakeLists.txt      native build, plus files that must reach site-packages
  bluestore/          the python code for the storage backend Swift will use
  test/               the differential test harness
```

---

## Building

Our code has to end up on a machine that is running Swift, in the same place
Swift's own code lives, and it has to get there without that machine needing
a C++ toolchain. Python's packaging system is how we do both.

What we produce is a *wheel*: a single archive containing our modules and our
compiled engine, already built. Installing a wheel copies its contents into
the interpreter's library directory, alongside Swift's own modules, which is
what puts our code within Swift's reach. Because the compiling happened when
the wheel was built, installing it needs nothing but pip.

The catch is that a wheel containing compiled code only works on the
interpreter version and platform it was built for. The build has to happen
somewhere that matches the machine that will install it.

### Two ways to build

**uv** is for working on the project and needs nothing installed but uv. It
fetches a matching Python interpreter, the build tools, and every dependency
into a directory inside the project. Nothing it does touches the rest of the
machine.

**pip** is for producing the wheel that gets deployed. There you supply the
interpreter and the toolchain, and Swift is already present system-wide, so
the build is told not to go looking for its own copy.

Both run the same build and produce the same wheel.

#### Set up an environment

```sh
uv sync
```

```sh
python -m venv .venv && . .venv/bin/activate
pip install -e '.[test]'
```

#### Run the tests

```sh
uv run pytest
```

```sh
. .venv/bin/activate
pytest
```

#### Build a wheel

```sh
uv build --wheel
```

```sh
pip wheel -w dist --no-deps .
```

#### Install it

```sh
pip install --force-reinstall --no-deps dist/bluestore-*.whl
```

`--no-deps` appears in both pip commands. We declare Swift as a dependency so
that a development environment gets a version we are compatible with, but on
a machine running Swift that requirement is already met by the system
installation, and fetching a second copy from PyPI would be wrong.

`--force-reinstall` is needed because our version number does not change
between iterations, so pip would otherwise decide the installed copy is
already current and do nothing.

#### Check that it worked

```sh
python -c "import bluestore.hook"
```

Silence means installed. If Swift then still refuses to start on an unknown
policy type, the problem is not the install; see [Policy](#policy).

### The pieces

**`pyproject.toml`** describes the project. It states what we depend on and
which interpreter we support, both pinned, because the engine is compiled
against a particular interpreter and the Python layer uses Swift internals
that are not stable between Swift versions. It also declares an *entry
point*: a name recorded in our installed metadata that points at a class in
our code. Other installed software can look that name up and get the class,
without knowing where we are installed or importing us by path. Swift uses
this to find our backend, described in [Interface](#interface).

**The build backend** is the program that turns this directory into a wheel.
The usual one only knows how to package Python files. We use
scikit-build-core instead, which does the same job but runs CMake first and
packs its output into the same wheel. The result is one artifact holding both
halves, installed in one step.

**`CMakeLists.txt`** owns the native build. It also installs files that have
to land in the interpreter's library directory but are not Python modules;
`hook_apply.pth` is one, and [Policy](#policy) explains what it is for.
Anything CMake installs into `SKBUILD_PLATLIB_DIR` ends up in the wheel
alongside the Python modules.

### Adding C++

Add sources under the package directory, declare them in `CMakeLists.txt` as
an extension module, and install that target into `SKBUILD_PLATLIB_DIR`. Once
installed it is imported like any other module in the package.

After adding a new source location, check `cache-keys` in `pyproject.toml`.
It lists the files whose contents decide whether a cached build can be
reused. A file not covered there can be edited without triggering a rebuild,
which produces a frustrating loop where changes appear to do nothing. To
force a clean build, delete `dist/` and the build directory, or pass
`--reinstall` to `uv sync`.

---

## Interface

Swift's object server carries out a request through a DiskFileManager and the
DiskFiles it produces. That interface, the standard implementation of it, and
what is gained and lost by replacing it are the subject of the object-server
presentation in this repository. Read it first. This section only says what we
do about it.

`manager.py` implements that interface on top of our engine. Two things are
worth adding to what the presentation covers.

**Swift finds the manager by name.** A storage policy names its backend as
`egg:bluestore#manager`, which Swift reads as: look in the installed
distribution `bluestore` for an entry point called `manager`. That entry point
is declared in `pyproject.toml`, and the name it is declared under has to match
the one `policy.py` asks for. If the two drift apart, Swift fails at startup
with a resolution error.

**Matching the methods is the easy half.** The rest of Swift assumes the
behaviour the presentation describes, and an implementation that satisfies the
signatures without satisfying the behaviour will survive casual use and then
fail in ways that are hard to trace back. [Testing](#testing) is how we hold
ourselves to it.

---

## Policy

A *storage policy* in Swift is a named way of storing objects. Every
container is created under one, every request carries the resulting policy
index, and the object server picks the backend for that index when it handles
the request. Policies exist so a cluster can offer, say, replicated and
erasure-coded storage side by side. We use the same mechanism to offer ours.

### What this buys us

**Both backends run in one process.** Selection happens per request, not per
process or per build. The same running object server can serve one request
with the reference backend and the next with ours. This is what makes the
differential testing in [Testing](#testing) possible: a reference
implementation is always available to compare against, under identical
conditions, in the same interpreter.

**The choice is per container.** A cluster can carry both at once, and moving
data between them is a copy through the normal API rather than a migration.
A deployment does not have to commit up front.

**Swift stays stock.** The proxy, the ring, the object server and the API are
the ones Swift ships. We inherit their behaviour instead of reimplementing
it, and we carry no patches forward across Swift releases.

### What it costs

- The policy needs its own ring, since it is a distinct place data can live.
- The policy has to declare its quorum, the number of responses that make a
  write successful. Ours declares one, which is an accurate statement about
  durability and should be read as one.
- A policy index is permanent once objects exist under it. Indices cannot be
  renumbered or reused.
- Swift refuses to start if its configuration names a policy type it does not
  recognise. This one is awkward enough to need the rest of this section.

### What gets registered

Two registrations make up a policy type. The first is the type itself, which
is what lets the configuration name it and what attaches our manager to it.
The second is a proxy-side controller: the proxy keeps a class per policy type
describing how a request is spread across the cluster, and refuses to route
for a type that has none. We register Swift's stock replicated controller
under our type and change nothing about it.

### The ordering problem

Registering a policy type means calling into `swift.common.storage_policy`,
which means importing it. But that module reads the Swift configuration while
it is being imported, and raises if it finds a policy type nobody has
registered.

So our registration has to run before that module finishes importing, and it
cannot run before it starts importing. No ordinary place in our code
satisfies both: by the time anything of ours would normally run, Swift has
already failed.

### The startup hook

Python offers one hook that runs earlier than application code. A file with a
`.pth` extension in the interpreter's library directory is read at startup,
and a line in it beginning with `import` is executed then and there, before
the interpreter runs whatever it was actually asked to run. That is early
enough.

`hook_apply.pth` holds one such line, importing `bluestore.hook`. The hook
installs a finder at the front of Python's import machinery, watching for two
module names. When either is imported, it lets the module load as usual and
then runs a small piece of our code.

For the proxy controller module that is the whole story: load, then register.

For `swift.common.storage_policy` the module's own execution is *expected* to
fail, since that is where the unknown policy type is rejected. The hook
catches the failure, confirms the module got as far as reading policies, and
if so substitutes an empty policy list rather than letting the error
propagate. Then it imports our policy module, which registers the type and
asks Swift to read the configuration again. The second read succeeds and
Swift carries on as though nothing had happened.

Confirming how far the module got is what keeps this from swallowing
unrelated failures. Anything raised before policy reading begins is re-raised
untouched.

### Consequences worth knowing

The hook runs in every Python process on a machine where the package is
installed, not only Swift's. That is a property of `.pth` files rather than a
choice the hook makes.

The two failure modes look nothing alike. If the hook never runs, Swift
refuses to start and names the policy type it does not recognise. If the hook
runs but registration fails, Swift starts with an empty policy list and the
symptom surfaces later as something apparently unrelated.

---

## Testing

A backend is correct when Swift cannot tell it apart from the reference
implementation. The tests take that literally.

Every request in the harness is sent twice through the same unmodified object
server, once directed at the reference backend and once at ours, with
identical timestamps. The two responses are compared in full: status, body,
and headers. Anything that differs fails the test.

Comparing everything is the point. A hand-written assertion catches only what
someone thought to check, whereas here any divergence fails by default,
including in error responses and in headers nobody was thinking about.

This works because both backends are selectable per request inside one
process. See [Policy](#policy) for why that is true.

### The harness does not import our code

`conftest.py` contains no import of this package. Registration has to happen
the way it happens on a real machine, and if it does not happen the tests
must fail as loudly as a real deployment would. An import in the harness
would conceal exactly the failure that matters most.

### The clock

Swift orders operations by timestamp, so the two backends stay comparable
only if they see the same ones. The harness generates timestamps from an
integer tick counter rather than the wall clock.

It advances two ways. A comparison call moves to the next whole second. A
single-backend call moves by one tick. Since a tick is far smaller than a
second, single-backend calls can be inserted anywhere without shifting the
timestamps the comparison calls see. The two backends stay on the same grid
however the two kinds of call are interleaved, and the arithmetic is integer
throughout, so nothing drifts.

### Declaring divergence

`call.diff()` sends a request to our backend only. It is for behaviour that
is intentionally different, and each use is a claim that a difference is
correct rather than a bug. The set of uses is the complete record of where
the two backends part ways.

`IGNORED_HEADERS` does the same at a finer grain, for headers that cannot
match by construction. The bar for adding one is that no implementation could
make it match, not that ours currently does not.

### Tests are sequences

Fixtures are class-scoped and methods run in the order they are written. A
test class is one scenario carried out step by step against shared server
state, which is how a backend's real failures tend to show up: not in a
single operation, but in what a series of them leaves behind. The
`incremental` marker skips the remainder of a class once a step has failed,
since everything after it would be testing from a state that was never
reached.
