{
  description = "Cross-platform secure sandbox for Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    claude-code-nix.url = "github:sadjow/claude-code-nix";
    claude-code-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, flake-utils, claude-code-nix }:
    flake-utils.lib.eachSystem [
      "x86_64-linux"     # NixOS desktop, Ubuntu VPS
      "aarch64-linux"    # Raspberry Pi
      "aarch64-darwin"   # macOS Apple Silicon
      "x86_64-darwin"    # macOS Intel
    ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        isLinux = pkgs.stdenv.isLinux;
        isDarwin = pkgs.stdenv.isDarwin;

        # Platform-specific sandbox dependencies
        linuxDeps = pkgs.lib.optionals isLinux [
          pkgs.bubblewrap
          pkgs.socat
        ];

        # Common dependencies (all platforms)
        commonDeps = [
          pkgs.python3
          pkgs.coreutils
          pkgs.bash
          pkgs.gnugrep
          pkgs.gnused
          pkgs.gawk
          pkgs.curl       # for verification tests
          pkgs.findutils
          claude-code-nix.packages.${system}.default
        ];

        # The egress proxy script, installed as a standalone bin
        egressProxy = pkgs.writeScriptBin "claude-egress-proxy" ''
          #!${pkgs.python3}/bin/python3
          ${builtins.readFile ./scripts/egress-proxy.py}
        '';

        # Helper: path to scripts dir in the nix store copy of this flake
        scriptsDir = "${self}/scripts";

        # The main launcher
        launcherScript = pkgs.writeShellApplication {
          name = "claude-sandbox";
          runtimeInputs = linuxDeps ++ commonDeps ++ [ egressProxy ];
          text = ''
            export CLAUDE_SANDBOX_SCRIPTS="${scriptsDir}"
            export CLAUDE_SANDBOX_PROXY="${egressProxy}/bin/claude-egress-proxy"
            export CLAUDE_SANDBOX_CONFIG="''${CLAUDE_SANDBOX_CONFIG:-${self}/config.toml}"
            export CLAUDE_SANDBOX_IS_LINUX="${if isLinux then "1" else "0"}"
            export CLAUDE_SANDBOX_IS_DARWIN="${if isDarwin then "1" else "0"}"

            exec bash "${scriptsDir}/claude-sandbox.sh" "$@"
          '';
        };

        # Verification test runner
        verifyScript = pkgs.writeShellApplication {
          name = "claude-sandbox-verify";
          runtimeInputs = linuxDeps ++ commonDeps ++ [ egressProxy ];
          text = ''
            export CLAUDE_SANDBOX_IS_LINUX="${if isLinux then "1" else "0"}"
            export CLAUDE_SANDBOX_IS_DARWIN="${if isDarwin then "1" else "0"}"
            export CLAUDE_SANDBOX_PROXY="${egressProxy}/bin/claude-egress-proxy"

            exec bash "${scriptsDir}/verify.sh" "$@"
          '';
        };

        # Drop-in `claude` replacement — reads defaults file, delegates to sandbox
        claudeDropIn = pkgs.writeShellApplication {
          name = "claude";
          runtimeInputs = [ launcherScript ];
          text = ''
            _DEFAULTS="''${CLAUDE_SANDBOX_DEFAULTS:-''${XDG_CONFIG_HOME:-$HOME/.config}/claude-sandbox/defaults}"
            _PROFILE="''${CLAUDE_SANDBOX_PROFILE:-dev}"
            if [[ -f "$_DEFAULTS" ]]; then
              while IFS= read -r _line || [[ -n "$_line" ]]; do
                _line="''${_line%%#*}"
                [[ -z "''${_line// /}" ]] && continue
                _key="''${_line%%=*}"
                _val="''${_line#*=}"
                _key="''${_key#"''${_key%%[![:space:]]*}"}"
                _key="''${_key%"''${_key##*[![:space:]]}"}"
                _val="''${_val#"''${_val%%[![:space:]]*}"}"
                _val="''${_val%"''${_val##*[![:space:]]}"}"
                _val="''${_val#\"}" ; _val="''${_val%\"}"
                _val="''${_val#\'}" ; _val="''${_val%\'}"
                case "$_key" in
                  CLAUDE_SANDBOX_PROFILE)
                    _PROFILE="''${CLAUDE_SANDBOX_PROFILE:-$_val}" ;;
                esac
              done < "$_DEFAULTS"
            fi
            exec claude-sandbox --profile "$_PROFILE" -- "$@"
          '';
        };

        # Short alias: default profile (via drop-in)
        csAlias = pkgs.writeShellApplication {
          name = "cs";
          runtimeInputs = [ claudeDropIn ];
          text = ''
            exec claude "$@"
          '';
        };

        # Short alias: dev profile (hardcoded)
        csdAlias = pkgs.writeShellApplication {
          name = "csd";
          runtimeInputs = [ launcherScript ];
          text = ''
            exec claude-sandbox --profile dev -- "$@"
          '';
        };

        # Short alias: strict profile (hardcoded)
        cssAlias = pkgs.writeShellApplication {
          name = "css";
          runtimeInputs = [ launcherScript ];
          text = ''
            exec claude-sandbox --profile strict -- "$@"
          '';
        };

        # Alias setup script
        setupAliases = pkgs.writeShellApplication {
          name = "setup-aliases";
          runtimeInputs = [ pkgs.coreutils pkgs.bash pkgs.gawk pkgs.gnugrep ];
          text = ''
            exec bash "${scriptsDir}/setup-aliases.sh" "$@"
          '';
        };

      in {
        packages = {
          default = launcherScript;
          verify = verifyScript;
          proxy = egressProxy;
          claude-code = claude-code-nix.packages.${system}.default;
          claude = claudeDropIn;
          cs = csAlias;
          csd = csdAlias;
          css = cssAlias;
          setup-aliases = setupAliases;
        };

        # `nix develop` — drop into a shell with all tools available
        devShells.default = pkgs.mkShell {
          packages = linuxDeps ++ commonDeps ++ [
            egressProxy launcherScript verifyScript
            claudeDropIn csAlias csdAlias cssAlias setupAliases
          ];
          shellHook = ''
            echo ""
            echo "  Claude Sandbox dev shell"
            echo "  Platform: ${system}"
            echo "  Sandbox:  ${if isLinux then "bubblewrap" else "sandbox-exec (Seatbelt)"}"
            echo ""
            echo "  claude-sandbox              — launch sandboxed Claude"
            echo "  claude / cs                 — sandboxed Claude (default profile)"
            echo "  csd                         — sandboxed Claude (dev profile)"
            echo "  css                         — sandboxed Claude (strict profile)"
            echo "  claude-sandbox-verify       — run escape tests"
            echo "  claude-sandbox --help       — options & profiles"
            echo ""
          '';
        };
      });
}
