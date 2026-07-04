{ self, inputs, ... }:
{
  perSystem =
    { pkgs, lib, ... }:
    let
      cronetLibDir = {
        x86_64-linux = "linux_amd64";
        aarch64-linux = "linux_arm64";
      }.${pkgs.stdenv.hostPlatform.system} or null;
    in
    {
      # Custom sing-box build with naive outbound support and purego (cronet).
      # No naive outbound is wired into the config here — this just keeps the
      # build tags and bundled libcronet.so available for later use.
      packages.mySingBox = pkgs.sing-box.overrideAttrs (old: {
        tags = lib.unique ((old.tags or [ ]) ++ [
          "with_naive_outbound"
          "with_purego"
        ]);

        postInstall = (old.postInstall or "") + lib.optionalString (cronetLibDir != null) ''
          install -Dm755 \
            ${old.goModules}/github.com/sagernet/cronet-go/lib/${cronetLibDir}/libcronet.so \
            $out/bin/libcronet.so
        '';
      });
    };

  flake.nixosModules.singBox =
    { config, pkgs, lib, ... }:
    {
      services.sing-box = {
        enable = true;
        package = self.packages.${pkgs.stdenv.hostPlatform.system}.mySingBox;

        settings = {
          log = {
            level = "info";
            timestamp = true;
          };

          dns = {
            servers = [
              {
                tag = "remote-dns";
                type = "tls";
                server = "8.8.8.8";
                detour = "proxy";
              }
              {
                tag = "local-dns";
                type = "https";
                server = "1.1.1.1";
              }
            ];
            rules = [
              {
                domain_suffix = [
                  ".ru"
                  ".su"
                  ".рф"
                ];
                server = "local-dns";
              }
              {
                rule_set = [
                  "geoip-ru"
                  "geosite-ru"
                ];
                server = "local-dns";
              }
            ];
            final = "remote-dns";
          };

          inbounds = [
            {
              type = "socks";
              tag = "socks-in";
              listen = "127.0.0.1";
              listen_port = 1080;
            }
            {
              type = "http";
              tag = "http-in";
              listen = "127.0.0.1";
              listen_port = 8080;
            }
          ];

          route = {
            default_domain_resolver = {
              server = "local-dns";
              strategy = "ipv4_only";
            };
            rule_set = [
              {
                tag = "geoip-ru";
                type = "remote";
                format = "binary";
                url = "https://github.com/SagerNet/sing-geoip/raw/rule-set/geoip-ru.srs";
                download_detour = "direct";
              }
              {
                tag = "geosite-ru";
                type = "remote";
                format = "binary";
                url = "https://github.com/SagerNet/sing-geosite/raw/rule-set/geosite-category-ru.srs";
                download_detour = "direct";
              }
            ];
            rules = [
              {
                domain_suffix = [
                  ".ru"
                  ".su"
                  ".рф"
                ];
                outbound = "direct";
              }
              {
                rule_set = [
                  "geoip-ru"
                  "geosite-ru"
                ];
                outbound = "direct";
              }
            ];
            auto_detect_interface = true;
            final = "proxy";
          };

          experimental.cache_file.enabled = true;
        };
      };

      # sing-box runs with `-C /run/sing-box` (the runtime directory), which
      # merges every JSON file found there. The nixpkgs module generates
      # /run/sing-box/config.json from `settings` (the public, typed config).
      # We drop the sops-decrypted outbounds next to it as outbounds.json, so
      # sing-box merges the secret outbounds array (vless-grpc, hysteria2,
      # urltest proxy group) into the final config at runtime.
      systemd.services.sing-box = {
        # Ensure sops has decrypted the secret before sing-box tries to read it.
        after = [ "sops-nix.service" ];
        serviceConfig.ExecStartPre = lib.mkAfter [
          "+${
            pkgs.writeShellScript "sing-box-install-outbounds" ''
              install -Dm 600 \
                ${config.sops.secrets.sing-box-outbounds.path} \
                /run/sing-box/outbounds.json
              chown sing-box:sing-box /run/sing-box/outbounds.json
            ''
          }"
        ];
      };
    };
}
