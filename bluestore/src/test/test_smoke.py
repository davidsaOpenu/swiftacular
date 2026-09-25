# Many requests in flight at once against a few shared names, with a
# heartbeat watching for anything that holds the hub while they run.
# Not in the default run; ask for it with -m smoke.
# see ARCHITECTURE.md#testing

from collections import defaultdict, namedtuple
from hashlib import md5
import os
import random
import time

import eventlet
import pytest

# What a GET shows of a name: its status, the timestamp of its data or
# tombstone, the POST whose metadata it carries, and the etag of its data.
State = namedtuple("State", "status ts meta etag")


def body_of(name, ts, size):
    line = ("%s %s\n" % (name, ts)).encode()
    return line * (size // len(line))


def resume(gen, resp):
    try:
        return gen.send(resp)
    except StopIteration:
        return None


def seeded():
    seed = int(os.environ.get("BLUESTORE_SMOKE_SEED") or random.randrange(2 ** 32))
    print("seed=%d" % seed)
    return random.Random(seed)


class Smoke:
    THREADS = 16
    ROUNDS = 50
    BODY_SIZE = 3 * 2 ** 20
    HEARTBEAT = 0.001
    STALL_BOUND = 0.100
    NEVER = "0000000000.00000"   # older than any timestamp the clock hands out
    MISSING = State(404, NEVER, None, None)

    def setup_method(self):
        self.rng = seeded()
        self.round = 0
        self.held = defaultdict(lambda: self.MISSING)   # what each name held when the round began

    def draw(self, call, mix, names):
        return [self.rng.choice(mix)(self.rng.choice(names), ts) for ts in call.stamps(self.THREADS)]

    def heartbeat(self, pool):
        worst = 0.0
        while pool.running():
            start = time.monotonic()
            eventlet.sleep(self.HEARTBEAT)
            worst = max(worst, time.monotonic() - start - self.HEARTBEAT)
        return worst

    def shows(self, resp):
        stamp = resp.headers.get("X-Backend-Timestamp")
        if resp.status_int != 200:
            return State(resp.status_int, stamp or self.NEVER, None, None)

        ts = resp.headers["X-Backend-Data-Timestamp"]
        etag = md5(resp.body).hexdigest() if resp.request.method == "GET" else resp.etag
        return State(200, ts, stamp if stamp != ts else None, etag)

    def drive(self, call, gens):
        self.writes = defaultdict(dict)    # this round's PUTs and DELETEs: ts -> the state each leaves
        self.posts = defaultdict(set)      # this round's POSTs
        self.accepted = defaultdict(set)   # and those answered 202

        self.rng.shuffle(gens)
        requests = [next(gen) for gen in gens]

        pool = eventlet.GreenPool()
        beat = eventlet.spawn(self.heartbeat, pool)
        threads = [pool.spawn(call.diff, *request) for request in requests]
        pool.waitall()
        stall = beat.wait()

        followups = [(gen, resume(gen, thread.wait())) for gen, thread in zip(gens, threads)]
        for gen, request in followups:
            if request is not None:
                resume(gen, call.diff(*request))

        print("round %d: stall %.1f ms" % (self.round, stall * 1000))
        assert stall < self.STALL_BOUND, "round %d: the hub was held for %.1f ms" % (self.round, stall * 1000)
        self.round += 1

    def landing(self, name, ts):
        states = [self.held[name]] + [s for t, s in self.writes[name].items() if t != ts]
        return states + [s._replace(meta=p) for s in states if s.status == 200
                         for p in self.posts[name] if p > s.ts and p != ts]

    def put(self, name, ts):
        body = body_of(name, ts, self.BODY_SIZE)
        self.writes[name][ts] = State(200, ts, None, md5(body).hexdigest())
        resp = yield ("PUT", name, body, ts)

        statuses = {409 if s.ts >= ts else 201 for s in self.landing(name, ts)}
        assert resp.status_int in statuses, "PUT %s @ %s" % (name, ts)

        if ts != max(self.writes[name]):
            return
        resp = yield ("GET", name, None, None)
        meta = max((p for p in self.accepted[name] if p > ts), default=None)
        self.held[name] = self.writes[name][ts]._replace(meta=meta)
        assert self.shows(resp) == self.held[name], "settled after PUT %s @ %s" % (name, ts)

    def delete(self, name, ts):
        self.writes[name][ts] = State(404, ts, None, None)
        resp = yield ("DELETE", name, None, ts)

        statuses = {404 if s.status == 404 else 409 if s.ts >= ts else 204
                    for s in self.landing(name, ts)}
        assert resp.status_int in statuses, "DELETE %s @ %s" % (name, ts)

        if ts != max(self.writes[name]):
            return
        resp = yield ("GET", name, None, None)
        self.held[name] = self.writes[name][ts]
        assert self.shows(resp) == self.held[name], "settled after DELETE %s @ %s" % (name, ts)

    def post(self, name, ts):
        self.posts[name].add(ts)
        resp = yield ("POST", name, None, ts)

        statuses = {404 if s.status == 404 else 409 if (s.meta or s.ts) >= ts else 202
                    for s in self.landing(name, ts)}
        assert resp.status_int in statuses, "POST %s @ %s" % (name, ts)
        if resp.status_int == 202:
            self.accepted[name].add(ts)

        if self.writes[name] or ts != max(self.posts[name]) or resp.status_int != 202:
            return
        resp = yield ("GET", name, None, None)
        self.held[name] = self.held[name]._replace(meta=ts)
        assert self.shows(resp) == self.held[name], "settled after POST %s @ %s" % (name, ts)

    def read(self, method, name, ts):
        resp = yield (method, name, None, ts)
        assert self.shows(resp) in self.landing(name, ts), "%s %s @ %s" % (method, name, ts)

    def get(self, name, ts):
        return self.read("GET", name, ts)

    def head(self, name, ts):
        return self.read("HEAD", name, ts)


@pytest.mark.smoke
class TestMixed(Smoke):
    """A random mix of every request type on a few shared names."""

    NAMES = ["/sda1/0/a/c/mixed-%d" % i for i in range(3)]

    def test_main(self, call):
        mix = [self.put] * 3 + [self.get] * 3 + [self.head] * 2 + [self.post] * 2 + [self.delete]
        for _ in range(self.ROUNDS):
            self.drive(call, self.draw(call, mix, self.NAMES))


@pytest.mark.smoke
class TestGeneralUse(Smoke):
    """Mostly reads over more names, with objects large enough that a PUT is
    still arriving while reads land on its name."""

    NAMES = ["/sda1/0/a/c/general-%d" % i for i in range(8)]
    BODY_SIZE = 10 * 2 ** 20

    def test_main(self, call):
        for _ in range(self.ROUNDS):
            self.drive(call, self.draw(call, [self.get, self.get, self.put], self.NAMES))


@pytest.mark.smoke
class TestConcurrentPuts(Smoke):
    """Distinct bodies at distinct timestamps to one object, sent at once: the
    highest timestamp wins, and no body is torn."""

    PATH = "/sda1/0/a/c/concurrent-puts"
    THREADS = 8
    ROUNDS = 25

    def test_main(self, call):
        for _ in range(self.ROUNDS):
            self.drive(call, [self.put(self.PATH, ts) for ts in call.stamps(self.THREADS)])


@pytest.mark.smoke
class TestPutDeleteAdjacent(Smoke):
    """A PUT and a DELETE at adjacent timestamps, sent at once: what is left
    follows the timestamps, not the order they landed in. Which of the two is
    newer alternates from round to round."""

    PATH = "/sda1/0/a/c/put-delete"

    def test_main(self, call):
        for round in range(self.ROUNDS):
            older, newer = call.stamps(2)
            put, delete = (newer, older) if round % 2 == 0 else (older, newer)
            self.drive(call, [self.put(self.PATH, put), self.delete(self.PATH, delete)])
