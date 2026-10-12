# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Dependencies fetched from git instead of sibling checkouts** — zigmodu
  **v0.39.11** and zent **v0.91.0** are now `.url` + `.hash` entries in
  `build.zig.zon` (tagged tarballs), replacing `.path` entries that pointed at
  `../../../zig_ws/*`. `zig build` clones and unpacks them into `zig-pkg/`, so
  the build no longer depends on a particular directory layout around the
  repository. CI, release and the Dockerfile drop their "recreate the sibling
  dependency layout" steps and their `ZIGMODU_SHA` / `ZENT_SHA` pins, which
  were still naming v0.39.6 / v0.83.0 and are now redundant with the manifest
  hashes; `zig-pkg/` is gitignored and was already in `.dockerignore`.
