# Patch Scope

## Goal

Patch the Windows OpenConnect build so `--dump-http-traffic` emits HTTP
response bodies for XML config endpoints that are currently only reported as
headers plus `HTTP body length`.

## Root Cause

The current response-body dump path in `http.c` uses a C-string oriented helper
that walks until `'\0'`. HTTP bodies should instead be dumped using the actual
buffer length returned by the HTTP layer. This patch is intentionally kept to
the smallest possible change: only response body emission is switched to a
length-aware helper.

The Windows build path currently also configures OpenConnect with
`--disable-nls` as a runtime-stability measure while validating the patched
binary.

Local Windows debug builds now use a repo-owned reusable Docker image so the
runtime can be rebuilt repeatedly without reinstalling the full Fedora MinGW
toolchain on every run.

## Required Endpoints

At minimum, body output must be observable for:

- `/global-protect/prelogin.esp`
- `/global-protect/getconfig.esp`
- `/ssl-vpn/getconfig.esp`

## Acceptance Criteria

- The patched Windows binary causes the main project to create
  `vpn_openconnect_http_body_dump.log`
- At least one captured document is marked `body_captured`
- The main project no longer records
  `xml_capture_blocked_reason = body_not_emitted_by_openconnect`

## Non-Goals

- No XML field extraction in this patch series
- No changes to route or DNS application logic
- No `vpnc-script` functional changes
- No protocol changes unrelated to HTTP dump body visibility
