{ self, inputs, ... }:
{
  flake.nixosModules.cliphist =
    { pkgs, lib, ... }:
    let
      mkWatcher = type: {
        description = "Cliphist ${type} clipboard watcher";
        wantedBy = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${lib.getExe' pkgs.wl-clipboard "wl-paste"} --type ${type} --watch ${lib.getExe pkgs.cliphist} store";
          Restart = "always";
          RestartSec = "2s";
        };
      };
    in
    {
      systemd.user.services = {
        cliphist-text = mkWatcher "text";
        cliphist-image = mkWatcher "image";
      };
    };

  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    {
      packages.myCliphistRofi = pkgs.writeShellApplication {
        name = "cliphist-rofi";
        runtimeInputs = with pkgs; [
          cliphist
          libnotify
          wl-clipboard
        ];
        text = ''
          history=$(mktemp)
          menu=$(mktemp)
          trap 'rm -f "$history" "$menu"' EXIT

          cliphist list > "$history"
          if [ ! -s "$history" ]; then
            notify-send "Clipboard" "History is empty. Copy something first."
            exit 0
          fi

          while IFS= read -r entry; do
            printf '%s\n' "$entry"
          done < "$history" > "$menu"

          selected=$(${lib.getExe self'.packages.myCliphistRofiPicker} -dmenu -i -p "Clipboard" < "$menu")
          if [ -n "$selected" ]; then
            printf '%s\n' "$selected" | cliphist decode | wl-copy
          fi
        '';
      };
    };
}
