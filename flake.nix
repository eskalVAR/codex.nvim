{
  description = "codex.nvim Neovim plugin";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      overlay = final: prev: {
        vimPlugins = prev.vimPlugins // {
          codex-nvim = prev.vimUtils.buildVimPlugin {
            pname = "codex.nvim";
            version = "0.1.0";
            src = prev.lib.cleanSource self;
          };
        };
      };
    in
    flake-utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ overlay ];
        };
      in
      {
        packages = {
          default = pkgs.vimPlugins.codex-nvim;
          codex-nvim = pkgs.vimPlugins.codex-nvim;
        };
      }) // {
        overlays.default = overlay;
      };
}
