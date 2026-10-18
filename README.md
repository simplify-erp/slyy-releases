# Slyy Desktop -- Releases

Downloads for Slyy Desktop (formerly NOCA), the natural-language interface
to Odoo ERP. This repository holds only release artefacts; the source is
private. https://slyy.ai

- Latest version: https://github.com/simplify-erp/slyy-releases/releases/latest
- Requires macOS 14 or newer (Apple Silicon).
- The app checks this repository for updates and installs them on one click.
  Every DMG is signed; the app verifies the signature before installing.
- Installations of NOCA 4.10.7 or newer move here by themselves with the
  next update; older ones update to 4.10.7 first from
  https://github.com/simplify-erp/noca-releases.

## slyy CLI (terminal agent, Linux + macOS)

One command installs the newest `slyy` CLI (arm64 + amd64; checksum verified, no sudo,
to `~/.local/bin`):

    curl -fsSL https://raw.githubusercontent.com/simplify-erp/slyy-releases/main/install.sh | sh

Then open a new terminal and run `slyy`. Updates: `slyy update`. CLI releases are the
`slyy-cli-v*` tags (the "Latest" badge stays with Slyy Desktop).

## Installation

1. Download the DMG from the latest release and drag "Slyy Desktop.app" to
   Applications.
2. First launch: macOS reports the developer cannot be verified (the build is
   not yet notarized). Allow it once under System Settings > Privacy &
   Security ("Open Anyway"), then launch Slyy Desktop again.
3. Enter your Odoo instance (https URL, database, user, API key) in the
   setup overlay.

Deutsch: siehe LIESMICH.txt im DMG.
