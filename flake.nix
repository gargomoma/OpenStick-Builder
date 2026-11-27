{
  description = "OpenStick-Builder extras (fix-attach-apn, dongie-leds, flash tweaks, Tailscale, dongie-rs + dongie-ims) for MSM8916 4G sticks";
  # (muxtastic isn't built here yet: build_extras.sh builds it with zig, or MUXTASTIC_PREBUILT)

  # nix build .#extras      -> rootfs/ (the tree build_extras.sh stages into dist/) + files/ (source archives)
  # nix build .#dongie      -> bin/{dongie,dongie-ims} (static aarch64) + sources/*.tar.xz
  # nix develop             -> shell with the Rust/Go toolchains and linters
  #
  # Use the Nix-built dongie in a normal image build:
  #   sudo DONGIE_PREBUILT=$(nix build --print-out-paths .#dongie) ./build.sh
  # The image itself is still built by the scripts (debootstrap/chroot as root).
  # .#extras/rootfs is for looking at: the Nix store makes every file 0444, so
  # don't copy it into an image (DONGIE_PREBUILT keeps the right modes).

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: lib.genAttrs systems (system: f (import nixpkgs {
        inherit system;
        overlays = [ (import rust-overlay) ];
      }));

      # configs/extras/dongie-versions: KEY=value lines, shared with build_extras.sh
      versions = builtins.listToAttrs (map
        (l: let m = builtins.match "([A-Z0-9_]+)=(.*)" l; in {
          name = builtins.elemAt m 0;
          value = builtins.elemAt m 1;
        })
        (builtins.filter (l: builtins.match "[A-Z0-9_]+=.*" l != null)
          (lib.splitString "\n" (builtins.readFile ./configs/extras/dongie-versions))));

      # Update after a version bump: set to lib.fakeHash, `nix build .#extras` prints the right ones.
      hashes = {
        dongie-rs = {
          src = "sha256-ffKfggWlCZMGiAhC991h5ZWarlqpfKEAB6lWr6o6PWI=";
          cargo = "sha256-7pBs1WqBW1tgkBybG6oJbe8e9sQbZ2DSVe5q9YY4w3I=";
        };
        dongie-ims = {
          src = "sha256-03/3s3gX9SBAjRUa1ScNoVQsqw3/8HV/R36tfG3GaUI=";
          vendor = "sha256-4miYfz9gonoteifEcQuiHZFMfW5vs2GAlddD2UjFMuU=";
        };
      };

      # same tarball and sha256 as build_extras.sh downloads
      tailscale-tgz = builtins.fetchurl {
        url = "https://pkgs.tailscale.com/stable/tailscale_${versions.TAILSCALE_VERSION}_arm64.tgz";
        sha256 = versions.TAILSCALE_SHA256;
      };

      tarFlags = "--sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner";
    in
    {
      packages = forAll (pkgs:
        let
          rust = pkgs.rust-bin.stable.latest.minimal.override {
            targets = [ "aarch64-unknown-linux-musl" ];
          };

          dongie-rs = pkgs.stdenv.mkDerivation rec {
            pname = "dongie-rs";
            version = lib.removePrefix "v" versions.DONGIE_RS_REF;
            src = pkgs.fetchFromGitHub {
              owner = "derpyspike";
              repo = "dongie-rs";
              rev = versions.DONGIE_RS_REF;
              hash = hashes.dongie-rs.src;
            };
            cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
              inherit src;
              hash = hashes.dongie-rs.cargo;
            };
            nativeBuildInputs = [ rust pkgs.rustPlatform.cargoSetupHook ];
            # the repo's .cargo/config.toml links with rust-lld, statically
            buildPhase = ''
              runHook preBuild
              cargo build --release --offline --locked --target aarch64-unknown-linux-musl
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              install -D -m 0755 target/aarch64-unknown-linux-musl/release/dongie $out/bin/dongie
              runHook postInstall
            '';
            dontStrip = true; # aarch64 binary, host strip can't handle it
            dontPatchELF = true;
            meta.license = lib.licenses.eupl12;
          };

          dongie-ims = pkgs.buildGoModule {
            pname = "dongie-ims";
            version = lib.removePrefix "v" versions.DONGIE_IMS_REF;
            src = pkgs.fetchFromGitHub {
              owner = "derpyspike";
              repo = "dongie-ims";
              rev = versions.DONGIE_IMS_REF;
              hash = hashes.dongie-ims.src;
            };
            vendorHash = hashes.dongie-ims.vendor;
            # dongie-ims >= 0.3.0: patch the vendored ims-go (VoLTE ESP socket),
            # as its scripts/vendor.sh does
            modPostBuild = ''
              chmod -R u+w vendor/github.com/damonto/ims-go
              patch -p1 -d vendor/github.com/damonto/ims-go < patches/ims-go-esp-numeric.patch
            '';
            env.CGO_ENABLED = 0;
            ldflags = [ "-s" "-w" ];
            # cross-compile for the stick; tests can't run on an x86 host
            preBuild = ''
              export GOOS=linux GOARCH=arm64
            '';
            doCheck = false;
            postInstall = ''
              if [ -d $out/bin/linux_arm64 ]; then
                mv $out/bin/linux_arm64/* $out/bin/ && rmdir $out/bin/linux_arm64
              fi
            '';
            dontStrip = true;
            dontPatchELF = true;
            meta.license = lib.licenses.gpl3Only;
          };

          # complete corresponding source with vendored dependencies, same layout
          # as the archives build_extras.sh writes
          dongie-sources = pkgs.runCommand "dongie-sources" { nativeBuildInputs = [ pkgs.xz ]; } ''
            mkdir -p work $out
            cp -r ${dongie-rs.src} work/dongie-rs
            cp -r ${dongie-ims.src} work/dongie-ims
            chmod -R u+w work
            # fetchCargoVendor nests the crates in source-registry-0/; use the plain
            # `cargo vendor` layout (no git dependencies in Cargo.lock)
            cp -r ${dongie-rs.cargoDeps}/source-registry-0 work/dongie-rs/vendor
            cp -r ${dongie-ims.goModules} work/dongie-ims/vendor
            chmod -R u+w work
            mkdir -p work/dongie-rs/.cargo
            printf '\n[source.crates-io]\nreplace-with = "vendored-sources"\n\n[source.vendored-sources]\ndirectory = "vendor"\n' \
              >> work/dongie-rs/.cargo/config.toml
            tar -C work ${tarFlags} -cJf $out/sources-dongie-rs-${versions.DONGIE_RS_REF}.tar.xz dongie-rs
            tar -C work ${tarFlags} -cJf $out/sources-dongie-ims-${versions.DONGIE_IMS_REF}.tar.xz dongie-ims
          '';

          dongie = pkgs.runCommand "dongie-${versions.DONGIE_RS_REF}" { } ''
            install -D -m 0755 ${dongie-rs}/bin/dongie $out/bin/dongie
            install -D -m 0755 ${dongie-ims}/bin/dongie-ims $out/bin/dongie-ims
            mkdir -p $out/sources
            cp ${dongie-sources}/*.tar.xz $out/sources/
          '';

          # runs the same scripts/build_extras.sh, with the Nix-built dongie
          # (without muxtastic and Leviculum: their builds need the network, not in the sandbox)
          extras = pkgs.runCommand "openstick-extras" { nativeBuildInputs = [ pkgs.sudo ]; } ''
            cp -r ${self} src && chmod -R u+w src && cd src
            DIST=$out/rootfs DONGIE_PREBUILT=${dongie} TAILSCALE_TGZ=${tailscale-tgz} WITH_MUXTASTIC=0 WITH_LEVICULUM=0 sh -e scripts/build_extras.sh
            mv files $out/files
          '';
        in
        {
          inherit dongie-rs dongie-ims dongie-sources dongie extras;
          default = extras;
        });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [
            (pkgs.rust-bin.stable.latest.default.override { targets = [ "aarch64-unknown-linux-musl" ]; })
            pkgs.go
            pkgs.zig # muxtastic's C parts (scripts/zigcc-aarch64-musl)
            pkgs.cmake
            pkgs.git
            pkgs.xz
            pkgs.shellcheck
            pkgs.actionlint
          ];
        };
      });
    };
}
