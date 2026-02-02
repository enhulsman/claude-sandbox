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

      in {
        packages = {
          default = launcherScript;
          verify = verifyScript;
          proxy = egressProxy;
          claude-code = claude-code-nix.packages.${system}.default;
        };

        # `nix develop` — drop into a shell with all tools available
        devShells.default = pkgs.mkShell {
          packages = linuxDeps ++ commonDeps ++ [ egressProxy launcherScript verifyScript ];
          shellHook = ''
            echo ""
            echo "  Claude Sandbox dev shell"
            echo "  Platform: ${system}"
            echo "  Sandbox:  ${if isLinux then "bubblewrap" else "sandbox-exec (Seatbelt)"}"
            echo ""
            echo "  claude-sandbox              — launch sandboxed Claude"
            echo "  claude-sandbox-verify       — run escape tests"
            echo "  claude-sandbox --help       — options & profiles"
            echo ""
          '';
        };
      });
}
