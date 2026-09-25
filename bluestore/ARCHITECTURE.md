# Overview

This directory contains a storage engine for Swift objects.

Swift's object server does not write object data itself. It delegates that
work to a class it is willing to have replaced, so a cluster can store
objects some way other than the standard one without altering Swift. That is
what this project does. The objects are stored by BlueStore, which is the
layer Ceph uses to put data on its own disks. The code here extracts
BlueStore from Ceph, wraps it, installs it next to Swift, and arranges for
Swift to use it.

Eight concerns follow from that, one per section below.

- [Building](#building) — the engine and its Python layer have to be
  compiled and installed onto a machine running Swift.
- [Engine](#engine) — BlueStore is machinery inside a large project that
  does not offer it to anyone, so it has to be extracted before it can be
  wrapped.
- [Object model](#object-model) — what BlueStore stores and what Swift expects
  of a name are not the same thing, so the engine defines a model of its own
  in between.
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

Code comments point back here by section, as `see ARCHITECTURE.md#policy`.
Those references make the headings an interface: add sections rather than
renaming or reordering them.

## Layout

```
bluestore/
  ARCHITECTURE.md     this file
  CMakeLists.txt      drives the builds below; compiles nothing itself
  pyproject.toml      project description: metadata, dependencies, build
  src/
    bluestore/        the python code for the storage backend Swift will use
    injection/        the engine, built inside Ceph's own build
    extension/        the binding and command line tool, built against it
    test/             the tests and the harness they run in
    vendor/           Ceph's source, fetched by the build and not committed
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
interpreter version and platform it was built for, so the build has to happen
somewhere compatible with the machine that will install it. Ours asks a little
more than most. It carries a large library of its own, compiled against the
system it was built on, and that library still uses a few of the system's own
libraries when it runs. Compatible is not the same as identical: what has to
line up is the interpreter version, and system libraries that are binary
compatible with the ones the build used.

## The first build

The engine is the expensive part. The first build fetches Ceph's source and
compiles the pieces our library depends on, so it wants a network connection
and some disk, and it takes minutes rather than seconds. Only those pieces
are built — see [Engine](#engine) — so this is a good deal smaller than
building Ceph.

Later builds are quick, because that half is cached and only our own code is
recompiled. The cache is worth protecting; see the note on clean builds at
the end of this section.

## Two ways to build

**uv** is for working on the project and needs nothing installed but uv. It
fetches a matching Python interpreter, the build tools, and every dependency
into a directory inside the project. Nothing it does touches the rest of the
machine.

**pip** is for producing the wheel that gets deployed, and is the one to
script, since it assumes nothing about the machine beyond what you put there.
You supply the interpreter, a C++ toolchain and CMake, and the development
packages of the system libraries the engine uses; see
[What the wheel carries](#what-the-wheel-carries). Swift is yours to supply as
well: the build does not need it and nothing on this path installs it, since
the Swift our code runs under belongs to whoever deploys it.

Both run the same build and produce the same wheel.

### Set up an environment

```sh
uv sync
```

```sh
python -m venv .venv && . .venv/bin/activate
pip install dependency-groups build
pip-install-dependency-groups dev
```

The tools needed to build are declared as a dependency group rather than as
ordinary dependencies, since they are wanted while building and never
afterwards. Groups are recent enough that older pip cannot read them, so the
pip path installs a helper that can, along with the program that drives the
build.

### Run the tests

```sh
uv run pytest              # default tests
uv run pytest -m <kind>    # one kind of test
uv run pytest -m ""        # every kind of test
```

```sh
. .venv/bin/activate
pytest                     # default tests
pytest -m <kind>           # one kind of test
pytest -m ""               # every kind of test
```

### Build a wheel

```sh
uv build --wheel
```

```sh
python -m build --no-isolation --wheel
```

`--no-isolation` tells the build to use the environment we just set up rather
than assembling a private one and fetching the build tools again. Ours are
already there, and a build this long should not be repeating that work.

### Install it

```sh
pip install --force-reinstall --no-deps dist/bluestore-*.whl
```

`--no-deps` is there because we declare Swift as a dependency, so that a
development environment gets a version we are compatible with. On a machine
running Swift that requirement is already met by the Swift it runs, and
fetching a second copy from PyPI would be wrong.

`--force-reinstall` is needed because our version number does not change
between iterations, so pip would otherwise decide the installed copy is
already current and do nothing.

### Check that it worked

An install puts three kinds of thing in place, and they can fail separately.
Check each:

```sh
python -c "import bluestore.hook"
python -c "import bluestore._raw"
bluestore-cli --help
```

The first is our Python code, the second the compiled engine behind it (see
[Binding](#binding)), the third the command line program. Silence from the
first two and a usage message from the third means installed.

The second check is the one that catches the most. It loads the compiled
module, which in turn has to find the engine library sitting beside it and
the system libraries the engine uses. It fails if any of them is missing,
naming the one it could not find, or if the module and the engine do not
agree. The third does the same for the command line program, which finds the
engine library by a different route.

If Swift then still refuses to start on an unknown policy type, the problem
is not the install; see [Policy](#policy).

## What the wheel carries

The engine is a library of its own, and it travels inside the wheel rather
than being installed on the machine. Everything it takes from Ceph is inside
it, so Ceph does not have to be installed, and no environment variable has to
be set to make the engine findable.

That works because everything which loads our code looks for the library by a
path relative to itself rather than in the usual system locations. The
compiled module finds it in the same directory; the command line program
finds it by walking from where it was installed to where our package lives.

The cost is that those relationships are fixed at build time. Moving the
library out of the package, or installing the program somewhere that does not
stand in the expected relation to the package, breaks loading — and it breaks
it at the moment something first tries to use it, not at install time.

What the wheel does not carry is a handful of ordinary system libraries that
the parts of Ceph inside the engine use, for compression, asynchronous disk
access and the like. Those are found the usual way. Most come with any normal
Linux installation; snappy and libaio are the ones most likely to be missing,
and a distribution's packages provide them. Compiling needs their development
packages as well, which are seldom installed by default.

Which libraries these are follows from which parts of Ceph are switched on
(see [Engine](#engine)), so the list can change with them. `readelf -d` on the
engine library shows the current one.

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

**`CMakeLists.txt`** compiles nothing itself. It sets up and runs the builds
that do, and collects what they produce into the places the wheel is
assembled from; [Engine](#engine) is about why the work is split up that way.
What comes out is three kinds of thing: a module Python can import and the
engine library it depends on, both of which have to end up inside our package,
and an ordinary program, which has to end up wherever installed programs go so
that a wheel install leaves it on `PATH`.

## Adding C++

There is more than one build, so the first question is which one your code
belongs to. Code that uses Ceph's own internals goes in `src/injection`,
because only the build that runs inside Ceph's can see them. Everything else
— the binding, the command line tool, anything reaching the engine through
the surface it already offers — goes in `src/extension`, and is compiled
against that surface rather than against Ceph.

Getting this wrong is not subtle. Reaching for a Ceph header from the
extension side fails while compiling, because it is not there to be found.

Add sources to whichever directory that is, declare them in the
`CMakeLists.txt` next to them as part of an existing target or a new one, and
give anything that has to be importable or runnable afterwards an install
destination. Every kind of product already exists in one of those files, so
there is an example to copy.

Before adding a function that Python will call, read
[Binding](#binding) and [Concurrency](#concurrency). Both place requirements
on how such a function is written, and neither failure is one the compiler
will catch.

After adding a new source location, check `cache-keys` in `pyproject.toml`.
It lists the files whose contents decide whether a cached build can be
reused. A file not covered there can be edited without triggering a rebuild,
which produces a frustrating loop where changes appear to do nothing. The
list matches paths, so a source file in a directory no pattern reaches is
invisible to it even though the build compiles it quite happily.

Deleting the build directory to force a rebuild is almost never what you
want: the engine's build lives there too, and throwing it away means waiting
out the first build again.

---

# Engine

The storage we want is BlueStore, and BlueStore is part of Ceph. Ceph is a
large project that builds into a set of servers and command line tools, and
BlueStore is machinery inside those rather than something Ceph offers to
anyone else. There is no package to install and nothing to link against. The
code is there and it compiles, but by the time Ceph's build has finished, the
piece we want has been folded into Ceph's own programs and is not separately
reachable.

This section is about how we get from that source tree to a single library
our own code can use, and how that library starts Ceph once it is loaded.

## Why we cannot simply link

A build is a set of pieces — libraries and programs — together with a
description of which pieces need which others, which headers they are
compiled against, and which settings they must all agree on. Ceph's build has
pieces for its object store, its configuration and logging, its key-value
layer, and a great many more.

That description exists only while Ceph is being built. When it finishes,
Ceph installs its servers and tools and discards the rest. Nothing is left
that tells a later build what the internal pieces were, what each needed, or
how they fit together.

We could try to reconstruct it: find the compiled pieces on disk, work out
which ones are required and in what order, and reproduce every setting they
were built with. That is guesswork, and the failures it produces are the
unpleasant kind — a build that succeeds and a program that misbehaves later,
because two halves were compiled under assumptions that did not match.

The alternative is to stop being outside, and everything below follows from
taking that option.

## Deciding, then compiling

CMake, the build system Ceph uses, works in two passes.

The first reads the project's build files and decides everything: which
pieces exist, what each needs, which options are on, what flags to use. No
compiling happens. The second carries out those decisions.

The distinction matters here more than it usually does. Choices are only
open during the first pass — once it is over, the answers are fixed. Almost
everything we do is done during that first pass, and much of it depends on
happening at the right moment within it.

## Joining Ceph's configuration

CMake lets a project be handed the name of an extra file to read as it starts
its first pass. Ceph neither knows nor cares: the name comes from outside,
and Ceph reads the file as though it had always been part of the project. Its
source is not modified and there is no patch to carry.

That file is `src/injection/CMakeLists.txt`. Everything in it runs as part of Ceph's own
configuration, which is what makes the rest possible. The following
subsections are the things it does.

## Answering questions before they are asked

Ceph's build offers a long list of switches — build the gateway or not,
build the filesystem or not, build the dashboard, the tracing, the management
daemons. Each is a question Ceph asks itself during configuration, and each
has a default.

A question already answered is not asked again. Because our file is read
before Ceph reaches those questions, setting a switch there settles it, and
Ceph configures itself accordingly. That is the whole mechanism: we are early
enough to have an opinion.

What we turn off is everything that is not storage. The principle is the
smallest Ceph that still contains what we came for; the list is long, it will
keep changing, and it lives in the file rather than here.

## Building only what we need

Turning features off is one lever. The other is asking for less.

When a build is asked for one particular piece, it builds that piece and
whatever that piece needs, and stops. The outer build asks only for our
library. Ceph's servers and tools are never compiled at all, not because they
were switched off but because nothing we asked for requires them.

Between the two, what actually gets compiled is the dependency chain behind
our library, which is a fraction of the project.

## Compiling for a shared library

We want the result to be one shared library: a single file that can be loaded
into a running program.

Code has to be compiled differently depending on where it will end up. Code
built into a program can assume it sits at a fixed address, because there is
one program and it knows where it is. A shared library has no such promise —
it is loaded wherever there is room, possibly at a different address in every
process — so its code has to be written to work regardless. That form is
slightly more expensive and is not what a build aimed at producing programs
would choose, so Ceph does not choose it. Our file asks for it everywhere,
because anything that will end up inside our library has to have it.

The same reasoning drives the other choices in that file. The dependencies
Ceph builds for itself are built in the form that folds into our library
rather than the form that sits beside it as a separate file, and the memory
allocator is left as the system's own rather than replaced. Everything Ceph
builds goes into one file. What it takes from the system instead, such as its
compression libraries, stays with the system, and that is all the file relies
on from its surroundings.

## Our library

Inside Ceph's configuration we declare a library of our own and say which of
Ceph's internal pieces it depends on.

Because the declaration is inside, the build works all the rest out itself:
which headers those pieces need, which definitions they were compiled with,
what has to be linked and in what order. That is precisely the guesswork we
could not do from outside, and here it is not guesswork at all — it is the
same calculation Ceph does for its own programs.

What comes out is one shared library. Our own small surface on the outside;
the parts of Ceph we need sealed within.

## Keeping to ourselves

That library gets loaded into a process that is already full of other code —
the Python interpreter, Swift, and whatever else those have brought with
them.

Shared libraries contribute names to the process they are loaded into, and
when two contribute the same name, one of them wins for everybody. Ceph is
large and its names are its own business, not something the rest of the
process should be exposed to or able to interfere with. So calls inside our
library are bound to their targets inside our library, rather than being left
open to whatever the process resolves them to later. What we deliberately
offer stays reachable; the rest stops being anyone else's concern.

The same place drops code that nothing in the library reaches, which is a
good deal of it given how much of Ceph comes along behind the pieces we
asked for.

This is the difference between a library that happens to build and one that
can be loaded into somebody else's process safely, which is the only way ours
is ever used.

## Starting Ceph

Ceph keeps its configuration, its logging and the threads behind them in one
context shared by everything in the process. Our library makes that context
the first time a store is opened, not when the library is loaded. The object
server loads our code before it forks the processes that serve requests, and
the thread that writes Ceph's log does not survive a fork, so the context has
to be made in the process that will use it.

It is made the way a library makes it rather than the way a Ceph server does.
Ceph's configuration file is not read, no administrative socket is opened, and
nothing is logged to the terminal. Nor does Ceph install its signal handlers,
which its servers do as part of starting up: the object server uses signals
to run its own processes, and they are not ours to take.

What Ceph is told instead is a short list of settings kept in `internal.cpp`,
and two of them are worth knowing about. BlueStore's cache is given over
mostly to metadata, and what is read is not kept in it, which is how Swift's
own backend treats the page cache: some data may end up cached, but nothing
relies on it being there. And the check BlueStore runs over a whole store
when asked to create one that already exists is off, since that is how the
engine opens every store.

Any setting can be overridden without a rebuild through the `CEPH_ARGS`
environment variable, which Ceph reads while making the context, and
`BLUESTORE_DEBUG` switches BlueStore to verbose logging on stderr.

## Describing what we made

The extension build has to link against this library, and cannot work out on
its own where it ended up, what headers go with it, or which language version
it was built to. So the inner build writes that down and the outer side reads
it.

The timing is the awkward part. Our file is read *before* Ceph configures
itself — that is what lets us answer its questions — which means that at the
moment we run, the answers we want to record do not exist yet. So the
recording is deferred: we ask for a piece of work to be run at the very end
of configuration, once every decision has been made, and it is then that the
settings are read off and the description written out.

What gets written is not instructions for building anything. It describes
something that already exists: where the file is, the name it will be known
by when loaded, which directory to take headers from, which language version
to compile against. A build that reads it gets a piece it can link against as
though it had built the thing itself.

If that description is missing or out of date, the extension build fails
while configuring, before anything is compiled. That is the direction we want
this failure to point: an inner build that did not finish should stop the
outer one at once rather than let it produce something subtly wrong.

## Why the builds are separate

Three builds run, and only one of them compiles anything of ours. The outer
build downloads Ceph's source and drives the other two. One of those is
Ceph's, with our file injected into it. The other is small, and builds the
binding and the command line tool against the library that came out.

An arrangement like this, where one build's job is to configure and run other
builds rather than to compile anything itself, is usually called a
superbuild. There are two reasons ours is one.

The first is that Ceph's settings are right in one place and wrong in the
other. Inside, we want them: they are what makes our library link correctly.
Outside, we do not — the binding should be built the way the rest of our code
is built, not the way Ceph builds itself. Separate builds are how each gets
its own answers.

The second is time. Ceph's build is the expensive one and our binding is not.
Keeping them apart means editing the binding re-examines only the binding,
and the large half sits untouched.

There is a small consequence of the split worth knowing: because the inner
builds are separate projects, their results cannot be placed straight into
the wheel. Each puts its output in a staging area and the outer build copies
from there into the places the wheel is assembled from.

## What it costs

Ceph's source is fetched rather than kept in this repository, and lands in a
directory that is not under version control. Fetching it is unavoidable and
the download is large, even though what gets compiled afterwards is only the
part we need. Everything after the first build is cached, and only our own
code is rebuilt. [Building](#building) has the practical side.

Ceph is also pinned to one release, named in `CMakeLists.txt`. The engine uses
parts of BlueStore that Ceph offers to no one and so promises nothing about,
such as shutting a store down quickly or growing one, and both the switches
we turn off and the system libraries Ceph uses move between releases. Moving
to another release is therefore a change to make on purpose, not something to
pick up along the way.

---

# Object model

What BlueStore offers and what Swift needs are not the same thing. Swift
wants a name that answers with whatever was written to it last, while a
reader already part-way through what was there before carries on reading
that. So the engine defines an object model of its own: built out of what
BlueStore offers, and shaped so that Swift's behaviour can be built out of it
in turn. It is not Swift's model and does not try to be — only something
Swift's can be expressed in.

What the engine deals in is Objects. Each is a thing of its own in the store,
with a state saying what may be done with it. The connections between them
are deliberately thin: an Object knows nothing of whatever held its name
before it, and the engine keeps no history. There is one relation and no more
— at most one Object holds a name at a time, and handing it over is one
transaction, so a crash leaves the name held by one of them and never by
neither. Which Object should hold it, and what holding it means to a client,
is decided above the boundary by the Python layer.

What follows is the vocabulary BlueStore brings, and then that model: what
an Object is, where it sits, and what becomes of the ones nothing points at
any more.

## What BlueStore offers

Everything below is built out of a handful of things BlueStore provides, and
the rest of this section uses them by name.

The first is an awkwardness rather than a feature. BlueStore stores things it
calls objects, and so does Swift, and so do we — three meanings for one word.
So in this section BlueStore's are **entries**, ours keep the capital letter,
and Swift's are whatever a client put there.

Entries live in **collections**. A collection is opened once and worked
within, and asking BlueStore to create one that already exists kills the
process, so ours are opened when the store is mounted — BlueStore's word for
opening one — and held until it is unmounted again.

An entry's **address** is a name and two numbers: which space it belongs to,
ordinary or temporary, and a **generation**. The temporary space is numbered
below the ordinary one, and a collection can be listed in order, so
everything temporary comes first. That ordering is load-bearing later.

An entry carries three kinds of content: its bytes, a handful of small named
values beside them called **attributes**, and a key-value map, whose
**header** is a blob of its own that can be read and written whole.

Changes are applied in **transactions**. A transaction is all-or-nothing on
disk — after a crash the whole batch is there or none of it is — but it is
not all-or-nothing to anyone reading at the time, who sees its changes land
one at a time. Its changes can be read as soon as it is handed to BlueStore,
and are durable only once BlueStore reports it committed, some time later. A
transaction can move an entry to another address inside its own collection,
which is how one is put in place; it cannot move one to a different collection,
and asking kills the process.

A **store**, finally, is a directory with one large file inside it, and that
file is the whole of the disk BlueStore has to work with.

## An Object and its states

An Object's state says what may be done with it, and every operation either
requires a state or moves to one. There are two ways through them: a search,
which finds whatever holds a name, and a write, which makes something that
can take the name over.

- **PRE_SEARCH** — what `find()` hands back, before anything has been looked
  up.
- **IN_SEARCH** — inside `open()`, and what tells it that finding nothing is
  an answer rather than a failure. An Object left in this state is one whose
  search did not finish.
- **MISSING** — the search finished and nothing holds the name.
- **PRE_WRITE** — what `create()` hands back. Nothing is on disk yet.
- **IN_WRITE** — being written. The first `write()` or `write_metadata()`
  prepares the entry and its attributes, which is why a delete or an empty
  object needs no `write()` at all.
- **ACTIVE** — holds the name. `put()` moves an IN_WRITE Object here.
- **OLD** — held the name until `put()` handed it to something else.

## Writing makes a new one

A write never lands in the Object a name already resolves to. It goes to one
created for the purpose, and `put()` then hands the name over: a single
transaction renames the old Object out into the temporary space and the new
one onto the name's address, writing both their attributes on the way. A
crash lands on one side of that or the other, so the name is never left held
by two Objects and never by neither. A reader looking while it happens is a
different matter — the renames land one at a time, and between them the name
resolves to nothing. A retired Object stays readable to whoever already holds
it, and goes away when they let go.

The reason writing works that way is the shape of a transaction. It can put
an entry in place in one step, but it cannot be held open while a body
arrives. An object server takes that body in chunks, over as long as the
client cares to take sending them, and has to keep answering reads from what
is already there throughout. Writing somewhere else and swapping is the only
shape that offers both.

## Deleting writes one too

A delete is not the absence of an Object. It is an Object that never had data
written to it: its deleted attribute is set before anything reaches the
store, it carries metadata of its own, and `put()` hands it the name exactly
as it would anything else. A delete and a write racing for the same name are
settled by one rule rather than two, and whatever finds it afterwards can
tell when it happened.

## The timestamp arrives late

Swift builds a writer before it knows what timestamp the object will have.
The timestamp comes with the metadata, after the body has been received,
which is too late to name the thing being written after it.

So `create()` stamps an Object with the clock, counted in the same
hundred-thousandths of a second Swift counts in, and `put()` replaces that
with the timestamp Swift chose. The state says which of the two is in hand:
one still being written has the guess, and one that has taken a name or been
retired has the real thing. Counting in Swift's unit is the price of being
able to replace one with the other, and the only opinion the engine has about
a timestamp it never interprets.

## Prepared, submitted, synced

Nothing the engine writes reaches BlueStore at the moment it is asked for.
`write()`, `write_metadata()`, `tombstone()` and `put()` each prepare a
transaction and add it to a queue the engine keeps, and so does everything
else that changes the store: removing an Object nobody holds, sweeping, and
setting up a new store's collections. `submit()` hands the queue to BlueStore
in the order it was filled. Only one caller does that at a time; one that
finds another already at it returns, and its transactions go with the rest.
`sync()` submits and then waits until the Object's latest transaction is
durable.

The order is the point. BlueStore has to apply transactions in the order the
decisions behind them were made, and preparing a transaction at the moment
its decision is made is what keeps the two in step. The slow parts, handing
the queue over and waiting for the disk, come afterwards, wherever suits the
caller.

One consequence is worth keeping in mind. BlueStore only answers from what it
has been handed, so something prepared and not yet submitted cannot be read,
even by the caller that prepared it. Code that has to read what it may just
have written syncs first.

## What the caller serialises

The engine serialises what it owns: its queue, the handing over of it, and
the clock its estimates come from. What it asks of the caller is narrower. A
change to an Object's state and the preparing of the transaction that
carries it have to happen as one step, with no other such step in between,
or the queue's order stops matching the order of the decisions. Reads are
outside that, deliberately — they are the common case, and almost all of
them collide with nothing. How the Python layer holds up its end is
[Concurrency](#concurrency).

What it costs is that a reader can be overtaken. It holds an Object and reads
it in pieces, and between two of those pieces the Object may have been
retired and removed. So after every read the engine re-reads the entry's
attributes at the same address and compares the timestamp it finds against
the one the Object holds; a mismatch, or nothing there at all, fails the read
rather than handing back another Object's bytes. A failed read is something
the layer above can retry; serialising every read would be paid for by all
the ones that never needed it.

Metadata is the exception. It is rewritten in place rather than by making a
new Object, so a caller reading it across several calls can see parts of two
updates. That is the price of a POST not having to copy the object it
describes. The Python layer notices when it happens and reads again; see
[Concurrency](#concurrency).

Three failures are worth telling apart. StateError says the caller asked for
something the Object's state does not allow, which is a bug above rather than
a condition to handle. ChangedError says the ground moved while an Object was
being read. ConflictError says an Object was offered that is not newer than
the one it would replace, which is an ordinary thing to tell a client.

## Where an Object sits

A name is hashed — with rjenkins, the function Ceph uses for the same job —
and the hash picks one of a fixed set of collections. Every Object under that
name lives in that one collection, and the address is what says which of them
holds it: the one that does sits in the ordinary space at generation 0, and
the ones being written or retired sit in the temporary space, at a generation
taken from their timestamp. For one that has not been settled yet, that is
the estimate, and estimates never repeat within a process, so two Objects
being written never share an address.

Two things follow, and both are load-bearing. Because the temporary space
sorts first, `clean()` can list a collection from the beginning, remove what
it finds, and stop at the first entry that is not temporary — everything past
that point holds a name, so it never has to be read. And because everything
under a name is in one collection, handing the name over is a move inside
that collection rather than a copy out of it, which matters because moving an
entry between collections is the case that kills the process.

## What is stored, and where

An Object's timestamp and whether it is a deletion are attributes, along with
one more that tells a retired Object from one still being written. Its state
is not stored at all: an entry in the ordinary space is ACTIVE, and one in
the temporary space is OLD or IN_WRITE according to that flag. A stored state
can disagree with reality after a crash, and a derived one cannot.

Swift's metadata goes in the map header, as bytes the engine never looks
inside. That is what lets the Python layer pick its own format without the
engine having an opinion about it, and it is why the command line tool can
print an object's metadata without the two of them agreeing on anything.

## What a crash leaves

An Object being written, or one that has been retired, is reachable only
through whoever holds it. When the last holder lets go its removal is
prepared, because nothing can find it again.

A crash leaves no holders, so those Objects stay where they are. Sweeping
them is a separate operation rather than part of mounting, so a store that
failed can be opened and listed exactly as it was left, and swept afterwards
once someone has looked at it. The Python layer sweeps every store it opens;
the command line tool leaves that to its `clean` command.

## Capacity

A store's size is the size of that one large file, and BlueStore never grows
it of its own accord. Nor does it fail politely when it runs out: a store
that fills kills the process rather than returning an error.

The file is sparse, so it costs only what has been written to it, but nothing
is ever given back to the filesystem. Returning space means telling the
device that a range is no longer in use — a discard — and a discard needs a
real block device rather than a file, so whatever a store has used stays
used.

So a store grows toward its capacity and stays there, whatever is live inside
it. Capacity is not a ceiling a store approaches slowly — it is the disk that
store will eventually occupy, which is why it comes from configuration rather
than from a default that suits nobody in particular.

Growing a store is possible and shrinking it is not. Growing needs the store
unmounted, and growing one that another process has open kills ours — so the
store is mounted, unmounted, and only then grown. A store somebody else holds
fails at that first mount, the way everything else does, with an error rather
than a crash.

## Closing a store

**A store is never unmounted the normal way.** BlueStore's unmount ends by
checking that nothing is cached anywhere in the process, not just in the store
being unmounted, so with a second store mounted it kills the process. When the
last user of a store lets go, the engine shuts it down the quick way instead
and keeps it until the process exits, never mounting it again; opening the
same path makes a new store. This is effectively solved, and all it costs is
the memory a closed store still holds. Growing a store is the one exception,
shutting it down and mounting it again before anything has used it.

## Large objects

**Large objects are expensive to write.** What RocksDB writes for an object
grows with the square of the object's size, until for anything near a
gigabyte it is comparable to the object itself. A larger `network_chunk_size`
in the object server lowers the curve without changing its shape. The cause
is in BlueStore, which starts from the beginning of an object every time it
reshards the map of where the object's data lies. Ceph never meets this,
because it caps objects far below what Swift allows, and we do not split
objects to do the same. Upstream is actively reworking the resharder, and a
fix there should reach us with a later release of Ceph.

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

## The engine is an object

What crosses the boundary is not a set of loose functions. The engine is a
thing with a lifetime: it is opened, used for as long as it is wanted, and
closed. Python holds a handle to it and the state stays on the native side,
where it belongs — the Python layer never sees what is behind the handle and
has no way to reach into it. Objects cross the same way: Python holds a
handle, and the Object itself stays native.

Two things follow. The handle has to be kept for as long as the storage is
in use, because letting go of it is what closes the engine — though not
until every Object it handed out has been let go as well, since each of them
keeps the store open too. Closing means the quick shutdown described in
[Object model](#object-model). And opening one is not free, so it happens
once when the storage is set up rather than per request.

## The binding does not decide anything

A function in `_raw` should do three things: convert its arguments into what
the engine wants, call the engine, and convert the result back. Nothing else.
No validation beyond what conversion requires, no retries, no special cases,
no deciding what to do when the engine says no. When it does say no, its
three errors arrive in Python as exceptions of the same names —
`StateError`, `ChangedError` and `ConflictError` — and that translation is
all the binding does with them.

This is worth holding to because a decision made in the binding is made in
the worst available place. It cannot be exercised by the engine's own tests,
which do not go through Python, nor by tests of the Python layer, which stop
at the boundary. It is invisible from both sides and belongs to neither. Put
the decision in the engine if it is about storage, and in the Python layer if
it is about what Swift expects, and the binding stays a thing you can read in
one sitting.

A binding function has one more obligation, which is not about translation
at all: it either gives up the interpreter lock while the engine works or
deliberately keeps it, and which one depends on what the call does. See
[Concurrency](#concurrency).

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

The engine can also be driven directly, by a program that does not involve
Python at all:

```sh
bluestore-cli --help
```

It is installed by the same wheel and is on `PATH` once that wheel is
installed. It exists so the engine can be exercised on its own, with nothing
else in the picture: when something misbehaves, it answers whether the engine
or the layers above it are at fault. [Testing](#testing) also uses it as the
thing to measure the binding against, since it reaches the same engine by an
entirely different route.

It mounts the store itself, and only one process can have a store mounted at
a time, so it can only be pointed at a store no running object server holds:
a stopped server's, or a copy. It also writes metadata exactly as it is
given, knowing nothing of the format the Python layer keeps it in, so an
object written through it is only readable by Swift if its metadata was given
in that format. It is for looking at a store and exercising the engine, not
for editing a store Swift will read.

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

## Two kinds of call

Calls into the engine come in two kinds, and the two are handled in opposite
ways.

**Calls that wait** — mounting a store, `open()`, reading, `submit()`,
`sync()` and `clean()` — have to satisfy both halves of that:

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

**Calls that do no waiting** — `create()` and `find()`, which make an Object,
and `write()`, `write_metadata()`, `tombstone()` and `put()`, which prepare
transactions — do the opposite, deliberately. They run on the server's thread
and keep the lock. A change to an Object's state and the preparing of the
transaction that carries it have to happen as one step, with no other in
between (see [Object model](#object-model)), and keeping the lock on the
server's one thread is what guarantees it: nothing else in the process can
decide anything until the call returns. They can afford to, because all they
do is build a transaction in memory.

Every existing call is already handled the way its kind requires. The Python
side lives in `device.py` and the native side in the binding it calls;
between them they are the example to follow, and following it is not
optional.

## One engine, many threads

There is a consequence of handing waiting calls to a pool that is easy to
miss: a pool has more than one thread in it. The Python layer holds a single
engine and every request reaches it through that same handle. So the engine
is not called from one thread at a time — it is called from several at once,
and it is our own choice that makes this so.

Anything the engine holds has to tolerate that. A value read by one call
while another is writing it is a bug that belongs to us rather than to the
caller, because nothing on the Python side is in a position to prevent it.

So the engine guards what it shares. Its queue has a lock of its own, only
one caller hands the queue to BlueStore at a time, estimates are handed out
one at a time, and so are places on the list of closed stores. An
Object's record of its latest transaction is read under the queue's lock as
well, since a call on the server's thread may be replacing it at that moment.

## How this fails

A call that waits, handled the wrong way, does not look broken.

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
incidentally. The `smoke` tests are that: a heartbeat notices the server's
thread going unserved while requests are in flight; see [Testing](#testing).

Getting the other kind wrong fails differently. A call that decides, moved
off the server's thread or made to give up the lock, lets another decision
slip in before its transaction is prepared. Nothing slows down. Instead the
queue stops matching the order things were decided in, and results go wrong,
only under concurrency and only now and then.

## Adding a function to the engine

Any new function that Python will call is one of the two kinds, and has to be
written as one before anything relies on it, not afterwards. One that waits
releases the lock around the work on the native side and is called through
the thread pool. One that does no waiting keeps the lock, is called directly,
and does nothing slow; anything that reads from storage or waits on it is the
first kind. Add nothing else — see [Binding](#binding) for what the binding
may and may not contain.

## The Device

Everything the Python layer does with a store goes through one object,
`BluestoreDevice` in `device.py`, and nothing else in the Python layer calls
the engine. There is one per store. It mounts its store in the background
when it is made, and requests that arrive before the mount finishes wait for
it.

At its centre is a map from each name to the Object for the version that name
currently resolves to. Every request that wants the name gets that same
Object rather than one found for itself, and the sharing is what makes
retiring simple. When a PUT or a DELETE hands the name to a new Object, the
one it replaces becomes OLD in place, so every request still reading it
carries on from where it was retired to, with nothing to tell them. It is
removed once the last of them lets go; the map itself keeps nothing alive,
and only remembers an Object while some request holds it. A second Object for
the same version would have no such luck: the moment the first was retired,
the second would point at an address that now holds something else.

The map is also what decisions are made from. Whether a PUT is newer than
what it replaces is judged against the Object in the map, not against
whatever BlueStore reports, since BlueStore may not have been handed the
latest put yet. A search still in progress sits in the map too, so requests
that want the same name wait for it instead of starting their own.

A read can still be overtaken. A request reading an Object that has just been
retired asks for it at its new address, possibly before the renames have been
handed to BlueStore, and gets a ChangedError. The Device retries such a read a
few times, yielding first and then waiting a little longer each time; by then
the renames have usually been handed over.

Waiting for a write to become durable occupies a thread of the pool until
BlueStore reports the commit, which is what Swift's own backend does when it
finishes a PUT. The size of the object server's pool,
`eventlet_tpool_num_threads`, therefore bounds how many requests can be
waiting on the disk at once.

Metadata needs one more thing. A POST rewrites an Object's metadata in place,
so the Device keeps a metadata version for each Object, raised by every such
rewrite. A metadata read syncs first, since a POST may be prepared and not yet
handed over, and starts again whenever the version moves while it reads. What
it returns is the complete, current metadata, never parts of two.

## One process per store

Only one process can have a store mounted, so every request for a device has
to reach the process that holds its store. The object server has to run with
`workers = 1`, or with `servers_per_port = 1`: then each port is served by a
process of its own, a device's requests always reach the same process, and
devices on different ports are still served in parallel. Each process opens a
store when the first request for its device arrives; see [Engine](#engine).

**Reloads are not supported.** A reload starts new processes while the old
ones still hold their stores, so the new ones cannot open them. A store that
cannot be opened stays unusable to that process until it is restarted; there
is no recovering in place.

---

# Interface

Swift's object server carries out a request through a DiskFileManager and the
DiskFiles it produces. That interface, the standard implementation of it, and
what is gained and lost by replacing it are the subject of the object-server
presentation in this repository. Read it first. This section only says what we
do about it.

Our implementation of it is split across a few files in `src/bluestore`:

- **`manager.py`** is the DiskFileManager Swift finds by name. It keeps one
  Device per device and policy, made when a request first wants it and held
  for as long as the manager lives. Each store is a directory under its
  device, named after the policy the way Swift names its per-policy
  directories: `bluestore-1` for policy 1.
- **`device.py`** is the Device, the one place the engine is reached from;
  see [Concurrency](#concurrency).
- **`diskfile.py`**, **`reader.py`** and **`writer.py`** are Swift's DiskFile,
  reader and writer. They translate Swift's calls into the Device's and hold
  nothing beyond the request. The writer hands each chunk on as it arrives and
  the reader reads in pieces of `disk_chunk_size`, so our code never holds a
  whole object in memory.
- **`metadata.py`** holds Swift's metadata rules; see
  [Metadata](#metadata) below.

Three things are worth adding to what the presentation covers.

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

**The Device is where the two halves meet.** Swift's expectations arrive
through the DiskFile classes and the engine is reached from the Device, so
that is the file answering to both. What Swift requires of it is above; what
the boundary requires is set out in [Binding](#binding) and
[Concurrency](#concurrency), and applies to every call it makes across.

## Metadata

Swift's metadata for an object is kept in the map header as one JSON blob, in
a format that is ours to choose since the engine never looks inside it. The
blob has two sections: `data`, what the PUT or DELETE wrote, and `meta`, what
the newest POST wrote. They are merged when read, the way Swift's own backend
merges an object's `.data` or `.ts` file with its `.meta` file, and the
content type follows `Content-Type-Timestamp` the way it does there.

A POST belongs to the name rather than to one version of it. A POST newer
than a PUT or DELETE that lands after it is carried into the new version's
blob, as Swift's own backend keeps a `.meta` that is newer than the data
beside it. So a POST racing a PUT is settled by their timestamps, not by
which arrived first.

A POST rewrites the blob in place: it reads what is there, merges, and writes
it back through the Device, whose metadata version keeps any read from seeing
half of it. Deciding what to write is `MetadataModel`'s job. Given what holds
the name now, it says what the next blob should be; it does no I/O, so it can
be tested on its own. Its `delete` is kept apart from `put`, though today one
only calls the other, so that a different behaviour for deletes has somewhere
to go.

## What is left out

Some of what Swift's own backend does is not done here.

- **Tombstones are never reclaimed.** Swift's own backend reclaims one nobody
  has touched only through the replicator, which does not run here.
- **`X-Delete-At` is not enforced.** Swift hands the DiskFile the request's
  time to check expiry against and ours ignores it, so an expired object stays
  readable until the expirer deletes it.
- **Failed container updates are not saved.** `pickle_async_update` does
  nothing, so the object-updater never retries them.
- **`mount_check` and partitions are ignored.** A store is not a mount point,
  and objects are placed by name rather than by partition.
- **Replication is out of scope**, along with the daemons that do it; see
  [Policy](#policy).

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

`hook_apply.pth`, installed as `bluestore_hook.pth`, holds one such line,
importing `bluestore.hook`. The hook installs a finder at the front of
Python's import machinery, watching for two module names. When either is
imported, it lets the module load as usual and then runs a small piece of our
code.

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

Tests come in kinds. Each kind asks one sort of question, has its own
machinery, and is written under its own rules. A section below describes
each; more can be added as more questions turn out to be worth asking.

## Kinds are marks

Every test carries a mark naming its kind. The mark is not decoration: it is
what selects the test, so it decides whether the test runs at all.

The default run selects the kinds cheap enough to sit in a loop with.
Anything else is asked for by name:

```sh
uv run pytest              # the default kinds
uv run pytest -m <kind>    # one kind
uv run pytest -m ""        # everything
```

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
throughout, so nothing drifts. `call.stamps(n)` hands a test a run of
single-backend timestamps, for tests that need to choose which of their
requests is the newer one.

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

### Racing requests

The harness yields at every chunk of a request's body and of its response, as
a socket would, so requests in flight together interleave at chunk boundaries.
`call.spawn()` makes use of that: it sends a request to both backends without
waiting for either, so a test can land other requests before joining it, and
its `wait()` then compares the two responses like any other call.

The `paused` fixture in `test_conflict.py` goes one step further. It holds a
request on both backends just before its DiskFile write while the test lands
a newer one, then lets it finish. Swift's own backend settles races like that
by cleaning up afterwards while answering success, so it is the responses and
what is left behind that get compared.

## Fork — `fork`

Crossing the binding is supposed to be cheap. Nothing in the code says so and
nothing breaks when it stops being true: a change to how arguments are
converted, or to how much work one call carries, can make crossing expensive
while every answer stays correct. These tests exist to notice that happening.

A duration on its own says nothing, so the test needs something to measure
against. That is the command line tool, which reaches the same engine by
starting a separate program. It is useful here precisely because it is slow
and always will be — its cost is dominated by starting a process and mounting
a store, neither of which any change of ours will make cheap — and because it
moves with the machine the same way the binding does. The mark names it.

These are not in the default run. A measurement needs enough repetitions to
outweigh the noise, which makes it far slower than a differential test.

### What is asserted

A relationship, not a duration. Timings depend on the machine, its load, and
whatever else is running, so no single number means anything on its own. Two
timings taken together on one machine at one moment do: since one route is far
cheaper than the other, that ordering holds anywhere we would run this, and a
comfortable multiple can be demanded without the test becoming a report on the
hardware.

### Reading a failure

A failure here is a question rather than a verdict. It may mean what it says,
or it may mean the machine was busy. Run it again somewhere quiet before
believing it, and prefer to have believed it after two failures than to have
dismissed it after one.

A run that fails leaves its store behind, so the tool can be pointed at
exactly the state that failed; a run that passes takes it away again.

## Engine — `engine`

The engine, the binding and the command line tool, without an object server:
`test_engine.py` and `test_cli.py`. They check what the differential tests
cannot see from outside — the state rules, a stale handle, several stores in
one process, capacity, the tool's exit codes, and what a crash leaves behind.
Each test mounts a store of its own and closes it again.

These run by default.

## Device — `device`

The Device and the metadata rules, without an object server: `test_device.py`
and `test_metadata.py`. `MetadataModel` is tested on its own, with no store at
all. The Device's tests cover its chunked metadata reads and what a read sees
while a POST lands, the latter as a real race between two greenthreads.

These run by default.

## Smoke — `smoke`

Many requests in flight at once against a few shared names, sent to our
backend only. The order they land in is not deterministic, so there is no
reference response to compare against request by request.

Instead each request checks itself. It is written as a generator that records
what it is about to do before anything is sent, so that when its response
comes back it knows every state its name could have held while it ran, and
checks the response against those. The write that decides what a name holds
next confirms it with a follow-up GET once the round is over.

A heartbeat runs alongside, measuring the longest the server's thread went
unserved during each round, and a round over the bound fails. This is the
measurement [Concurrency](#concurrency) asks for.

These are not in the default run. The seed is printed, and
`BLUESTORE_SMOKE_SEED` replays a run; a run makes enough rounds that it
stands in for many seeds. A run that fails keeps its stores, and they are
large, so remove them once they have been looked at.
