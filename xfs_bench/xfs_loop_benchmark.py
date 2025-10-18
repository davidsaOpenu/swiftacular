#!/usr/bin/env python3
"""
xfs_loop_benchmark.py

Creates a loop-backed XFS filesystem (default 5 GiB), mounts it,
and runs two separate benchmark phases:

  1. File write workloads
  2. xattr set/get performance

HOWTO:
  sudo python xfs_loop_benchmark.py --prepare --mountpoint /mnt/xfsbench
  sudo python xfs_loop_benchmark.py --mount --mountpoint /mnt/xfsbench
  chown user:grp /mnt/xfsbench -R
  python xfs_loop_benchmark.py --mountpoint /mnt/xfsbench --run-all
"""

import xattr
import argparse
import os
import sys
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path


# ----------------------- Utilities -----------------------

def run(cmd, check=True, capture=False):
    print("RUN:", " ".join(cmd))
    if capture:
        return subprocess.check_output(cmd).decode()
    else:
        subprocess.check_call(cmd)


def require_root():
    if os.geteuid() != 0:
        print("This operation requires root (for losetup/mkfs/mount). Rerun with sudo.")
        sys.exit(1)


def human(n):
    for unit in ['B','K','M','G']:
        if abs(n) < 1024.0:
            return "%3.1f%s" % (n, unit)
        n /= 1024.0
    return "%3.1f%s" % (n, 'T')


def human_readable_size(n):
    """Format size for table display"""
    if n < 1024:
        return f"{n} B"
    elif n < 1024*1024:
        return f"{n//1024} KB"
    elif n < 1024*1024*1024:
        return f"{n//(1024*1024)} MB"
    else:
        return f"{n//(1024*1024*1024)} GB"


# ----------------------- Image setup -----------------------

def prepare_image(image_path: str, size_gb: int = 5, force: bool = False):
    """Create a sparse image and format it as XFS."""
    require_root()
    image = Path(image_path)
    if image.exists() and not force:
        print(f"Image {image} already exists. Use --force to overwrite or reuse it.")
        return
    print(f"Creating sparse file {image} of {size_gb} GiB")
    with open(image, 'wb') as f:
        f.truncate(size_gb * 1024**3)
    run(["mkfs.xfs", "-f", str(image)])
    print("Image prepared. You can now mount it with --mount.")


def mount_image(image_path: str, mountpoint: str):
    require_root()
    mp = Path(mountpoint)
    mp.mkdir(parents=True, exist_ok=True)
    loop = subprocess.check_output(["losetup", "--find", "--show", str(image_path)]).decode().strip()
    print(f"loop device: {loop}")
    run(["mount", loop, str(mp)])
    print(f"Mounted {image_path} on {mp}")


def unmount_image(mountpoint: str, image_path: str):
    require_root()
    run(["umount", mountpoint])
    out = subprocess.check_output(["losetup", "-j", str(image_path)]).decode()
    for line in out.splitlines():
        dev = line.split(":")[0]
        run(["losetup", "-d", dev])
    print("Unmounted and released loop devices")


# ----------------------- Benchmarks -----------------------

def adjust_count_to_space(mountpoint: str, per_file_size_bytes: int, desired_count: int):
    st = os.statvfs(mountpoint)
    free = st.f_bavail * st.f_frsize
    safe = int(free * 0.95)
    max_count = safe // per_file_size_bytes
    if max_count < desired_count:
        print(f"Adjusting file count to {max_count} (limited by free space {human(free)})")
        return max_count
    return desired_count


def create_and_write_file(path: str, file_size: int, block_size: int):
    start = time.perf_counter()
    with open(path, 'wb') as f:
        remaining = file_size
        buf = os.urandom(block_size)
        while remaining > 0:
            to_write = min(block_size, remaining)
            f.write(buf[:to_write])
            remaining -= to_write
        f.flush()
        os.fsync(f.fileno())
    return time.perf_counter() - start

def read_file(path: str, block_size: int):
    start = time.perf_counter()
    with open(path, 'rb') as f:
        while f.read(block_size):
            pass
    return time.perf_counter() - start

def run_read_workload(file_paths, block_size: int, threads: int):
    times = []
    with ThreadPoolExecutor(max_workers=threads) as ex:
        futs = {ex.submit(read_file, p, block_size): p for p in file_paths}
        for fut in as_completed(futs):
            try:
                t = fut.result()
            except Exception as e:
                print("Read worker failed:", e)
                t = None
            times.append(t)
    total = sum(t for t in times if t)
    return total, times


def run_write_workload(mountpoint: str, dest_dir: str, file_count: int, per_file_size: int, block_size: int, threads: int):
    Path(dest_dir).mkdir(parents=True, exist_ok=True)
    names = [os.path.join(dest_dir, f"f_{i}.dat") for i in range(file_count)]
    times = []
    with ThreadPoolExecutor(max_workers=threads) as ex:
        futs = {ex.submit(create_and_write_file, n, per_file_size, block_size): n for n in names}
        for fut in as_completed(futs):
            try:
                t = fut.result()
            except Exception as e:
                print("Worker failed:", e)
                t = None
            times.append(t)
    total = sum(t for t in times if t)
    return total, times


def prepare_xattr_files(mountpoint: str, workdir: str, count: int):
    d = Path(mountpoint) / workdir
    d.mkdir(parents=True, exist_ok=True)
    for i in range(count):
        p = d / f"x_{i}.dat"
        with open(p, 'wb', os.O_RDWR | os.O_SYNC) as f:
            f.write(b'0')
    return d


