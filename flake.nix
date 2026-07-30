{
  description = "Development shell for dotnet-workspace-explorer.nvim";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = with pkgs; [
          neovim
          lua-language-server
          stylua
          lua51Packages.luacheck
          dotnet-sdk_10
          go_1_25
          ttyd
          ffmpeg
          chromium
        ];
      };
    };
}
