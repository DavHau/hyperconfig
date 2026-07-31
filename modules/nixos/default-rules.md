---
alwaysApply: true
---

## NixOS Module Organization

Always create new NixOS features as a separate `.nix` file in `modules/nixos/` and import it where needed.
Do NOT inline new features into existing files.
