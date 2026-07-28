# Secure Hibernate Manager

This directory contains the future Electron and React desktop manager. The
manager will provide installation, system inspection, update, diagnostics, and
recovery workflows for the secure hibernation kernel.

The first implementation should use a mocked, typed system backend. It must not
execute privileged commands until the maintenance CLI and its state transitions
have been validated independently.

The current code is a Vite and React UI prototype imported from Google AI
Studio. It contains no Gemini integration, network requests, shell execution,
Electron runtime, or privileged helper.

## Development

```sh
pnpm install
pnpm dev
```

The development server listens on `http://127.0.0.1:3000/`. Press `Ctrl+C` to
stop Vite cleanly.

Run `pnpm typecheck` and `pnpm build` before committing UI changes.

## Intended boundaries

- `src/main/`: Electron main process and fixed privileged-helper invocation.
- `src/preload/`: narrow, typed IPC bridge exposed to the renderer.
- `src/renderer/`: current React user interface.
- `src/shared/`: current state types and future IPC contracts.
- `src/mock/`: deterministic system states for UI development and testing.

Electron must run as the desktop user. Operations requiring root privileges
must use fixed helper subcommands through `pkexec`; the renderer must never
construct or execute shell commands.
