from collections import namedtuple
from threading import Thread
from random import Random
from queue import Queue, Empty
import threading
import time

StatPoint = namedtuple('StatPoint', ['name', 'thread', 'time'])

class ParallelStats:
    def __init__(self, size=0, name="main"):
        self._queue = Queue(size)
        self._last = time.perf_counter()
        self._name = name
        self._store = {}

        self._start = float("Inf")
        self._end = - float("Inf")

    def __enter__(self):
        self._queue.put(StatPoint(
            name='start',
            thread=threading.current_thread(),
            time=time.perf_counter()
        ))

    def __exit__(self, error, *args):
        self._queue.put(StatPoint(
            name='end' if not error else 'error',
            thread=threading.current_thread(),
            time=time.perf_counter()
        ))

    def report(self):
        now = time.perf_counter()
        threads = set()
        busy = ops = 0

        while True:
            try:
                data = self._queue.get(False)
            except Empty:
                break

            if data.thread not in threads:
                threads.add(data.thread)

            if self._start > data.time:
                self._start = data.time
            if self._end < data.time:
                self._end = data.time

            if data.name == "start":
                self._store[data.thread] = data.time
            elif data.name == "end" or data.name == "error":
                if data.thread in self._store:
                    start = self._store.pop(data.thread)
                else:
                    start = self._last

                busy += data.time - start
                if data.name == "end":
                    ops += 1

        for thread in self._store:
            if thread not in threads:
                threads.add(thread)

            busy += now - max(self._last, self._store[thread])
            self._store[thread] = now

        duration = now - self._last
        rate = ops / duration
        concurrency = busy / duration

        self._last = now
        return f"{self._name} stats: {duration=:2.2f}s {ops=} {rate=:2.2f} {concurrency=:2.2f}/{len(threads)}"

    def total(self):
        self.report()

        duration = self._end - self._start

        return f"{self._name} total: {duration=:2.2f}s"
        

class BaseParallelWorkload:
    def __init__(self, operations=10_000, objects=1_000, rw_ratio=0.7, workers=20, seed=42):
        self._operations = operations
        self._objects = objects
        self._rw_ratio = rw_ratio
        self._workers = workers
        self._seed = seed

    def put(self, conn, idx):
        pass

    def get(self, conn, idx):
        pass

    def preput(self, queue):
        for idx in range(self._objects):
            queue.put((False, idx))

        for i in range(self._workers):
            queue.put((None, None))

    def producer(self, queue):
        rng = Random(self._seed)

        for i in range(self._operations):
            is_get = rng.random() < self._rw_ratio
            idx = rng.randrange(self._objects)
            queue.put((is_get, idx))

        for i in range(self._workers):
            queue.put((None, None))
    
    def consumer(self, conn, stats, queue):
        while True:
            is_get, idx = queue.get()
            if idx is None:
                queue.task_done()
                return

            if is_get:
                action = self.get
            else:
                action = self.put

            with stats:
                action(conn, idx)

            queue.task_done()

    def _start(self, conn_gen, log, producer, name):
        stats = ParallelStats(name=name)
        queue = Queue(self._workers * 2)

        Thread(target=producer, args=(queue,), daemon=True).start()

        workers = []
        for i in range(self._workers):
            workers.append(Thread(
                target=self.consumer,
                args=(conn_gen(), stats, queue),
                daemon=True
            ))

        for w in workers:
            w.start()

        while any(w.is_alive() for w in workers):
            time.sleep(1)
            log(stats.report())

        log(stats.total())

    def start(self, conn_gen, log=print, preput=True):
        if preput:
            self._start(conn_gen, log, self.preput, "preput")
        self._start(conn_gen, log, self.producer, "main")

    @staticmethod
    def exit_on_thread_error():
        import os, sys, threading, traceback

        def hook(args):
            traceback.print_exception(args.exc_type, args.exc_value, args.exc_traceback)
            print(f"thread {args.thread.name} failed — aborting", file=sys.stderr)
            sys.stderr.flush()
            sys.stdout.flush()
            os._exit(1)

        threading.excepthook = hook

class ParallelWorkload(BaseParallelWorkload):
    def __init__(self, container, prefix, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._container = container
        self._prefix = prefix

    def put(self, conn, idx):
        conn.put_object(self._container, self._prefix + str(idx), "A" * 512)

    def get(self, conn, idx):
        conn.get_object(self._container, self._prefix + str(idx))

class MockWorkload(BaseParallelWorkload):
    def put(self, conn, idx):
        time.sleep(idx / 100)

    def get(self, conn, idx):
        time.sleep(idx / 1000)

if __name__ == '__main__':
    MockWorkload.exit_on_thread_error()
    work = MockWorkload(workers=300)
    work.start(lambda: None)
