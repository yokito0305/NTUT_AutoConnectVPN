# OpenConnect Fork Build

This directory owns the reproducible build and release scaffolding for the
patched OpenConnect Windows runtime used by this project.

## Source Of Truth

- Canonical upstream: `https://gitlab.com/openconnect/openconnect`
- Maintained fork: `https://gitlab.com/yokito0305/openconnect.git`
- Submodule path: `third_party/openconnect`

The submodule commit pinned in the main repository is the only approved source
for CI and release builds.

## Scope

This build pipeline exists to produce a patched Windows OpenConnect runtime
which exposes HTTP response bodies for `--dump-http-traffic` so the main
project can capture XML config documents reliably.

Windows builds in this repository currently add `--disable-nls` to the
configure step. This keeps `libintl` out of the runtime while the new
`openconnect.exe` startup path is being stabilized.

Non-goals for this phase:

- XML field extraction
- `vpnc-script` behavioral fixes
- route or DNS policy changes
- installer UX changes

## Official Build Paths

### GitHub Actions release build

Use `.github/workflows/openconnect-build.yml` to build the pinned submodule on a
Linux runner with a Fedora container and MinGW cross toolchain.

The workflow stages artifacts into `out/openconnect-win64/` and uploads that
directory as the official build artifact.

### Local debug build

Use one of the following:

- `third_party/openconnect-build/build-openconnect-win64.sh` inside Linux, WSL,
  or a Fedora container
- `third_party/openconnect-build/build-openconnect-win64.ps1` on Windows, which
  ensures a reusable local build image exists and then runs the same shell
  build inside that container

The local Windows wrapper uses the repo-owned Dockerfile:

- `third_party/openconnect-build/Dockerfile.mingw64`

Default local image tag:

- `ntut-autovpn/openconnect-build:fedora42-mingw64`

Local builds are for validation only. They must not be treated as the official
release source.

To force a rebuild of the local image:

```powershell
third_party/openconnect-build/build-openconnect-win64.ps1 -RebuildImage
```

## Staging Rules

- Local and CI builds write to `out/openconnect-win64/`
- `bin/` remains the runtime/release layout consumed by the PowerShell service
- Promotion into `bin/` or a release archive is an explicit separate step

## Validation Target

After replacing `bin/openconnect.exe` and its dependent DLLs with the built
runtime, run one diagnostic session with:

- `Config_OpenConnectVerbose = 3`
- `Config_OpenConnectDumpHttpTraffic = $true`

Success means:

- `vpn_openconnect_http_body_dump.log` is created
- `vpn_state.json` reports `http_config_capture_status = body_captured`

If the runtime still reports `headers_only`, the fork patch is incomplete and
XML parsing must remain blocked.
