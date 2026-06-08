{
  self,
  inputs,
  ...
}: {
  flake.wrappers.zsh = {
    pkgs,
    lib,
    wlib,
    ...
  }: let
    starshipConfig = (pkgs.formats.toml {}).generate "starship.toml" {
      add_newline = false;
      command_timeout = 1000;
      format = "$directory$git_branch$git_status$nix_shell$cmd_duration$line_break$character";
      character = {
        success_symbol = "[>](bold green)";
        error_symbol = "[>](bold red)";
      };
      directory = {
        truncation_length = 3;
        truncate_to_repo = false;
      };
      git_branch.symbol = "git ";
      nix_shell = {
        symbol = "nix ";
        format = "[$symbol$state( \\($name\\))]($style) ";
      };
      cmd_duration = {
        min_time = 1000;
        format = "[$duration]($style) ";
      };
    };
  in {
    imports = [wlib.wrapperModules.zsh];

    env = {
      EDITOR = "nano";
      MANPAGER = "sh -c 'col -bx | bat --language=man --plain'";
      PAGER = "less -FRX";
      STARSHIP_CONFIG = "${starshipConfig}";
    };

    extraPackages = with pkgs; [
      alejandra
      bat
      btop
      curl
      deadnix
      delta
      direnv
      dust
      duf
      eza
      fd
      fzf
      gh
      git
      hyperfine
      jq
      just
      lazygit
      less
      nano
      nh
      nil
      nix-output-monitor
      nixd
      procs
      ripgrep
      sd
      starship
      statix
      tealdeer
      tree
      util-linux
      wget
      yq-go
      zoxide
      zsh-autosuggestions
      zsh-syntax-highlighting
    ];

    zshAliases = {
      ls = "eza --icons=always";
      ll = "eza --icons=always --long --git --header";
      la = "eza --icons=always --long --git --header --all";
      l = "eza --icons=always --long --all";
      tree = "eza --icons=always --tree";
      cat = "bat --paging=never";
      grep = "rg";
      find = "fd";
      du = "dust";
      ps = "procs";
      top = "btop";
      df = "duf";
      lg = "lazygit";
      g = "git";
      ".." = "cd ..";
      "..." = "cd ../..";
      rebuild-check = "nix flake check && nixos-rebuild dry-build --flake .#acrux";
    };

    zshrc.content = ''
      setopt AUTO_CD
      setopt EXTENDED_HISTORY
      setopt HIST_IGNORE_DUPS
      setopt HIST_IGNORE_SPACE
      setopt HIST_VERIFY
      setopt SHARE_HISTORY

      HISTSIZE=100000
      SAVEHIST=100000
      HISTFILE="$HOME/.zsh_history"

      autoload -Uz compinit
      compinit -d "$HOME/.zcompdump-$ZSH_VERSION"

      source ${pkgs.fzf}/share/fzf/completion.zsh
      source ${pkgs.fzf}/share/fzf/key-bindings.zsh
      source ${pkgs.zsh-autosuggestions}/share/zsh-autosuggestions/zsh-autosuggestions.zsh

      eval "$(${lib.getExe pkgs.zoxide} init zsh --cmd cd)"
      eval "$(${lib.getExe pkgs.starship} init zsh)"

      if command -v direnv >/dev/null; then
        eval "$(${lib.getExe pkgs.direnv} hook zsh)"
      fi

      source ${pkgs.zsh-syntax-highlighting}/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
    '';
  };

  flake.nixosModules.shell = {pkgs, ...}: {
    programs.zsh.enable = true;
    environment.pathsToLink = ["/share/zsh"];

    environment.shells = [
      pkgs.bashInteractive
      self.packages.${pkgs.stdenv.hostPlatform.system}.myShellEnv
    ];
    users.defaultUserShell = self.packages.${pkgs.stdenv.hostPlatform.system}.myShellEnv;

    environment.systemPackages = [
      self.packages.${pkgs.stdenv.hostPlatform.system}.myShellEnv
    ];
  };

  perSystem = {
    pkgs,
    self',
    ...
  }: {
    wrappers.packages.zsh = true;

    packages.myZsh = inputs.wrapper-modules.wrappers.zsh.wrap {
      inherit pkgs;
      imports = [self.wrapperModules.zsh];
    };

    packages.myShellEnv = inputs.wrapper-modules.lib.wrapPackage {
      inherit pkgs;
      package = self'.packages.myZsh;
      passthru.shellPath = self'.packages.myZsh.shellPath;
    };
  };
}
