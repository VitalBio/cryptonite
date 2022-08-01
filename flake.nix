{
  description = "Engineering documentation";

  inputs = {
    flakeUtils.url = "flake:flake-utils";
    haskellNix.url = "github:input-output-hk/haskell.nix";
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
  };

  outputs = { flakeUtils, haskellNix, nixpkgs, self }@inputs: let
    haskellConfig = {
      compiler-nix-name = "ghc924";
      index-state = "2022-07-31T00:00:00Z";
      index-sha256 = "d922320090859af94941e832ee662c5a1fec856d8083e3983933454b97498bef";

      modules = let
        inherit (builtins) compareVersions;
        inherit (nixpkgs.lib.modules) mkIf;
      in [
        {
          packages.bytestring = ({config, ... }:
          mkIf
          (compareVersions config.package.identifier.version "0.11" < 0)
          {
            flags."integer-simple" = true;
          });
        }

        { packages.bitvec.flags.libgmp = false; }

        {
          packages.bitvec = ({config, ... }:
          mkIf
          (compareVersions config.package.identifier.version "1.1.3.0" == 0)
          {
            patches = [
              ./deps/patches/bitvec-1.1.3.0-libgmp-link-dependency.patch
            ];
          });
        }

        { packages.ghc-bignum.flags.native = true; }
      ];
    };


    overlays = {
      default = final: prev: {
        cryptoniteHaskellProject = final.haskell-nix.cabalProject' (haskellConfig // {
          src = ./.;

          shell = {
            packages = ps: with ps; [
              cryptonite
            ];

            buildInputs = [
              final.gdb
            ];

            tools = let
              inherit (builtins) typeOf;
              handlers = {
                "set" = config: haskellConfig // config;
                "string" = version: haskellConfig // { inherit version; };
              };

              baseHaskellConfig = _n: v: (handlers.${typeOf v} or (builtins.abort "no handler for ‘${typeOf v}’")) v;
            in nixpkgs.lib.mapAttrs baseHaskellConfig {
              cabal = "latest";
              # ghcid = "latest";
              # haskell-language-server = {
              #   version = "latest";

              #   cabalProject = nixpkgs.lib.mkOverride 50 ''
              #     packages: .

              #     constraints: dependent-sum >= 0.7.1.0

              #     package haskell-language-server
              #       flags:
              #         -brittany
              #         -floskell
              #         -ormolu
              #         -stylishHaskell
              #         -haddockcomments
              #         -retrie
              #         -splice
              #         -tactics
              #   '';
              # };
              # hlint = "latest";
              # hoogle = "latest";
              # hpack = "latest";
            };
          };
        });
      };

      ghcCompilerSettings = let
        inherit (nixpkgs.lib.attrsets) mapAttrs recursiveUpdate;
        inherit (nixpkgs.lib.strings) hasPrefix;

        ghcOverrides = compiler-nix-name: attrs: attrs // {
          enableDWARF = true;
          enableRelocatedStaticLibs = !attrs.enableShared or false;
          enableShared = attrs.enableShared or true;
        } // (if hasPrefix "ghc" compiler-nix-name && !hasPrefix "ghc8" compiler-nix-name then {
          enableNativeBignum = true;
        } else {
          enableIntegerSimple = true;
        });

        overrideHaskellNixCompilers = baseOverrides: pkgs: recursiveUpdate pkgs {
          haskell-nix.compiler =
            mapAttrs
            (cn: cpkg: cpkg.override (ghcOverrides cn baseOverrides))
            (nixpkgs.lib.attrsets.filterAttrs (
              n: nixpkgs.lib.trivial.const (n == haskellConfig.compiler-nix-name))
              pkgs.haskell-nix.compiler);
        };

        crossOverrides = {
          musl64 = {
            enableDWARF = false;
            enableShared = false;
          };
        };
      in final: prev: recursiveUpdate (overrideHaskellNixCompilers {} prev) {
        pkgsCross = mapAttrs (n: v: overrideHaskellNixCompilers (crossOverrides.${n} or {}) v) prev.pkgsCross;
      };
    };
  in flakeUtils.lib.eachSystem
    (with flakeUtils.lib.system; [ x86_64-linux ])
    (system: let
      pkgs = import nixpkgs {
        localSystem = {
          inherit system;
          gcc = { tune = "skylake"; arch = "skylake"; };
        };

        overlays = [
          haskellNix.overlay
          overlays.ghcCompilerSettings
          overlays.default
        ];
      };
    in {
      devShells.default = pkgs.cryptoniteHaskellProject.shell.overrideAttrs (oldAttrs: {
          name = "cryptonite-devshell";
        });
    });
}
