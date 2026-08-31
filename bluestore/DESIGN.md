<<<<<<< PATCH SET (17cdbc4e501dbc913dd911a23f86b68c2c266964 Build and link ceph)
=======
# Overview

This directory contains a storage engine for Swift objects.

Swift's object server does not write object data itself. It delegates that
work to a class it is willing to have replaced, so a cluster can store
objects some way other than the standard one without altering Swift. That is
what this project does. The engine is C++; the code here wraps it, installs
it next to Swift, and arranges for Swift to use it.

Six concerns follow from that, one per section below.

- [Building](#building) — the engine and its Python layer have to be
  compiled and installed onto a machine running Swift.
- [Binding](#binding) — Python and native code cannot call each other
  directly, so something has to carry calls across.
- [Concurrency](#concurrency) — one object server handles many requests at
  once, and a native call that does not cooperate stops all of them.
- [Interface](#interface) — the replacement has to behave the way Swift
  expects a storage backend to behave.
- [Policy](#policy) — Swift has to be told the backend exists and directed to
  use it, which turns out to be the least obvious part.
- [Testing](#testing) — "behaves the way Swift expects" has to mean
  something checkable.

Code comments point back here by section, as `see DESIGN.md#policy`. Those
references make the headings an interface: add sections rather than renaming
or reordering them.

## Layout

```
bluestore/
  pyproject.toml      project description: metadata, dependencies, build
  CMakeLists.txt      the native build: what is compiled, and where it lands
  bluestore/          the python code for the storage backend Swift will use
  src/                the native engine, the binding to it, and a command line tool
  test/               the tests and the harness they run in
```

---

# Building

Our code has to end up on a machine that is running Swift, in the same place
Swift's own code lives, and it has to get there without that machine needing
a C++ toolchain. Python's packaging system is how we do both.

What we produce is a *wheel*: a single archive containing our modules, our
compiled engine, and a command line program, all built already. Installing a
wheel copies its contents into the interpreter's library directory, alongside
Swift's own modules, which is what puts our code within Swift's reach.
Because the compiling happened when the wheel was built, installing it needs
nothing but pip.

The catch is that a wheel containing compiled code only works on the
interpreter version and platform it was built for. The build has to happen
somewhere that matches the machine that will install it.

## Two ways to build

**uv** is for working on the project and needs nothing installed but uv. It
fetches a matching Python interpreter, the build tools, and every dependency
into a directory inside the project. Nothing it does touches the rest of the
machine.

**pip** is for producing the wheel that gets deployed. There you supply the
interpreter and the toolchain, and Swift is already present system-wide, so
the build is told not to go looking for its own copy.

Both run the same build and produce the same wheel.

### Set up an environment

```sh
uv sync
```

```sh
python -m venv .venv && . .venv/bin/activate
pip install -e '.[test]'
```

### Run the tests

```sh
uv run pytest              # default tests
uv run pytest -m <kind>    # one kind of test
uv run pytest -m ""        # every kind tests
```

```sh
. .venv/bin/activate
pytest                     # default tests
pytest -m <kind>           # one kind of test
pytest -m ""               # every kind tests
```

### Build a wheel

```sh
uv build --wheel
```

```sh
pip wheel -w dist --no-deps .
```

### Install it

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

### Check that it worked

An install puts three kinds of thing in place, and they can fail separately.
Check each:

```sh
python -c "import bluestore.hook"
python -c "import bluestore._raw"
command -v bluestore-cli
```

The first is our Python code, the second the compiled engine behind it (see
[Binding](#binding)), the third the command line program. Silence from the
first two and a path from the third means installed.

Silence means installed. If Swift then still refuses to start on an unknown
policy type, the problem is not the install; see [Policy](#policy).

## The pieces

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

**`CMakeLists.txt`** owns the native build: which sources are compiled, what
they produce, and where each product has to land. It produces two kinds of
thing. One is a module Python can import, which has to end up inside our
package to be importable as part of it; [Binding](#binding) explains what it
is for. The other is an ordinary program, which has to end up wherever
installed programs go, so that a wheel install leaves it on `PATH`.

## Adding C++

Add sources under `src/`, declare them in `CMakeLists.txt` as part of an
existing target or a new one, and give anything that has to be importable or
runnable afterwards an install destination. Both kinds of product are already
built and installed there, so the existing targets are the example to copy.

Before adding a function that Python will call, read
[Binding](#binding) and [Concurrency](#concurrency). Both place requirements
on how such a function is written, and neither failure is one the compiler
will catch.

After adding a new source location, check `cache-keys` in `pyproject.toml`.
It lists the files whose contents decide whether a cached build can be
reused. A file not covered there can be edited without triggering a rebuild,
which produces a frustrating loop where changes appear to do nothing. The
list matches paths, so a source file in a directory no pattern reaches is
invisible to it even though the build compiles it quite happily. To force a
clean build, delete `dist/` and the build directory, or pass `--reinstall` to
`uv sync`.

---

# Binding

The engine is C++ and the code Swift calls is Python. Neither can call the
other directly. They do not agree on how a value is represented, how errors
are reported, or who is responsible for a piece of memory, so something has
to sit between them and translate.

That something is `_raw`, a module written in C++ against the interpreter's
own extension interface and compiled into our wheel. Once installed it is
imported like any other module in the package. The leading underscore is the
usual mark of something private: it exists for our Python layer to call and
is not part of what this project offers anyone else. Nothing outside this
package should import it.

We write it with the help of a binding library, nanobind, which supplies the
conversions and the boilerplate rather than a new way of working. What
follows is true of the boundary itself and does not depend on that choice.

## The binding does not decide anything

A function in `_raw` should do three things: convert its arguments into what
the engine wants, call the engine, and convert the result back. Nothing else.
No validation beyond what conversion requires, no retries, no special cases,
no deciding what to do when the engine says no.

This is worth holding to because a decision made in the binding is made in
the worst available place. It cannot be exercised by the engine's own tests,
which do not go through Python, nor by tests of the Python layer, which stop
at the boundary. It is invisible from both sides and belongs to neither. Put
the decision in the engine if it is about storage, and in the Python layer if
it is about what Swift expects, and the binding stays a thing you can read in
one sitting.

A binding function has one more obligation, which is not about translation at
all and is not optional: see [Concurrency](#concurrency).

## Crossing is not free

Every call across the boundary costs something even when it does nothing. The
interpreter has to be entered and left, arguments have to be converted, and
data that both sides need may have to be copied so that each has it in a form
it understands.

The consequence is about shape rather than speed. A boundary crossed once
with a large piece of work behind it costs almost nothing; the same work
split across many small calls pays that cost every time and can be dominated
by it. When a call turns out to be too expensive, the usual remedy is to move
the loop to the other side of the boundary rather than to make the crossing
cheaper.

## The command line tool

The engine can also be driven directly, by a program built from the same
sources that does not involve Python at all:

```sh
bluestore-cli --help
```

It is installed by the same wheel and is on `PATH` once that wheel is
installed. It exists so the engine can be exercised on its own, with nothing
else in the picture: when something misbehaves, it answers whether the engine
or the layers above it are at fault. [Testing](#testing) also uses it as the
thing to measure the binding against, since it reaches the same engine by an
entirely different route.

---

# Concurrency

A Swift object server handles many requests at once, and it does so in a
single thread. It can only do that because the code it runs cooperates:
whenever a request has to wait for something — a socket, a disk, another
service — the code doing the waiting hands the thread back, and the server
spends the wait serving somebody else. This is not a scheduler taking the
thread away. Nothing is taken. The waiting code gives it up, and if it does
not, nobody else runs.

Native code does not cooperate. It has no way to know it is expected to, and
no way to hand anything back if it did. From the server's point of view a
native call is not waiting for anything, it is simply not finished, and the
thread stays with it until it returns.

Python adds a second reason for the same outcome. The interpreter allows only
one thread to run Python code at a time, and holds a lock to enforce it. That
lock is held on behalf of whoever entered our binding, and it stays held for
the whole call unless the native side gives it up. So even a native call
moved onto a thread of its own still blocks every other thread from running
Python.

Either of those alone is enough to stop the server. Together they mean that a
native call written the obvious way does not slow down the request that made
it. It stops all of them, for as long as the call runs.

## The rule

Every call into the engine has to satisfy both halves of that:

- **It runs on a real operating system thread**, not on the server's one
  thread. The caller hands the work to a pool of such threads and waits for
  it the cooperative way, so the server is free to serve other requests
  meanwhile.
- **The native side gives up the interpreter lock** for as long as it is
  busy, and takes it back before it touches anything belonging to Python
  again.

Neither half is sufficient. A call on its own thread that keeps the lock
leaves every other thread unable to run Python. A call that releases the lock
but stays on the server's thread has still taken the thread hostage,
and released the lock to an interpreter with nobody left to use it.

Both halves are already in place at every existing call. The Python side of
one lives in `manager.py`, the native side in the binding it calls; between
them they are the example to follow, and following it is not optional.

## How this fails

Breaking the rule does not look like breakage.

The call returns the right answer and the request it belongs to succeeds. A
test that issues one request at a time passes, because a server with nothing
else to serve is not kept from serving it. The engine's own measurements are
unaffected, since the engine is doing what it was asked at the speed it
always did.

The cost is only visible with several requests in flight, and it does not
announce itself as a wrong result. Throughput stops improving with load;
latency rises across every request in the process, including ones that never
went near the engine. Seen from there the cause is a long way off, and the
network, the disk, or the engine are all likelier suspects than a missing
line in a function that demonstrably works.

So the compiler will not catch this, and neither will a test unless it was
written to. Catching it takes concurrent load and a measurement, which is a
deliberate thing to build rather than something a correctness test does
incidentally.

## Adding a function to the engine

Any new function that Python will call needs both halves before it is used
in anger, not afterwards. Write the native side to release the lock around
the work, and call it through the thread pool. Add nothing else — see
[Binding](#binding) for what the binding may and may not contain.

There is one exception, and it is narrow: a call that does no waiting and no
appreciable work — one that only reads a value the engine already has — can
cost more to hand to another thread than to do outright. If a call is a
candidate for that, it should be obvious from the function itself. Anything
that touches storage is not.

---

# Interface

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

**The manager is where the two halves meet.** Swift's expectations arrive at
our manager and the engine is reached from there, so this is the file
answering to both. What Swift requires of it is above; what the boundary
requires is set out in [Binding](#binding) and [Concurrency](#concurrency),
and applies to every call it makes across.

---

# Policy

A *storage policy* in Swift is a named way of storing objects. Every
container is created under one, every request carries the resulting policy
index, and the object server picks the backend for that index when it handles
the request. Policies exist so a cluster can offer, say, replicated and
erasure-coded storage side by side. We use the same mechanism to offer ours.

## What this buys us

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

## What it costs

- The policy needs its own ring, since it is a distinct place data can live.
- The policy has to declare its quorum, the number of responses that make a
  write successful. Ours declares one, which is an accurate statement about
  durability and should be read as one.
- A policy index is permanent once objects exist under it. Indices cannot be
  renumbered or reused.
- Swift refuses to start if its configuration names a policy type it does not
  recognise. This one is awkward enough to need the rest of this section.

## What gets registered

Two registrations make up a policy type. The first is the type itself, which
is what lets the configuration name it and what attaches our manager to it.
The second is a proxy-side controller: the proxy keeps a class per policy type
describing how a request is spread across the cluster, and refuses to route
for a type that has none. We register Swift's stock replicated controller
under our type and change nothing about it.

## The ordering problem

Registering a policy type means calling into `swift.common.storage_policy`,
which means importing it. But that module reads the Swift configuration while
it is being imported, and raises if it finds a policy type nobody has
registered.

So our registration has to run before that module finishes importing, and it
cannot run before it starts importing. No ordinary place in our code
satisfies both: by the time anything of ours would normally run, Swift has
already failed.

## The startup hook

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

## Consequences worth knowing

The hook runs in every Python process on a machine where the package is
installed, not only Swift's. That is a property of `.pth` files rather than a
choice the hook makes.

The two failure modes look nothing alike. If the hook never runs, Swift
refuses to start and names the policy type it does not recognise. If the hook
runs but registration fails, Swift starts with an empty policy list and the
symptom surfaces later as something apparently unrelated.

---

# Testing

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

## The harness does not import our code

`conftest.py` contains no import of this package. Registration has to happen
the way it happens on a real machine, and if it does not happen the tests
must fail as loudly as a real deployment would. An import in the harness
would conceal exactly the failure that matters most.

## The clock

Swift orders operations by timestamp, so the two backends stay comparable
only if they see the same ones. The harness generates timestamps from an
integer tick counter rather than the wall clock.

It advances two ways. A comparison call moves to the next whole second. A
single-backend call moves by one tick. Since a tick is far smaller than a
second, single-backend calls can be inserted anywhere without shifting the
timestamps the comparison calls see. The two backends stay on the same grid
however the two kinds of call are interleaved, and the arithmetic is integer
throughout, so nothing drifts.

## Declaring divergence

`call.diff()` sends a request to our backend only. It is for behaviour that
is intentionally different, and each use is a claim that a difference is
correct rather than a bug. The set of uses is the complete record of where
the two backends part ways.

`IGNORED_HEADERS` does the same at a finer grain, for headers that cannot
match by construction. The bar for adding one is that no implementation could
make it match, not that ours currently does not.

## Tests are sequences

Fixtures are class-scoped and methods run in the order they are written. A
test class is one scenario carried out step by step against shared server
state, which is how a backend's real failures tend to show up: not in a
single operation, but in what a series of them leaves behind. The
`incremental` marker skips the remainder of a class once a step has failed,
since everything after it would be testing from a state that was never
reached.

---

# Testing

Tests come in kinds. Each kind asks one sort of question, has its own
machinery, and is written under its own rules. A section below describes
each; more can be added as more questions turn out to be worth asking.

## Kinds are marks

Every test carries a mark naming its kind. The mark is not decoration: it is
what selects the test, so it decides whether the test runs at all.

The default run selects the kinds cheap enough to sit in a loop with.
Anything else is asked for by name

A mark given on the command line replaces the default rather than adding to
it, which is what makes the last two work. The consequence is worth knowing:
a test carrying no mark is selected by nothing and quietly never runs.

Adding a kind means registering its mark in `pyproject.toml`, deciding
whether it belongs in the default run, and describing it here. A test that
fits no existing kind wants a new one rather than no mark.

Not every mark is a kind. A mark can also say something about *how* a test is
run, and a test carries those in addition to its kind rather than instead of
one. `incremental`, below, is the example.

## Differential — `diff`

A backend is correct when Swift cannot tell it apart from the reference
implementation. These tests take that literally.

Every request is sent twice through the same unmodified object server, once
directed at the reference backend and once at ours, with identical
timestamps. The two responses are compared in full: status, body, and
headers. Anything that differs fails the test.

Comparing everything is the point. A hand-written assertion catches only what
someone thought to check, whereas here any divergence fails by default,
including in error responses and in headers nobody was thinking about.

This works because both backends are selectable per request inside one
process. See [Policy](#policy) for why that is true.

These run by default. They are the cheap ones.

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

## Fork — `fork`

Crossing the binding is supposed to be cheap. Nothing in the code says so and
nothing breaks when it stops being true: a change to how arguments are
converted, or to how much work one call carries, can make crossing expensive
while every answer stays correct. These tests exist to notice that happening.

A duration on its own says nothing, so the test needs something to measure
against. That is the command line tool, which reaches the same engine by
starting a separate program. It is useful here precisely because it is slow
and always will be — its cost is dominated by starting the program, which no
change of ours will make cheap — and because it moves with the machine the
same way the binding does. The mark names it.

These are not in the default run. A measurement needs enough repetitions to
outweigh the noise, which makes it far slower than a differential test.

### What is asserted

A relationship, not a duration. Timings depend on the machine, its load, and
whatever else is running, so no single number means anything on its own. Two
timings taken together on one machine at one moment do: if one route is meant
to be far cheaper than the other, that ordering holds anywhere we would run
this, and a comfortable multiple can be demanded without the test becoming a
report on the hardware. The multiples live in the test, sit well below what
we expect to see, and exist to catch a route that has stopped being cheap
rather than to pin down a figure.

### Reading a failure

A failure here is a question rather than a verdict. It may mean what it says,
or it may mean the machine was busy. Run it again somewhere quiet before
believing it, and prefer to have believed it after two failures than to have
dismissed it after one.
>>>>>>> BASE      (49253d045a20a5f2076513756758a77ddeee06a9 Added mock binding and test)
