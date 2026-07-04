{ self, inputs, ... }:
{
  flake.nixosModules.sops =
    { config, ... }:
    {
      imports = [ inputs.sops-nix.nixosModules.sops ];

      # Derive the age decryption key from the host's SSH ed25519 key.
      # ssh-to-age conversion happens automatically inside sops-nix at
      # activation time — no separate age key file needed.
      sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

      sops.defaultSopsFile = ./../../secrets/sing-box-outbounds.json;
      sops.defaultSopsFormat = "json";

      # key = "" emits the whole decrypted JSON document as the secret file
      # (instead of extracting a single top-level key). sing-box consumes
      # the full {"outbounds": [...]} blob via ExecStartPre.
      sops.secrets.sing-box-outbounds = {
        key = "";
        restartUnits = [ "sing-box.service" ];
      };
    };

  perSystem =
    { pkgs, ... }:
    {
      # Helper to derive the age recipient (public key) from the host's
      # SSH ed25519 public key and write it into .sops.yaml.
      # Run once after first boot, from the repo root:
      #   nix run .#sops-init-recipient
      # Then re-encrypt the secret with real values:
      #   nix shell nixpkgs#sops -- sops secrets/sing-box-outbounds.json
      packages.sops-init-recipient = pkgs.writeShellApplication {
        name = "sops-init-recipient";
        runtimeInputs = [
          pkgs.openssh
          pkgs.ssh-to-age
          pkgs.gnused
          pkgs.git
        ];
        text = ''
          set -euo pipefail

          # Always operate from the repo root so paths resolve regardless of CWD.
          cd "$(git rev-parse --show-toplevel)"

          SSH_PUB="/etc/ssh/ssh_host_ed25519_key.pub"
          SOPS_YAML="''${1:-.sops.yaml}"

          if [ ! -f "$SSH_PUB" ]; then
            echo "ERROR: $SSH_PUB not found. Is openssh enabled on this host?" >&2
            exit 1
          fi
          if [ ! -f "$SOPS_YAML" ]; then
            echo "ERROR: $SOPS_YAML not found." >&2
            exit 1
          fi
          if [ ! -w "$SOPS_YAML" ]; then
            echo "ERROR: $SOPS_YAML is not writable." >&2
            exit 1
          fi

          RECIPIENT="$(ssh-to-age < "$SSH_PUB")"
          if [ -z "$RECIPIENT" ]; then
            echo "ERROR: ssh-to-age produced an empty recipient." >&2
            exit 1
          fi

          echo "Derived age recipient: $RECIPIENT"

          if ! grep -q 'age1PLACEHOLDER_REPLACE_VIA_sops-init-recipient' "$SOPS_YAML"; then
            echo "ERROR: placeholder not found in $SOPS_YAML." >&2
            echo "       It looks like .sops.yaml was already updated." >&2
            exit 1
          fi

          sed -i "s|age1PLACEHOLDER_REPLACE_VIA_sops-init-recipient|$RECIPIENT|g" "$SOPS_YAML"
          echo "Updated $SOPS_YAML with the host's age recipient."
          echo ""
          echo "Next steps:"
          echo "  1. Re-encrypt the secret with real outbound values:"
          echo "     nix run .#sops-edit -- --reset secrets/sing-box-outbounds.json"
          echo "  2. Deploy (the user decides when to switch)."
        '';
      };

      # Drop-in replacement for the `sops` CLI that derives the age private
      # key from the host's SSH ed25519 key at runtime, so you don't have to
      # manage SOPS_AGE_KEY_FILE by hand.
      #   nix run .#sops-edit -- secrets/sing-box-outbounds.json
      # If the target file is the bootstrap placeholder (encrypted with a
      # throwaway key the host can't decrypt), pass --reset to wipe it and
      # start from the tracked example.
      packages.sops-edit = pkgs.writeShellApplication {
        name = "sops-edit";
        runtimeInputs = [
          pkgs.openssh
          pkgs.ssh-to-age
          pkgs.sops
          pkgs.coreutils
          pkgs.git
        ];
        text = ''
          set -euo pipefail

          # Always operate from the repo root so paths resolve regardless of CWD.
          cd "$(git rev-parse --show-toplevel)"

          SSH_KEY="/etc/ssh/ssh_host_ed25519_key"
          RESET=0
          ARGS=()
          for a in "$@"; do
            if [ "$a" = "--reset" ]; then
              RESET=1
            else
              ARGS+=("$a")
            fi
          done

          if [ ! -f "$SSH_KEY" ]; then
            echo "ERROR: $SSH_KEY not found." >&2
            exit 1
          fi

          KEY_DIR="''${XDG_CONFIG_HOME:-$HOME/.config}/sops/age"
          KEY_FILE="$KEY_DIR/keys.txt"
          mkdir -p "$KEY_DIR"
          chmod 700 "$KEY_DIR"

          # The host SSH private key is root-only; fall back to the system
          # setuid sudo (NixOS: /run/wrappers/bin/sudo) to read it.
          if [ -r "$SSH_KEY" ]; then
            ssh-to-age -private-key -i "$SSH_KEY" > "$KEY_FILE"
          else
            SUDO="$(command -v sudo || true)"
            if [ -z "$SUDO" ]; then
              echo "ERROR: sudo not found and $SSH_KEY is not readable as $(id -un)." >&2
              exit 1
            fi
            echo "Host SSH key not readable as $(id -un); using $SUDO to convert it." >&2
            "$SUDO" ssh-to-age -private-key -i "$SSH_KEY" | tee "$KEY_FILE" >/dev/null
          fi
          chmod 600 "$KEY_FILE"

          if [ "$RESET" -eq 1 ] && [ "''${#ARGS[@]}" -ge 1 ]; then
            TARGET="''${ARGS[-1]}"
            if [ ! -f "''${TARGET}.example" ]; then
              echo "ERROR: ''${TARGET}.example not found." >&2
              exit 1
            fi
            echo "Resetting $TARGET — copying from the example and encrypting fresh."
            cp "''${TARGET}.example" "$TARGET"
            SOPS_AGE_KEY_FILE="$KEY_FILE" sops -e -i "$TARGET"
            echo "Encrypted. Now edit with real values:"
            echo "  nix run .#sops-edit -- $TARGET"
            exit 0
          fi

          export SOPS_AGE_KEY_FILE="$KEY_FILE"
          exec sops "''${ARGS[@]}"
        '';
      };
    };
}
