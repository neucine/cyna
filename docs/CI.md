# Continuous checks

The Cyna Buildkite pipeline runs a quick macOS check by default. Linux and
Windows quick checks are opt-in so an ordinary change does not need every
runner to be awake.

## Run the Linux or Windows check

On a pull request, add one of these labels:

- `ci:linux` runs the Linux quick check.
- `ci:windows` runs the Windows quick check.
- `ci:cross-platform` runs both.

Adding a label starts a Buildkite build for that pull request. The build uses
the pull request's current commit. While the label remains on the pull request,
later builds include the selected platform checks too. Remove the label to
return future builds to macOS only. Create the labels in the repository first
if they are not already available.

For a manual Buildkite build, set the `CYNA_FAST_PLATFORMS` environment
variable to `linux`, `windows`, or `linux,windows`. A plain build without this
variable and without one of the labels runs only the macOS check.

## What each quick check runs

The macOS and Linux jobs run `fast-check.sh`. They build the compiler, run the
repository checks, run `zig build test-fast`, and confirm the compiler version.

The Windows job runs `windows-fast-check.ps1`. It prepares the pinned Windows
tools, builds the compiler, runs `zig build test-fast`, and confirms the
compiler version.

Release branches use the full candidate checks instead of these quick checks.
