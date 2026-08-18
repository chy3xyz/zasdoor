# Contributing to Zasdoor

Thanks for taking the time to contribute! This project follows a small set of
conventions to keep reviews fast and the codebase consistent.

## Getting started

1. Fork the repository and create a feature branch from `main`:

   ```bash
   git checkout -b feat/your-change
   ```

2. Make your changes, then verify them locally:

   ```bash
   zig build test
   cd web && npm run typecheck && npm run build
   ```

3. Keep Zig code formatted with `zig fmt .` and frontend code consistent with the
   existing TypeScript style.

4. Open a pull request against `main` with a clear description of the change and
   any related issue number.

## Guidelines

- Follow the module layout for new domains:
  `model` (schema) → `persistence` → `service` → `api` → `module`.
- Register new zent schemas in `src/schema.zig` so migrations and the shared
  client stay in sync.
- Add tests for new backend behavior in `src/tests.zig` (in-memory SQLite is
  available via the `openMemory` helper).
- Keep environment configuration in `src/config.zig` with the `ZASDOOR_` prefix,
  and document it in both `README.md` and `README.zh-CN.md`.

## Report issues

Please use GitHub Issues for bug reports and feature requests. Include the Zig
version, OS, and reproduction steps where possible.
