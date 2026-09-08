{
  self,
  inputs,
  ...
}:
{
  flake.wrappers.zsh =
    {
      pkgs,
      lib,
      wlib,
      ...
    }:
    let
      starshipConfig = (pkgs.formats.toml { }).generate "starship.toml" {
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
    in
    {
      imports = [ wlib.wrapperModules.zsh ];

      env = {
        EDITOR = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.myNeovim;
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
        hyperfine
        jq
        just
        lazygit
        less
        nano
        self.packages.${pkgs.stdenv.hostPlatform.system}.myNh
        nil
        nix-output-monitor
        nix-your-shell
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
        zsh-completions
        zsh-fzf-tab
        zsh-history-substring-search
        zsh-syntax-highlighting
        wl-clipboard
        cliphist
        self.packages.${pkgs.stdenv.hostPlatform.system}.myCliphistRofi
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
        f = "yazi";
        opencode-proxy = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.myOpencodeProxy;
        ".." = "cd ..";
        "..." = "cd ../..";
        rebuild-check = "nix flake check && nixos-rebuild dry-build --flake .#$(hostname)";
      };

      zshrc.content = ''
        setopt AUTO_CD
        setopt EXTENDED_HISTORY
        setopt HIST_IGNORE_DUPS
        setopt HIST_IGNORE_SPACE
        setopt HIST_VERIFY
        setopt SHARE_HISTORY
        setopt INTERACTIVE_COMMENTS
        setopt AUTO_PUSHD
        setopt PUSHD_IGNORE_DUPS
        setopt PUSHD_SILENT
        setopt HIST_REDUCE_BLANKS
        setopt HIST_FIND_NO_DUPS
        setopt NO_FLOW_CONTROL

        HISTSIZE=100000
        SAVEHIST=100000
        HISTFILE="$HOME/.zsh_history"
        HIST_TIME_FORMAT='%F %T '

        # keep only '_' as a word character, so alt+f and alt+backspace split
        # at path separators and punctuation instead of jumping whole paths
        WORDCHARS='_'

        # zsh-completions definitions must be on fpath before compinit runs
        fpath=(${pkgs.zsh-completions}/share/zsh/site-functions $fpath)

        autoload -Uz compinit
        if [[ -f "$HOME/.zcompdump-$ZSH_VERSION" ]]; then
          compinit -C -d "$HOME/.zcompdump-$ZSH_VERSION"
        else
          compinit -d "$HOME/.zcompdump-$ZSH_VERSION"
        fi

        # completion styling: case-insensitive, mid-word prefix matching,
        # named groups. Menu selection is handled by fzf-tab, not menu select.
        zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|=*' 'l:|=* r:|=*'
        zstyle ':completion:*:descriptions' format '[%d]'
        zstyle ':completion:*:warnings' format 'no matches for: %d'
        zstyle ':completion:*' group-name '''
        zstyle ':completion:*' keep-prefix true

        # fzf-tab replaces the default completion menu with an fzf popup.
        # Must load after compinit and before plugins that wrap widgets
        # (zsh-autosuggestions, zsh-syntax-highlighting).
        source ${pkgs.zsh-fzf-tab}/share/fzf-tab/fzf-tab.zsh

        # suggest from history first, then from tab-completion candidates
        ZSH_AUTOSUGGEST_STRATEGY=(history completion)

        source ${pkgs.fzf}/share/fzf/completion.zsh
        source ${pkgs.fzf}/share/fzf/key-bindings.zsh
        source ${pkgs.zsh-autosuggestions}/share/zsh-autosuggestions/zsh-autosuggestions.zsh

        eval "$(${lib.getExe pkgs.zoxide} init zsh --cmd cd)"
        eval "$(${lib.getExe pkgs.nix-your-shell} zsh)"
        eval "$(${lib.getExe pkgs.starship} init zsh)"

        if command -v direnv >/dev/null; then
          eval "$(${lib.getExe pkgs.direnv} hook zsh)"
        fi

        # Ghostty shell integration. Auto-injection is disabled on the ghostty
        # wrapper (--shell-integration=none) because it conflicts with the
        # wrapped zsh's ZDOTDIR, so we source the integration script manually
        # here. The guard makes this a no-op outside of ghostty. The script
        # reorders its own precmd hook to run last, so sourcing it before
        # zsh-syntax-highlighting (which recommends being sourced last) is safe.
        if [[ -n "$GHOSTTY_RESOURCES_DIR" ]]; then
          source "$GHOSTTY_RESOURCES_DIR"/shell-integration/zsh/ghostty-integration
        fi

        source ${pkgs.zsh-syntax-highlighting}/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

        # history-substring-search must load after zsh-syntax-highlighting.
        # Type a substring and press up/down to walk matching history entries.
        source ${pkgs.zsh-history-substring-search}/share/zsh-history-substring-search/zsh-history-substring-search.zsh
        bindkey '\e[A' history-substring-search-up
        bindkey '\e[B' history-substring-search-down
        bindkey '\eOA' history-substring-search-up
        bindkey '\eOB' history-substring-search-down

        # Ctrl+Tab: ghostty sends ESC[27;5;9~ for it. forward-word is in
        # ZSH_AUTOSUGGEST_PARTIAL_ACCEPT_WIDGETS, so with a pending gray
        # autosuggestion this accepts one word and leaves the rest editable
        # (fish-style partial accept); without a suggestion it moves forward
        # one word.
        bindkey '\e[27;5;9~' forward-word
      '';
    };

  flake.nixosModules.shell =
    { pkgs, ... }:
    {
      programs.zsh = {
        enable = true;
        enableGlobalCompInit = false;
        promptInit = "";
      };
      environment.pathsToLink = [ "/share/zsh" ];

      environment.shells = [
        pkgs.bashInteractive
        self.packages.${pkgs.stdenv.hostPlatform.system}.myShellEnv
      ];
      users.defaultUserShell = self.packages.${pkgs.stdenv.hostPlatform.system}.myShellEnv;

      environment.systemPackages = [
        self.packages.${pkgs.stdenv.hostPlatform.system}.myShellEnv
      ];
    };

  perSystem =
    {
      pkgs,
      self',
      ...
    }:
    {
      wrappers.packages.zsh = true;

      packages.myZsh = inputs.wrapper-modules.wrappers.zsh.wrap {
        inherit pkgs;
        imports = [ self.wrapperModules.zsh ];
      };

      packages.myShellEnv = inputs.wrapper-modules.lib.wrapPackage {
        inherit pkgs;
        package = self'.packages.myZsh;
        extraPackages = [ self'.packages.myGit ];
        passthru.shellPath = self'.packages.myZsh.shellPath;
      };
    };
}
