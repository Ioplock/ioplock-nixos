{ self, inputs, ... }:
{
  # Forward a client's physical microphone over the LAN into mimosa's games.
  #
  # Two independently toggleable sides share one feature module:
  #   * receiver (mimosa, Sunshine host): snd-aloop virtual mic + RTP/Opus
  #     listener. Games read the virtual mic as the default input source.
  #   * sender  (acrux / any Linux client): captures this host's real mic and
  #     streams it as RTP/Opus to the receiver.
  #
  # Lifecycle: the receiver unit runs only while a streaming session is live
  # (started/stopped by Sunshine's prep/undo commands). Senders are started
  # manually on whichever client PC is in use — Sunshine does not expose the
  # connected client's IP to prep commands, so per-client auto-triggering is
  # not possible, and broadcast triggering was rejected because multiple
  # online clients would collide on the receiver's single UDP socket. Start
  # the sender on exactly one machine: `systemctl --user start
  # mic-forward-send` (Linux) or windows-client/mic-forward-send.ps1.
  #
  # Windows clients send with the same RTP/Opus transport via a portable
  # GStreamer runtime — see windows-client/README.md.
  flake.nixosModules.micForward =
    { config, pkgs, lib, ... }:
    let
      cfg = config.myMicForward;
      sys = pkgs.stdenv.hostPlatform.system;
      selfPkg = name: self.packages.${sys}.${name};
      gst = with pkgs.gst_all_1; [
        gstreamer
        gst-plugins-base
        gst-plugins-good
        gst-plugins-bad
      ];
    in
    {
      options.myMicForward = {
        enableReceiver = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Expose incoming RTP/Opus as a virtual mic (Sunshine host).";
        };
        enableSender = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Send this host's mic to the Sunshine host as RTP/Opus.";
        };

        host = lib.mkOption {
          type = lib.types.str;
          default = "192.168.1.92";
          description = "Sunshine host (receiver) address that senders target.";
        };
        receivePort = lib.mkOption {
          type = lib.types.port;
          default = 5004;
          description = "UDP port the receiver listens on for RTP/Opus audio.";
        };

        loopbackPlayback = lib.mkOption {
          type = lib.types.str;
          default = "mic-loopback-pb";
          description = "Stable Pulse/PipeWire name of the snd-aloop playback sink.";
        };
        loopbackCapture = lib.mkOption {
          type = lib.types.str;
          default = "mic-loopback-cm";
          description = "Stable Pulse/PipeWire name of the snd-aloop capture source (the virtual mic).";
        };

        enableVbanReceiver = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Accept VoiceMeeter VBAN streams from Windows clients as a virtual mic.";
        };
        vbanPort = lib.mkOption {
          type = lib.types.port;
          default = 6980;
          description = "UDP port for incoming VBAN streams (VoiceMeeter default).";
        };
      };

      config = lib.mkMerge [
        (lib.mkIf cfg.enableReceiver {
          boot.kernelModules = [ "snd-aloop" ];

          # Expose a single playback+capture pair (instead of the default 8
          # substreams) so the node-rename rules below match exactly one node
          # each. The capture side of the pair is the virtual mic.
          boot.extraModprobeConfig = ''
            options snd-aloop pcm_substreams=1
          '';

          # GStreamer stack for decoding.
          environment.systemPackages = gst;

          # Incoming RTP/Opus audio.
          networking.firewall.allowedUDPPorts = [ cfg.receivePort ];

          # Rename the snd-aloop nodes to stable names so the receiver can
          # feed the playback side deterministically and games see the capture
          # side as a fixed virtual mic. Real node names are
          # alsa_output.platform-snd_aloop..analog-stereo (and alsa_input.*);
          # pcm_substreams=1 above guarantees exactly one node of each kind.
          # Note: monitor.alsa.rules is the WirePlumber section for ALSA
          # device/node matching — node.rules is a PipeWire server section
          # that WirePlumber ignores.
          services.pipewire.wireplumber.extraConfig."50-mic-loopback" = {
            "monitor.alsa.rules" = [
              {
                matches = [ { "node.name" = "~alsa_output.*snd_aloop.*"; } ];
                actions."update-props" = {
                  "node.name" = cfg.loopbackPlayback;
                  "node.description" = "Virtual Mic (playback)";
                };
              }
              {
                matches = [ { "node.name" = "~alsa_input.*snd_aloop.*"; } ];
                actions."update-props" = {
                  "node.name" = cfg.loopbackCapture;
                  "node.description" = "Virtual Mic";
                  "priority.session" = 10000;
                };
              }
            ];
          };

          # Decode incoming RTP/Opus into the loopback playback side; the
          # loopback capture side is what games read as the mic. Started and
          # stopped by Sunshine's prep/undo commands.
          systemd.user.services."mic-forward-recv" = {
            enable = true;
            serviceConfig = {
              Restart = "on-failure";
              ExecStart = "${lib.getExe (selfPkg "myMicForwardRecv")} ${toString cfg.receivePort} ${cfg.loopbackPlayback}";
            };
          };
        })

        (lib.mkIf cfg.enableVbanReceiver {
          # Windows clients stream their mic with VoiceMeeter's VBAN protocol
          # (plain PCM over UDP, no scripting on the Windows side). The
          # PipeWire module is loaded permanently, but the source node only
          # exists while a stream is actually arriving; its priority beats
          # the snd-aloop virtual mic (10000), so the default source follows
          # whichever client is live and reverts when it goes silent.
          services.pipewire.extraConfig.pipewire."55-mic-vban" = {
            "context.modules" = [
              {
                "name" = "libpipewire-module-vban-recv";
                "args" = {
                  "source.ip" = "0.0.0.0";
                  "source.port" = cfg.vbanPort;
                  "sess.latency.msec" = 20;
                  "stream.rules" = [
                    {
                      "matches" = [ { "sess.name" = "~.*"; } ];
                      "actions"."create-stream"."stream.props" = {
                        "media.class" = "Audio/Source";
                        "node.name" = "mic-vban";
                        "node.description" = "Virtual Mic (VBAN)";
                        "priority.session" = 10001;
                      };
                    }
                  ];
                };
              }
            ];
          };

          networking.firewall.allowedUDPPorts = [ cfg.vbanPort ];
        })

        (lib.mkIf cfg.enableSender {
          environment.systemPackages = gst;

          # Actual mic streamer; started manually on the machine you are
          # sitting at (`systemctl --user start mic-forward-send`) so exactly
          # one client ever streams into the receiver.
          systemd.user.services."mic-forward-send" = {
            enable = true;
            serviceConfig = {
              Restart = "on-failure";
              ExecStart = "${lib.getExe (selfPkg "myMicForwardSend")} ${cfg.host} ${toString cfg.receivePort}";
            };
          };
        })
      ];
    };

  perSystem =
    { pkgs, lib, ... }:
    let
      gst = with pkgs.gst_all_1; [
        gstreamer
        gst-plugins-base
        gst-plugins-good
        gst-plugins-bad
      ];
      pluginPath = lib.makeSearchPath "lib/gstreamer-1.0" gst;
    in
    {
      packages = {
        # Capture this host's default mic and stream it as RTP/Opus.
        myMicForwardSend = pkgs.writeShellApplication {
          name = "mic-forward-send";
          runtimeInputs = gst;
          text = ''
            host="''${1:-192.168.1.92}"
            port="''${2:-5004}"
            export GST_PLUGIN_SYSTEM_PATH_1_0="${pluginPath}"
            exec gst-launch-1.0 -q \
              pulsesrc ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=1 ! \
              opusenc ! rtpopuspay pt=96 ! \
              udpsink host="''${host}" port="''${port}" auto-multicast=0
          '';
        };

        # Receive RTP/Opus and inject into the snd-aloop playback side.
        myMicForwardRecv = pkgs.writeShellApplication {
          name = "mic-forward-recv";
          runtimeInputs = gst;
          text = ''
            port="''${1:-5004}"
            sink="''${2:-mic-loopback-pb}"
            export GST_PLUGIN_SYSTEM_PATH_1_0="${pluginPath}"
            exec gst-launch-1.0 -q \
              udpsrc port="''${port}" \
                caps="application/x-rtp,media=(string)audio,encoding-name=(string)OPUS,payload=(int)96,clock-rate=(int)48000" ! \
              rtpjitterbuffer latency=20 ! rtpopusdepay ! \
              opusdec ! audioconvert ! audioresample ! \
              pulsesink device="''${sink}"
          '';
        };

        # Start/stop the sender on the machine you are sitting at; bound to
        # Mod+M in the desktop niri config.
        myMicForwardToggle = pkgs.writeShellApplication {
          name = "mic-forward-toggle";
          runtimeInputs = [ pkgs.systemd ];
          text = ''
            if systemctl --user is-active --quiet mic-forward-send; then
              systemctl --user stop mic-forward-send
              echo "mic-forward: stopped"
            else
              systemctl --user start mic-forward-send
              echo "mic-forward: streaming"
            fi
          '';
        };
      };
    };
}
