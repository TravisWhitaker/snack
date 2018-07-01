# TODO: currently single out derivations prepend the PWD to the path
# TODO: make sure that filters for "base" are airtight
{ lib
, haskellPackages
, makeWrapper
, rsync
, stdenv
, symlinkJoin
, writeScriptBin
, writeText
, runCommand
, callPackage
}:

with (callPackage ./files.nix {});

# why is "inherit" needed?
with (callPackage ./modules.nix { inherit singleOut; });
with (callPackage ./module-spec.nix { inherit singleOut; });
with (callPackage ./package-spec.nix { inherit singleOut; });
with (callPackage ./lib.nix {});

let

  buildModule = ghcWith: modSpec:
    let
      ghc = ghcWith modSpec.moduleDependencies;
      exts = modSpec.moduleExtensions;
      ghcOpts = modSpec.moduleGhcOpts ++ (map (x: "-X${x}") exts);
      ghcOptsArgs = lib.strings.escapeShellArgs ghcOpts;
      objectName = modSpec.moduleName;
      builtDeps = map (buildModule ghcWith) modSpec.moduleImports;
      depsDirs = map (x: x + "/") builtDeps;
      base = modSpec.moduleBase;
      makeSymtree =
        if lib.lists.length depsDirs >= 1
        # TODO: symlink instead of copy
        then "rsync -r ${lib.strings.escapeShellArgs depsDirs} ."
        else "";
      makeSymModule =
        # TODO: symlink instead of copy
        "rsync -r ${singleOutModule base modSpec.moduleName}/ .";
      pred = file: path: type:
        let
          topLevel = (builtins.toString base) + "/";
          actual = (lib.strings.removePrefix topLevel path);
          expected = file;
      in
        (expected == actual) ||
        (type == "directory" && (lib.strings.hasPrefix actual expected));

      extraFiles = builtins.filterSource
        (p: t:
          lib.lists.length
            (
            let
              topLevel = (builtins.toString base) + "/";
              actual = lib.strings.removePrefix topLevel p;
            in
              lib.filter (expected:
                (expected == actual) ||
                (t == "directory" && (lib.strings.hasPrefix actual expected))
                )
                modSpec.moduleFiles
            ) >= 1
        ) base;
    in stdenv.mkDerivation
    { name = objectName;
      src = symlinkJoin
        { name = "extra-files";
          paths = [ extraFiles ] ++ modSpec.moduleDirectories;
        };
      phases =
        [ "unpackPhase" "buildPhase" ];
      buildPhase =
        ''
          echo "Building module ${modSpec.moduleName}"
          mkdir -p $out
          echo "Creating dependencies symtree for module ${modSpec.moduleName}"
          ${makeSymtree}
          echo "Creating module symlink for module ${modSpec.moduleName}"
          ${makeSymModule}
          echo "Compiling module ${modSpec.moduleName}"
          # Set a tmpdir we have control over, otherwise GHC fails, not sure why
          mkdir -p tmp
          ghc -tmpdir tmp/ ${moduleToFile modSpec.moduleName} -c \
            -outputdir $out \
            ${ghcOptsArgs} \
            2>&1
          echo "Done building module ${modSpec.moduleName}"
        '';

      buildInputs =
        [ ghc
          rsync
        ];
    };

  # Returns an attribute set where the keys are all the built module names and
  # the values are the paths to the object files.
  # mainModSpec: a "main" module
  buildMain = ghcWith: mainModSpec:
    buildModulesRec ghcWith
      # XXX: the main modules need special handling regarding the object name
      { "${mainModSpec.moduleName}" =
        "${buildModule ghcWith mainModSpec}/Main.o";}
      mainModSpec.moduleImports;

  # returns a attrset where the keys are the module names and the values are
  # the modules' object file path
  buildLibrary = ghcWith: modSpecs:
    buildModulesRec ghcWith {} modSpecs;

  # Build the given modules (recursively) using the given accumulator to keep
  # track of which modules have been built already
  # XXX: doesn't work if several modules in the DAG have the same name
  buildModulesRec = ghcWith: empty: modSpecs:
    foldDAG
      { f = mod:
          { "${mod.moduleName}" =
            "${buildModule ghcWith mod}/${moduleToObject mod.moduleName}";
          };
        elemLabel = mod: mod.moduleName;
        elemChildren = mod: mod.moduleImports;
        reduce = a: b: a // b;
        empty = empty;
      }
      modSpecs;

  linkMainModule = ghcWith: mod: # main module
    let
      objAttrs = buildMain ghcWith mod;
      objList = lib.attrsets.mapAttrsToList (x: y: y) objAttrs;
      deps = allTransitiveDeps [mod];
      ghc = ghcWith deps;
      ghcOptsArgs = lib.strings.escapeShellArgs mod.moduleGhcOpts;
      packageList = map (p: "-package ${p}") deps;
      relExePath = "bin/${lib.strings.toLower mod.moduleName}";
      drv = runCommand "linker" {}
        ''
          mkdir -p $out/bin
          ${ghc}/bin/ghc \
            ${lib.strings.escapeShellArgs packageList} \
            ${lib.strings.escapeShellArgs objList} \
            ${ghcOptsArgs} \
            -o $out/${relExePath}
        '';
    in
      {
        out = drv;
        relExePath = relExePath;
      };


  # Write a new ghci executable that loads all the modules defined in the
  # module spec
  ghciWithMain = ghcWith: mainModSpec:
    let
      imports = allTransitiveImports [mainModSpec];
      modSpecs = [mainModSpec] ++ imports;
    in ghciWithModules ghcWith modSpecs;

  ghciWithModules = ghcWith: modSpecs:
    let
      ghcOpts = allTransitiveGhcOpts modSpecs
        ++ (map (x: "-X${x}") (allTransitiveExtensions modSpecs));
      ghc = ghcWith (allTransitiveDeps modSpecs);
      ghciArgs = lib.strings.escapeShellArgs
        (ghcOpts ++ absoluteModuleFiles);
      absoluteModuleFiles =
        map
          (mod:
            builtins.toString (mod.moduleBase) +
              "/${moduleToFile mod.moduleName}"
          )
          modSpecs;

      dirs = allTransitiveDirectories modSpecs;
      newGhc =
        symlinkJoin
          { name = "ghci";
            paths = [ ghc ];
            postBuild =
            ''
              wrapProgram "$out/bin/ghci" \
                --add-flags "${ghciArgs}"
            '';
            buildInputs = [makeWrapper];
          };
    in
      # This symlinks the extra dirs to $PWD for GHCi to work
      writeScriptBin "ghci-with-files"
        ''
        #!/usr/bin/env bash
        set -euo pipefail

        TRAPS=""
        for i in ${lib.strings.escapeShellArgs dirs}; do
          if [ "$i" != "$PWD" ]; then
          for j in $(find "$i" ! -path "$i"); do
            file=$(basename $j)
            echo "Temporarily symlinking $j to $file..."
            ln -s $j $file
            TRAPS="rm $file ; $TRAPS"
            trap "$TRAPS" EXIT
            echo "done."
          done
          fi
        done
        ${newGhc}/bin/ghci
        '';

  # Takes a package spec and returns (modSpecs -> Fold)
  modSpecFoldFromPackageSpec = pkgSpec:
      let
        baseByModuleName = modName:
          let res = pkgSpecByModuleName pkgSpec null modName;
          in if res == null then null else res.packageBase;
        depsByModuleName = modName:
          (pkgSpecByModuleName
            pkgSpec
            (abort "asking dependencies for external module: ${modName}")
            modName).packageDependencies
            modName
          ;
        extsByModuleName = modName:
          (pkgSpecByModuleName
            pkgSpec
            (abort "asking extensions for external module: ${modName}")
            modName).packageExtensions;
        ghcOptsByModuleName = modName:
          (pkgSpecByModuleName
            pkgSpec
            (abort "asking ghc options for external module: ${modName}")
            modName).packageGhcOpts;
      in
        moduleSpecFold
          { baseByModuleName = baseByModuleName;
            filesByModuleName = pkgSpec.packageExtraFiles;
            dirsByModuleName = pkgSpec.packageExtraDirectories;
            depsByModuleName = depsByModuleName;
            extsByModuleName = extsByModuleName;
            ghcOptsByModuleName = ghcOptsByModuleName;
          };

  # TODO: "executable" is a bad name
  executable = pkgDescr:
    let
      moduleSpecFold' = modSpecFoldFromPackageSpec topPkgSpec;
      topPkgSpec = mkPackageSpec pkgDescr;
      ghcWith = deps: haskellPackages.ghcWithPackages
        (ps: map (p: ps.${p}) deps);
    in
      if builtins.isNull topPkgSpec.packageMain
      then
        let
          modNames = listModulesInDir topPkgSpec.packageBase;
          fld = moduleSpecFold' modSpecs';
          modSpecs' = foldDAG fld modNames;
          modSpecs = builtins.attrValues modSpecs';
        in
          {
            build =
              # This json is a bit different than the other ones, because it's
              # a map of modules to object files (rather than out_path +
              # exe_path)
              { json = writeText "build_output"
                  (builtins.toJSON (buildLibrary ghcWith modSpecs));
              };
            ghci =
              let
                drv = ghciWithModules ghcWith modSpecs;
                json =
                  { out_path = "${drv.out}";
                    exe_path = "${drv.out}/bin/ghci-with-files";
                  };
              in
                { out = drv.out;
                  json = writeText "ghci_output" (builtins.toJSON json);
                };
          }
      else
        let
          mainModName = topPkgSpec.packageMain;
          mainModSpec =
            let
              fld = moduleSpecFold' modSpecs;
              modSpecs = foldDAG fld [mainModName];
            in modSpecs.${mainModName};
        in
          { build =
              let
                drv = linkMainModule ghcWith mainModSpec;
                json =
                  { out_path = "${drv.out}";
                    exe_path = "${drv.out}/${drv.relExePath}";
                  };
              in
                { out = drv.out;
                  json = writeText "build_output" (builtins.toJSON json);
                };

            ghci =
              let
                drv = ghciWithMain ghcWith mainModSpec;
                json =
                  { out_path = "${drv.out}";
                    exe_path = "${drv.out}/bin/ghci-with-files";
                  };
                in
                  { out = drv.out;
                    json = writeText "ghci_output" (builtins.toJSON json);
                  };
          };
in
  {
    inherit
    executable
    ;
  }
