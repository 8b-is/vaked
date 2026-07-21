{
  description = "vaked — flake-native capability-graph language";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
    in
    {
      devShells = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            packages = [ pkgs.python312 pkgs.zig ];
            shellHook = ''
              export PYTHONPATH="$PWD:$PYTHONPATH"
              export PATH="$PWD/bin:$PATH"
            '';
          };
        });

      packages = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          vakedz = pkgs.stdenv.mkDerivation {
            pname = "vakedz";
            version = "0.0.0";
            src = self;
            nativeBuildInputs = [ pkgs.zig ];
            buildPhase = "zig build -Doptimize=ReleaseSafe --global-cache-dir $TMPDIR/zig-cache";
            installPhase = "mkdir -p $out/bin && cp zig-out/bin/vakedz $out/bin/";
          };
        });
    };
}
