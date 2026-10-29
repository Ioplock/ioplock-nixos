{ self, ... }:
{
  # zapret2 (nfqws2) DPI bypass, driven by strategies maintained in the
  # private zapret-cfg repo (verified on Hl_telecom.K14 / 2026-10-15).
  #
  # Strategies, domain lists and blobs are private: they never appear in the
  # Nix store, the systemd unit file, or this (public) repo as plain text.
  # They live in an sops-encrypted secrets/zapret.json and are decrypted to
  # /run/secrets at runtime only.
  #
  # nfqws2 expands an @file given as argv[1] into the ENTIRE command line and
  # ignores any other arguments. Public module-generated arguments
  # (--qnum, --fwmark, --lua-init) plus the decrypted strategies must
  # therefore be merged into one runtime file. That is what the myNfqws2
  # wrapper does: it is set as services.zapret2.package, so the module builds
  # its normal ExecStart against it, and the wrapper appends the decrypted
  # strategies before exec'ing the real nfqws2.
  #
  # Keep the secret key names below in sync with packages.myZapretImport and
  # with the "=lists/..." path mapping it writes into the strategies.

  perSystem =
    { pkgs, lib, ... }:
    {
      # Re-encrypt secrets/zapret.json from a zapret-cfg checkout:
      #   nix run .#myZapretImport -- /path/to/zapret-cfg
      # zapret-cfg stays the source of truth; re-run after changing
      # config/strategies.conf, lists/*.txt or blobs/*.bin there.
      packages.myZapretImport = pkgs.writeShellApplication {
        name = "zapret-import";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.jq
          pkgs.sops
          pkgs.ssh-to-age
          pkgs.openssh
          pkgs.git
        ];

        text = ''
          fail() { echo "ERROR: $*" >&2; exit 1; }

          [ $# -ge 1 ] || fail 'pass the zapret-cfg checkout: nix run .#myZapretImport -- /path/to/zapret-cfg'
          SRC=$1

          cd "$(git rev-parse --show-toplevel)" || fail 'not run from inside this repo'
          [ -d "$SRC" ] || fail "not a directory: $SRC"
          STRAT="$SRC/config/strategies.conf"
          BLOBS="$SRC/blobs"
          LISTS="$SRC/lists"
          [ -r "$STRAT" ] || fail "missing $STRAT"

          for f in targets list-google list-discord list-cloudflare list-exclude ipset-discord ipset-cloudflare ipset-exclude; do
            [ -s "$LISTS/$f.txt" ] || fail "missing or empty $LISTS/$f.txt"
          done
          for f in tls_clienthello_www_google_com.bin quic_initial_www_google_com.bin; do
            [ -r "$BLOBS/$f" ] || fail "missing $BLOBS/$f"
          done

          # Strategy lines are recombined into a single wordexp-parsed command
          # line at runtime. WRDE_NOCMD makes command substitution fail the
          # whole parse, variable expansion would happen silently, and globs
          # would try to match files in the service CWD. Reject all of these
          # up front instead of producing a service that cannot start.
          if grep -E '[$`]|[[:space:]](\*|\[|\?)' "$STRAT"; then
            fail 'strategies contain characters unsafe for nfqws2 config parsing (dollar, backtick, unquoted glob)'
          fi

          # Transform strategies.conf:
          #   - drop --lua-init lines (provided by services.zapret2.files)
          #   - --blob=<name>:@blobs/<file>.bin -> --blob=<name>:0x<hex>
          #     (hex keeps the secret self-contained; no store paths involved)
          #   - =lists/<file>.txt -> =/run/secrets/zapret-<file-without-.txt>
          STRAT_OUT="$(
            while IFS= read -r line; do
              case "$line" in
                --lua-init=*) continue ;;
                --blob=*)
                  rest="''${line#--blob=}"
                  name="''${rest%%:*}"
                  file="''${rest#*:}"
                  file="''${file#@}"
                  file="''${file#blobs/}"
                  [ -r "$BLOBS/$file" ] || fail "blob file missing: $BLOBS/$file"
                  printf '%s\n' "--blob=$name:0x$(od -An -tx1 -v "$BLOBS/$file" | tr -d ' \n')"
                  ;;
                *)
                  printf '%s\n' "$(printf '%s' "$line" | sed 's|=lists/\([a-z0-9-]*\)\.txt|=/run/secrets/zapret-\1|g')"
                  ;;
              esac
            done < "$STRAT"
          )"
          [ -n "$STRAT_OUT" ] || fail 'strategies transform produced nothing'

          # Derive the age decryption key the same way sops-edit does, so
          # sops can encrypt straight away without a user-managed key.
          SSH_KEY=/etc/ssh/ssh_host_ed25519_key
          KEY_DIR="''${XDG_CONFIG_HOME:-$HOME/.config}/sops/age"
          KEY_FILE="$KEY_DIR/keys.txt"
          if [ ! -f "$KEY_FILE" ]; then
            mkdir -p "$KEY_DIR"
            chmod 700 "$KEY_DIR"
            if [ -r "$SSH_KEY" ]; then
              ssh-to-age -private-key -i "$SSH_KEY" > "$KEY_FILE"
            else
              fail "no age key at $KEY_FILE and $SSH_KEY is not readable; run nix run .#sops-edit once to generate it"
            fi
          fi
          chmod 600 "$KEY_FILE"

          # Write the decrypted plaintext to a temporary file under secrets/
          # so the .sops.yaml creation rule (secrets/.*\.json$) matches, then
          # encrypt in place and atomically move it over the real secret.
          # The committed path never holds plaintext.
          mkdir -p secrets
          TMP="$(mktemp secrets/.zapret-import.XXXXXX.json)"
          trap 'rm -f "$TMP"' EXIT

          jq -n \
            --arg strategies "$STRAT_OUT" \
            --rawfile targets "$LISTS/targets.txt" \
            --rawfile lgoogle "$LISTS/list-google.txt" \
            --rawfile ldiscord "$LISTS/list-discord.txt" \
            --rawfile lcloudflare "$LISTS/list-cloudflare.txt" \
            --rawfile lexclude "$LISTS/list-exclude.txt" \
            --rawfile idiscord "$LISTS/ipset-discord.txt" \
            --rawfile icloudflare "$LISTS/ipset-cloudflare.txt" \
            --rawfile iexclude "$LISTS/ipset-exclude.txt" \
            '{
              "zapret-strategies": $strategies,
              "zapret-targets": $targets,
              "zapret-list-google": $lgoogle,
              "zapret-list-discord": $ldiscord,
              "zapret-list-cloudflare": $lcloudflare,
              "zapret-list-exclude": $lexclude,
              "zapret-ipset-discord": $idiscord,
              "zapret-ipset-cloudflare": $icloudflare,
              "zapret-ipset-exclude": $iexclude
            }' > "$TMP"

          SOPS_AGE_KEY_FILE="$KEY_FILE" sops --encrypt --input-type json --output-type json -i "$TMP"
          mv "$TMP" secrets/zapret.json
          trap - EXIT

          echo 'secrets/zapret.json updated (strategies + 8 lists).'
          echo 'Next: nix flake check && nixos-rebuild dry-build --flake .#<host>'
        '';
      };

      # Wraps services.zapret2's generated ExecStart. Clears the module
      # arguments into a runtime file, appends the decrypted strategies and
      # execs nfqws2 with @file as argv[1]. Temp files land in the unit's
      # private /tmp (base unit sets PrivateTmp and UMask=0077).
      packages.myNfqws2 = pkgs.writeShellApplication {
        name = "nfqws2-wrapper";
        runtimeInputs = [ pkgs.coreutils ];
        meta.mainProgram = "nfqws2-wrapper";

        text = ''
          NFQWS2=${pkgs.zapret2}/bin/nfqws2

          : "''${ZAPRET_STRATEGIES:?ZAPRET_STRATEGIES is not set}"
          [ -r "$ZAPRET_STRATEGIES" ] || { echo "ERROR: cannot read strategies file: $ZAPRET_STRATEGIES" >&2; exit 1; }

          CMD=$(mktemp)
          { printf '%s\n' "$@"; cat "$ZAPRET_STRATEGIES"; } > "$CMD"

          CHECK=$(mktemp)
          { printf '%s\n' --dry-run; cat "$CMD"; } > "$CHECK"
          "$NFQWS2" @"$CHECK"

          # Same second check zapret-cfg's start.sh runs: initialises the Lua
          # environment. Needs capabilities; the unit provides them.
          INIT=$(mktemp)
          { printf '%s\n' --intercept=0; cat "$CMD"; } > "$INIT"
          "$NFQWS2" @"$INIT"

          exec "$NFQWS2" @"$CMD"
        '';
      };
    };

  flake.nixosModules.zapret =
    { config, pkgs, lib, ... }:
    {
      # Static system user so the service can read 0400 secrets via owner
      # match (sops-nix cannot chown to a systemd DynamicUser).
      users.groups.zapret2 = { };
      users.users.zapret2 = {
        isSystemUser = true;
        group = "zapret2";
      };

      sops.secrets = lib.genAttrs
        [
          "zapret-strategies"
          "zapret-targets"
          "zapret-list-google"
          "zapret-list-discord"
          "zapret-list-cloudflare"
          "zapret-list-exclude"
          "zapret-ipset-discord"
          "zapret-ipset-cloudflare"
          "zapret-ipset-exclude"
        ]
        (_: {
          sopsFile = ./../../secrets/zapret.json;
          format = "json";
          owner = "zapret2";
          restartUnits = [ "nfqws2@default.service" ];
        });

      services.zapret2 = {
        enable = true;
        # The wrapper stands in for the package: the module puts lib.getExe of
        # it into ExecStart. Consequences handled below:
        #   - systemd.packages gets the real package (for the unit file)
        #   - files gets absolute store paths (default names would resolve
        #     against the wrapper, which has no share/zapret2)
        package = self.packages.${pkgs.stdenv.hostPlatform.system}.myNfqws2;

        files = [
          "${pkgs.zapret2}/share/zapret2/lua/zapret-lib.lua"
          "${pkgs.zapret2}/share/zapret2/lua/zapret-antidpi.lua"
        ];

        firewall = {
          tcpPorts = [
            80
            443
            2053
            2083
            2087
            2096
            8443
          ];
          # module type cannot express the Discord voice port ranges
          # (19294-19344, 50000-65535); route all UDP instead — matches the
          # superset of zapret-cfg's verified nft rules
          udpPorts = null;
          maxPackets = 12; # zapret-cfg intercepts 1-12 packets (module default 16)
          queue = 200; # config/linux.header
          desyncFwmark = "0x40000000"; # config/linux.header
        };

        # profiles stay empty on purpose: the strategies are private data and
        # would end up verbatim in the world-readable unit file. They arrive
        # at runtime through the wrapper instead.
      };

      # Compensate for package being the unit-less wrapper (the module itself
      # already adds systemd.packages = [cfg.package]).
      systemd.packages = [ pkgs.zapret2 ];

      systemd.services."nfqws2@default" = {
        after = [ "sops-install-secrets.service" ];
        environment.ZAPRET_STRATEGIES = config.sops.secrets.zapret-strategies.path;
        serviceConfig = {
          DynamicUser = lib.mkForce false;
          User = "zapret2";
          Group = "zapret2";
        };
      };

      boot.kernel.sysctl = {
        # The generated nftables rules match `ct original packets 1-12`, which
        # only counts when conntrack accounting is enabled (zapret-cfg's
        # start.sh turned it on for the same reason).
        "net.netfilter.nf_conntrack_acct" = true;
      };
    };
}
