{
  description = "A development shell for C projects using PipeWire";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    {
      devShells.x86_64-linux.default =
        let
          pkgs = import nixpkgs { system = "x86_64-linux"; };
        in
        pkgs.mkShell {
          packages = with pkgs; [
            pkg-config
          ];

          buildInputs = with pkgs; [
            pipewire.dev
          ];

          shellHook = ''
            export PKG_CONFIG_PATH="${pkgs.pipewire.dev}/lib/pkgconfig:$PKG_CONFIG_PATH"
            export CPATH="${pkgs.pipewire.dev}/include/pipewire-0.3/:$CPATH"
            echo "PipeWire C development shell active."
          '';
        };
    };
}
