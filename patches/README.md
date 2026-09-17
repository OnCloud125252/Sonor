# Sonor patches to sonor.cpp

`sonor.cpp` is a vendored copy of [whisper.cpp](https://github.com/ggml-org/whisper.cpp), renamed from `whisper` to `sonor`.

Base snapshot: **`8384aa8086714d6177f24eb5c409b39949efd2ce`** (2026-05-02).

Every file in `sonor.cpp` matches that snapshot, except the two files listed here.
These patches are the only code Sonor owns in the vendored tree.

## Patches

### `0001-ggml-metal-macos-compile-fixes.patch`

Target: `sonor.cpp/ggml/src/ggml-metal/ggml-metal.metal`

The Xcode Metal compiler rejects two upstream patterns.

1. `const device const float *` repeats `const`. Drop the second one.
2. `bilinear_tri` is never called. An unused static function fails the build.

Without this patch the Metal shader library does not compile.

### `0002-ggml-metal-device-idle-and-availability.patch`

Target: `sonor.cpp/ggml/src/ggml-metal/ggml-metal-device.m`

Two changes.

**Idle heartbeat.** Upstream runs a background thread that calls `usleep(500 * 1000)` forever.
That thread wakes twice a second for the whole life of the process, even with no work to do.
Sonor sits in the menu bar all day, so this drains the battery.
The patch adds a `dispatch_semaphore_t`.
The thread parks on `DISPATCH_TIME_FOREVER` once it goes idle, and a signal wakes it when work arrives.

**Class availability.** `MTLResidencySetDescriptor` arrived in macOS 15.0.
Sonor deploys to macOS 14.6.
A direct class reference makes the linker bind the symbol, which breaks the older system.
The patch looks the class up with `NSClassFromString` and sets its properties through key-value coding.

## How to re-vendor

1. Check out the target whisper.cpp commit.
2. Copy the tree into `sonor.cpp/`.
3. Rename `whisper` to `sonor`, `WHISPER` to `SONOR`, and `Whisper` to `Sonor`, in both paths and file contents.
4. Run `git apply patches/*.patch` from the repository root.
5. Update the base snapshot hash in this file.

## How to verify the patches still match

```bash
git apply --check --reverse patches/*.patch
```

A clean exit means the working tree carries exactly these changes.
