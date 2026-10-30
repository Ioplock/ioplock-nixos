{ self, inputs, ... }:
{
  flake.nixosModules.modioSplit =
    { config, lib, ... }:
    let
      cfg = config.myModioSplit;
    in
    {
      options.myModioSplit = {
        enable = lib.mkEnableOption "TUN split-routing only for mod.io/modapi.io (e.g. Transport Fever 3 Mod Center via Proton)";

        tunTag = lib.mkOption {
          type = lib.types.str;
          default = "tun-in";
          description = "Tag of the TUN inbound. Referenced by the tun catch-all route rule.";
        };

        interfaceName = lib.mkOption {
          type = lib.types.str;
          default = "tun0";
          description = "Name of the TUN device created by sing-box.";
        };

        tunAddress = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "172.19.0.1/30"
            "fdfe:dcba:9876::1/126"
          ];
          description = ''
            Prefixes assigned to the TUN interface. IPv4 covers game traffic;
            the ULA IPv6 prefix prevents IPv6 leaks bypassing the TUN.
          '';
        };

        mtu = lib.mkOption {
          type = lib.types.int;
          default = 9000;
          description = "MTU of the TUN interface (sing-box docs example).";
        };

        domainSuffixes = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "mod.io"
            "modapi.io"
            "modcdn.io"
          ];
          description = ''
            Domains routed through the secret `proxy` outbound.
            Covers mod.io portal, per-game g-*.modapi.io API and mod CDN
            binary_url downloads (legacy api.mod.io included via mod.io suffix).
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        # Dependent on flake.nixosModules.singBox: the host must import both.
        # NixOS merges services.sing-box.settings across modules; lists
        # (inbounds, rules) concatenate, so this only appends.
        services.sing-box.settings = {
          inbounds = [
            {
              type = "tun";
              tag = cfg.tunTag;
              interface_name = cfg.interfaceName;
              address = cfg.tunAddress;
              mtu = cfg.mtu;
              auto_route = true;
              strict_route = true;
              # Explicit stack for sing-box 1.14 (nixpkgs pins 1.14.1 here).
              # Upstream deprecates `stack` in 1.15 (removal in 1.17) in favour
              # of the built-in sing-tun stack; drop this line once nixpkgs
              # moves past 1.15. Custom mySingBox already builds with_gvisor.
              stack = "gvisor";
            }
          ];

          # mkBefore: sing-box uses first-match-wins. Sniff must run before
          # any domain_suffix match (non-final action: evaluation continues).
          # Legacy inbound `sniff` fields were removed in sing-box 1.13;
          # the migration replaces them with this rule action.
          route.rules = lib.mkBefore [
            {
              inbound = [ cfg.tunTag ];
              action = "sniff";
            }
            {
              domain_suffix = cfg.domainSuffixes;
              outbound = "proxy";
            }
            {
              inbound = [ cfg.tunTag ];
              outbound = "direct";
            }
          ];

          # Explicit so mod DNS keeps going via DoH-through-proxy even if the
          # base module ever changes its DNS final. geohide-dns is defined in
          # flake.nixosModules.singBox and resolved/dialed via `proxy`.
          dns.rules = lib.mkBefore [
            {
              domain_suffix = cfg.domainSuffixes;
              server = "geohide-dns";
            }
          ];
        };
      };
    };
}