def benchmark_xattr_set_get(files_dir: Path, attr_sizes: list, iterations: int = 10000):
    """
    Benchmark extended attribute set/get performance using the xattr library with file descriptors.
    Each test averages the time to set and get an xattr of a given size across multiple files.
    """

    files = list(files_dir.glob('x_*.dat'))
    if len(files) == 0:
        raise RuntimeError(f"No files found in {files_dir}")
    if len(files) < iterations:
        iterations = len(files)
        print(f"Reduced iterations to {iterations} due to file availability.")

    results = []
    name = b"user.bench"

    for size in attr_sizes:
        print(f"\nBenchmarking xattr size = {size} bytes ...")

        vals = [os.urandom(size) for _ in range(iterations)]
        total_set = total_get = 0.0

        # Warmup: avoid cold start effects
        with open(files[0], "rb+") as f:
            fd = f.fileno()
            for _ in range(50):
                xattr.setxattr(fd, name, b"x" * size)
                _ = xattr.getxattr(fd, name)

        for i in range(iterations):
            p = files[i % len(files)]
            val = vals[i]

            with open(p, "rb+") as f:
                fd = f.fileno()

                # Measure setxattr
                t1 = time.perf_counter_ns()
                xattr.setxattr(fd, name, val)
                # os.fsync(fd) 
                t2 = time.perf_counter_ns()
                total_set += (t2 - t1)

                # Measure getxattr
                t3 = time.perf_counter_ns()
                _ = xattr.getxattr(fd, name)
                t4 = time.perf_counter_ns()
                total_get += (t4 - t3)

        avg_set_us = (total_set / iterations) / 1000.0
        avg_get_us = (total_get / iterations) / 1000.0
        results.append((size, avg_set_us, avg_get_us))

        print(f"attr_size={size:5d} B  avg_set={avg_set_us:8.3f} µs  avg_get={avg_get_us:8.3f} µs")

    return results

# ----------------------- CLI -----------------------

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument('--image', default='xfs_loop.img')
    p.add_argument('--image-size-gb', type=int, default=5)
    p.add_argument('--prepare', action='store_true')
    p.add_argument('--mount', action='store_true')
    p.add_argument('--unmount', action='store_true')
    p.add_argument('--mountpoint', default='/mnt/xfsbench')
    p.add_argument('--run-all', action='store_true')
    p.add_argument('--force', action='store_true')
    return p.parse_args()


# ----------------------- Main -----------------------

if __name__ == '__main__':
    args = parse_args()

    if args.prepare:
        prepare_image(args.image, args.image_size_gb, force=args.force)
        sys.exit(0)

    if args.mount:
        mount_image(args.image, args.mountpoint)
        sys.exit(0)

    if args.unmount:
        unmount_image(args.mountpoint, args.image)
        sys.exit(0)

    if args.run_all:
        mp = args.mountpoint

        print("\n============================")
        print("  FILE WRITE BENCHMARKS")
        print("============================\n")

        per_file_sizes = [
            4*1024,        # 4 KB
            16*1024,       # 16 KB
            64*1024,       # 64 KB
            256*1024,      # 256 KB
            1024*1024,     # 1 MB
            2*1024*1024,   # 2 MB
            4*1024*1024,   # 4 MB
            8*1024*1024    # 8 MB
        ]
        
        block_size = 4*1024
        target_files = 1000
        threads = 1

        results = []

        for per_size in per_file_sizes:
            desired_count = target_files
            actual_count = adjust_count_to_space(mp, per_size, desired_count)
            if actual_count == 0:
                print(f"Skipping: no space for {per_size} B files.")
                continue

            dest_dir = f'write_{per_size}'
            print(f"\n--- Testing {human_readable_size(per_size)} files (count={actual_count}) ---")

            # WRITE BENCHMARK
            write_start = time.perf_counter()
            total_write, write_times = run_write_workload(mp, dest_dir, actual_count, per_size, block_size, threads)
            write_wall = time.perf_counter() - write_start
            avg_write_sec = sum(write_times)/len(write_times)
            avg_write_us = avg_write_sec * 1e6
            write_mbps = (per_size / (1024*1024)) / avg_write_sec

            # READ BENCHMARK
            file_paths = [os.path.join(dest_dir, f"f_{i}.dat") for i in range(actual_count)]
            read_start = time.perf_counter()
            total_read, read_times = run_read_workload(file_paths, block_size, threads)
            read_wall = time.perf_counter() - read_start
            avg_read_sec = sum(read_times)/len(read_times)
            avg_read_us = avg_read_sec * 1e6
            read_mbps = (per_size / (1024*1024)) / avg_read_sec

            results.append((per_size, avg_write_us, write_mbps, avg_read_us, read_mbps))

        # Print final table
        print("\n")
        print("Size          Write (us)   Write (MB/s)   Read (us)    Read (MB/s)")
        print("-" * 78)
        for size, w_us, w_mbps, r_us, r_mbps in results:
            size_str = human_readable_size(size)
            print(f"{size_str:12s}  {w_us:10.2f}   {w_mbps:12.2f}   {r_us:10.2f}   {r_mbps:12.2f}")
        print("-" * 78)
        print("Benchmarks completed successfully.\n")

        print("\n============================")
        print("  XATTR BENCHMARKS")
        print("============================\n")

        attr_sizes = [8, 16, 32, 64, 128, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
        iterations = 20000
        files_dir = prepare_xattr_files(mp, 'xattr_files', iterations)
        benchmark_xattr_set_get(files_dir, attr_sizes, iterations)

        print("\nAll benchmarks completed.\n")

    if not (args.prepare or args.mount or args.unmount or args.run_all):
        print('No action requested. Use --prepare, --mount, --unmount or --run-all.')