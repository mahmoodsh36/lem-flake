{
  description = "lem flake";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:nixos/nixpkgs/release-25.11";
    lem-src = {
      # url = "github:mahmoodsh36/lem/organ-mode";
      url = "github:mahmoodsh36/lem";
      flake = false;
    };
    micros-src = {
      url = "github:lem-project/micros";
      flake = false;
    };
    jsonrpc-src = {
      url = "github:cxxxr/jsonrpc";
      flake = false;
    };
    async-process-src = {
      url = "github:lem-project/async-process";
      flake = false;
    };
    lem-mailbox-src = {
      url = "github:lem-project/lem-mailbox";
      flake = false;
    };
    cltpt-src = {
      url = "github:mahmoodsh36/cltpt";
      flake = false;
    };
    organ-mode-src = {
      url = "github:mahmoodsh36/organ-mode";
      flake = false;
    };
    tree-sitter-cl-src = {
      url = "github:lem-project/tree-sitter-cl";
      flake = false;
    };
    cl-webview-src = {
      url = "github:lem-project/webview";
      flake = false;
    };
    webview-upstream-src = {
      url = "github:webview/webview";
      flake = false;
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      imports = [
        inputs.flake-parts.flakeModules.easyOverlay
      ];

      perSystem =
        { pkgs, ... }:
        let
          lisp = pkgs.sbcl;
          sharedLibExt = if pkgs.stdenv.isDarwin then "dylib" else "so";

          # helper for ASDF systems
          mkSimpleASDFSystem =
            {
              name,
              src,
              systems ? [ name ],
              lispLibs ? [ ],
            }:
            lisp.buildASDFSystem {
              pname = name;
              version = "unstable";
              inherit src systems lispLibs;
            };

          # helper to generate the Lisp build script used by all variants
          mkBuildScript =
            { entryPoint ? "lem:main" }:
            pkgs.writeText "build-lem.lisp" ''
              (defpackage :nix-cl-user (:use :cl))
              (in-package :nix-cl-user)

              ;; load ASDF
              (load "${lem-base.asdfFasl}/asdf.${lem-base.faslExt}")

              ;; redirect nix store fasls to local fasl-cache directory
              (asdf:initialize-output-translations
                `(:output-translations
                  (#p"/nix/store/**/*.*" ,(merge-pathnames "fasl-cache/nix/store/**/*.*" (uiop:getcwd)))
                  :inherit-configuration))

              ;; add extension paths (like organ-mode) to the registry
              (let ((ext-paths (uiop:getenv "LEM_EXTENSION_PATHS")))
                (when (and ext-paths (not (string= ext-paths "")))
                  (dolist (path (uiop:split-string ext-paths :separator '(#\Newline #\Space)))
                    (when (and (not (string= path ""))
                               (probe-file path))
                      (pushnew (pathname (concatenate 'string path "/"))
                               asdf:*central-registry* :test #'equal)))))

              ;; load systems
              (mapcar #'asdf:load-system (uiop:split-string (uiop:getenv "systems")))

              ;; runtime hook: configure ASDF output for recompilation
              (defun nix-cl-user::configure-asdf-for-runtime ()
                (asdf:initialize-output-translations
                  `(:output-translations
                    (t (,(merge-pathnames ".cache/lem-fasl/" (user-homedir-pathname)) :**/ :*.*.*))
                    :inherit-configuration)))
              (pushnew 'nix-cl-user::configure-asdf-for-runtime uiop:*image-restore-hook*)

              ;; dump image
              (setf uiop:*image-entry-point* #'${entryPoint})
              (uiop:dump-image "lem" :executable t :compression t)
            '';

          micros = mkSimpleASDFSystem {
            name = "micros";
            src = inputs.micros-src;
          };

          lem-mailbox = mkSimpleASDFSystem {
            name = "lem-mailbox";
            src = inputs.lem-mailbox-src;
            lispLibs = with lisp.pkgs; [
              bordeaux-threads
              bt-semaphore
              queues
              queues_dot_simple-cqueue
            ];
          };

          cltpt = mkSimpleASDFSystem {
            name = "cltpt";
            src = inputs.cltpt-src;
            lispLibs = with lisp.pkgs; [
              ironclad
              fiveam
              local-time
              clingon
              bordeaux-threads
            ];
          };

          jsonrpc = lisp.buildASDFSystem {
            pname = "jsonrpc";
            version = "unstable";
            src = inputs.jsonrpc-src;
            systems = [
              "jsonrpc"
              "jsonrpc/transport/stdio"
              "jsonrpc/transport/tcp"
              "jsonrpc/transport/websocket"
              "jsonrpc/transport/local-domain-socket"
            ];
            lispLibs = with lisp.pkgs; [
              yason
              alexandria
              bordeaux-threads
              dissect
              chanl
              vom
              usocket
              trivial-timeout
              cl_plus_ssl
              quri
              fast-io
              trivial-utf-8
              websocket-driver
              clack
              clack-handler-hunchentoot
              event-emitter
              hunchentoot
            ];
          };

          async-process =
            let
              c-lib = pkgs.stdenv.mkDerivation {
                pname = "async-process-native";
                version = "unstable";
                src = inputs.async-process-src;
                nativeBuildInputs = with pkgs; [
                  libtool
                  libffi.dev
                  automake
                  autoconf
                  pkg-config
                ];
                buildPhase = "make PREFIX=$out";
              };
            in
            lisp.buildASDFSystem {
              pname = "async-process";
              version = "unstable";
              src = inputs.async-process-src;
              systems = [ "async-process" ];
              lispLibs = [ lisp.pkgs.cffi ];
              nativeLibs = [ c-lib ];
              nativeBuildInputs = [ pkgs.pkg-config ];
            };

          treeSitterGrammars = with pkgs.tree-sitter-grammars; [
            tree-sitter-json
            tree-sitter-markdown
            tree-sitter-yaml
            tree-sitter-nix
            tree-sitter-python
            tree-sitter-javascript
            tree-sitter-typescript
            tree-sitter-go
            tree-sitter-perl
            tree-sitter-clojure
          ];

          ts-wrapper = pkgs.stdenv.mkDerivation {
            pname = "ts-wrapper";
            version = "0.1.0";
            src = "${inputs.tree-sitter-cl-src}/c-wrapper";
            buildInputs = [ pkgs.tree-sitter ];
            buildPhase = ''
              $CC -shared -fPIC -o libts-wrapper.${sharedLibExt} ts-wrapper.c \
                -I${pkgs.tree-sitter}/include \
                -L${pkgs.tree-sitter}/lib \
                -ltree-sitter
            '';
            installPhase = ''
              mkdir -p $out/lib
              cp libts-wrapper.${sharedLibExt} $out/lib/
            '';
          };

          treeSitterNativeLibs = [ pkgs.tree-sitter ts-wrapper ];
          treeSitterLibPath = pkgs.lib.concatMapStringsSep ":" toString treeSitterGrammars;

          tree-sitter-cl = lisp.buildASDFSystem {
            pname = "tree-sitter-cl";
            version = "unstable";
            src = inputs.tree-sitter-cl-src;
            systems = [ "tree-sitter-cl" ];
            lispLibs = with lisp.pkgs; [
              cffi
              alexandria
              trivial-garbage
            ];
            nativeLibs = treeSitterNativeLibs;
          };

          c-webview = pkgs.stdenv.mkDerivation {
            pname = "c-webview";
            version = "unstable";
            src = inputs.cl-webview-src;
            nativeBuildInputs = with pkgs; [ cmake ninja pkg-config ];
            dontStrip = true;
            buildInputs =
              if pkgs.stdenv.isLinux
              then [ pkgs.webkitgtk_4_1 pkgs.webkitgtk_6_0 pkgs.gtk3 ]
              else [ pkgs.apple-sdk_14 ];

            configurePhase =
              let
                linkerFlags =
                  if pkgs.stdenv.isDarwin
                  then "-Wl,-all_load"
                  else "-Wl,--whole-archive -Wl,--allow-multiple-definition";
              in
              ''
                runHook preConfigure
                cmake -G Ninja -B build -S c \
                  -DCMAKE_BUILD_TYPE=Release \
                  -DCMAKE_CXX_FLAGS="-fvisibility=default -DWEBVIEW_API='extern __attribute__((visibility(\"default\")))'" \
                  -DCMAKE_C_FLAGS="-fvisibility=default -DWEBVIEW_API='extern __attribute__((visibility(\"default\")))'" \
                  -DCMAKE_SHARED_LINKER_FLAGS="${linkerFlags}" \
                  -DFETCHCONTENT_SOURCE_DIR_WEBVIEW=${inputs.webview-upstream-src}
                runHook postConfigure
              '';
            buildPhase = "cmake --build build";
            installPhase = ''
              mkdir -p $out/lib
              cp build/lib/libexample.${sharedLibExt} $out/lib/libwebview.${sharedLibExt}
            '';
          };

          cl-webview = lisp.buildASDFSystem {
            pname = "cl-webview";
            version = "unstable";
            src = inputs.cl-webview-src // { name = "cl-webview-src"; };
            systems = [ "webview" ];
            lispLibs = with lisp.pkgs; [ cffi float-features ];
            nativeLibs = [ c-webview ];
            postPatch = ''
              sed -i 's/(define-foreign-library (libwebview/(define-foreign-library libwebview/' webview.lisp
              sed -i '/:search-path/,/arm64"))))/d' webview.lisp
              sed -i 's/"libwebview\.so\.0\.12\.0"/"libwebview.${sharedLibExt}"/' webview.lisp
            '';
          };

          commonLispLibs =
            [
              micros
              async-process
              jsonrpc
              lem-mailbox
              cltpt
              tree-sitter-cl
            ]
            ++ (with lisp.pkgs; [
              deploy
              iterate
              closer-mop
              trivia
              alexandria
              trivial-gray-streams
              trivial-types
              cl-ppcre
              inquisitor
              babel
              bordeaux-threads
              yason
              log4cl
              split-sequence
              str
              dexador
              cl-mustache
              esrap
              parse-number
              cl-package-locks
              trivial-utf-8
              swank
              _3bmd
              _3bmd-ext-code-blocks
              lisp-preprocessor
              trivial-ws
              trivial-open-browser
              frugal-uuid
              hunchentoot
            ]);

          ncursesLispLibs = with lisp.pkgs; [ cl-charms cl-setlocale ];

          extensionPaths = pkgs.writeText "extension-paths" (toString inputs.organ-mode-src);

          lem-base = lisp.buildASDFSystem {
            pname = "lem-base";
            version = "unstable";
            src = inputs.lem-src // { name = "lem-src"; };
            nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
            lispLibs = commonLispLibs;
            postPatch = ''
              sed -i '1i(pushnew :nix-build *features*)' lem.asd
            '';
            LEM_EXTENSION_PATHS = toString inputs.organ-mode-src;
            buildScript = mkBuildScript { entryPoint = "lem:main"; };
            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              install lem $out/bin
              wrapProgram $out/bin/lem \
                --prefix LD_LIBRARY_PATH : "$LD_LIBRARY_PATH" \
                --prefix DYLD_LIBRARY_PATH : "$DYLD_LIBRARY_PATH"
              runHook postInstall
            '';
          };

          frontendInstallPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            install lem $out/bin
            wrapProgram $out/bin/lem \
              --prefix LD_LIBRARY_PATH : "$LD_LIBRARY_PATH:${treeSitterLibPath}" \
              --prefix DYLD_LIBRARY_PATH : "$DYLD_LIBRARY_PATH"
            runHook postInstall
          '';

          lem-ncurses = lem-base.overrideLispAttrs (o: {
            pname = "lem-ncurses";
            meta.mainProgram = "lem";
            systems = [ "lem-ncurses" "tree-sitter-cl" "lem-tree-sitter" ];
            lispLibs = o.lispLibs ++ ncursesLispLibs;
            nativeLibs = [ pkgs.ncurses ] ++ treeSitterNativeLibs;
            installPhase = frontendInstallPhase;
          });

          lem-sdl2 = lem-base.overrideLispAttrs (o: {
            pname = "lem-sdl2";
            meta.mainProgram = "lem";
            systems = [ "lem-sdl2" "tree-sitter-cl" "lem-tree-sitter" ];
            lispLibs = o.lispLibs ++ (with lisp.pkgs; [
              sdl2
              sdl2-ttf
              sdl2-image
              trivial-main-thread
            ]);
            nativeLibs = (with pkgs; [ SDL2 SDL2_ttf SDL2_image ]) ++ treeSitterNativeLibs;
            installPhase = frontendInstallPhase;
          });

          lem-webview = lem-base.overrideLispAttrs (o: {
            pname = "lem-webview";
            meta.mainProgram = "lem";
            systems = [ "lem-webview" "tree-sitter-cl" "lem-tree-sitter" ];
            buildScript = mkBuildScript { entryPoint = "lem-webview:main"; };
            lispLibs = o.lispLibs ++ [ cl-webview ] ++ (with lisp.pkgs; [
              float-features
              command-line-arguments
            ]);
            nativeLibs =
              [ pkgs.stdenv.cc.cc.lib c-webview ]
              ++ treeSitterNativeLibs
              ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
                pkgs.webkitgtk_4_1
                pkgs.webkitgtk_6_0
                pkgs.gtk3
              ];
            postPatch =
              (o.postPatch or "")
              + (
                if pkgs.stdenv.isLinux
                then ''sed -i 's/fontName:"Monospace"/fontName:"DejaVu Sans Mono"/' frontends/server/frontend/dist/assets/index.js''
                else ''sed -i 's/fontName:"Monospace"/fontName:"Menlo"/' frontends/server/frontend/dist/assets/index.js''
              );
            postInstall =
              ''
                wrapProgram $out/bin/lem \
                  --prefix LD_LIBRARY_PATH : "${treeSitterLibPath}"
              ''
              + pkgs.lib.optionalString pkgs.stdenv.isLinux ''
                wrapProgram $out/bin/lem \
                  --set FONTCONFIG_FILE "${pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; }}" \
                  --prefix XDG_DATA_DIRS : "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}" \
                  --prefix XDG_DATA_DIRS : "${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}"
              '';
          });

          allLispLibs = commonLispLibs ++ ncursesLispLibs ++ [ cl-webview ] ++ (with lisp.pkgs; [
            float-features
            command-line-arguments
          ]);

          mkPathCollector =
            { name, findPattern }:
            pkgs.runCommand name { packages = allLispLibs; } ''
              collect_deps() {
                local pkg="$1"
                local seen_file="$2"
                if grep -qxF "$pkg" "$seen_file" 2>/dev/null; then return; fi
                echo "$pkg" >> "$seen_file"
                find "$pkg" ${findPattern} 2>/dev/null | while read f; do
                  dirname "$f" >> "$out"
                done
                if [ -f "$pkg/nix-support/propagated-build-inputs" ]; then
                  for dep in $(cat "$pkg/nix-support/propagated-build-inputs"); do
                    if [ -n "$dep" ] && [ -d "$dep" ]; then
                      collect_deps "$dep" "$seen_file"
                    fi
                  done
                fi
              }
              touch "$out"
              seen=$(mktemp)
              for pkg in $packages; do collect_deps "$pkg" "$seen"; done
              rm "$seen"
              sort -u "$out" -o "$out"
            '';

          lispLibPaths = mkPathCollector {
            name = "lisp-lib-paths";
            findPattern = "-name '*.asd' -type f";
          };

          nativeLibPaths = mkPathCollector {
            name = "native-lib-paths";
            findPattern = ''-type f \( -name "*.so" -o -name "*.dylib" \)'';
          };

          lemReplNativeLibs =
            [ pkgs.ncurses pkgs.openssl c-webview ]
            ++ treeSitterNativeLibs
            ++ treeSitterGrammars
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.webkitgtk_4_1 pkgs.gtk3 ];

          asdfFaslPath = "${lem-base.asdfFasl}/asdf.${lem-base.faslExt}";

          lispInitCode = ''
            (load "${asdfFaslPath}")
            (pushnew :nix-build *features*)
            (asdf:initialize-output-translations
             `(:output-translations
               (t (,(merge-pathnames ".cache/lem-fasl/" (user-homedir-pathname)) :**/ :*.*.*))
               :ignore-inherited-configuration))

            ;; monkey-patch compile-file* to allow #. and suppress errors
            (setf (symbol-function 'uiop/lisp-build:compile-file*)
                  (lambda (input-file &key output-file (external-format :utf-8) &allow-other-keys)
                    (when output-file (ensure-directories-exist output-file))
                    (let ((*read-eval* t) (sb-ext:*on-package-variance* nil))
                      (multiple-value-bind (truename warnings-p failure-p)
                          (compile-file input-file :output-file output-file :external-format external-format)
                        (declare (ignore failure-p warnings-p))
                        (values (or truename (when (and output-file (probe-file output-file)) (truename output-file))) nil nil)))))

            (setf (symbol-function 'uiop/lisp-build:check-lisp-compile-results)
                  (lambda (output-truename warnings-p failure-p &optional context-format context-arguments)
                    (declare (ignore context-format context-arguments failure-p warnings-p))
                    output-truename))

            ;; add nix-provided extensions
            (with-open-file (f (uiop:getenv "LEM_EXTENSION_PATHS") :if-does-not-exist nil)
              (when f
                (loop for line = (read-line f nil nil) while line
                      when (probe-file line)
                      do (pushnew (pathname (concatenate 'string line "/")) asdf:*central-registry* :test #'equal))))
            ;; add lem source directory
            (pushnew (pathname (uiop:getenv "LEM_SOURCE_DIR")) asdf:*central-registry* :test #'equal)
            ;; add nix lisp library paths
            (with-open-file (f (uiop:getenv "LEM_LIB_PATHS"))
              (loop for line = (read-line f nil nil) while line
                    when (probe-file line)
                    do (pushnew (pathname (concatenate 'string line "/")) asdf:*central-registry* :test #'equal)))
          '';

          lemReplEnvSetup = ''
            export LEM_LIB_PATHS="${lispLibPaths}"
            export LEM_SOURCE_DIR="''${LEM_SOURCE_DIR:-${inputs.lem-src}/}"
            export LEM_EXTENSION_PATHS="${extensionPaths}"
            NATIVE_PATHS=$(cat "${nativeLibPaths}" | tr '\n' ':')
            export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath lemReplNativeLibs}:$NATIVE_PATHS"
            export DYLD_LIBRARY_PATH="$LD_LIBRARY_PATH"
          '';

          lem-repl-bin = pkgs.writeShellScriptBin "lem-repl" ''
            ${lemReplEnvSetup}
            LEM_INIT=$(mktemp)
            cat > "$LEM_INIT" << 'INITEOF'
            ${lispInitCode}
            INITEOF
            exec ${pkgs.sbcl}/bin/sbcl --load "$LEM_INIT" "$@"
          '';

          lem-webview-run = pkgs.writeShellScriptBin "lem-webview" ''
            exec ${lem-repl-bin}/bin/lem-repl --eval '(asdf:load-system "lem-webview")' --eval '(lem-webview:main)' "$@"
          '';
        in
        {
          overlayAttrs = { inherit lem-ncurses lem-sdl2 lem-webview; };

          packages = {
            inherit lem-ncurses lem-sdl2 lem-webview;
            lem-repl = lem-repl-bin;
            lem-webview-run = lem-webview-run;
            default = lem-ncurses;
          };

          apps = {
            lem-ncurses = { type = "app"; program = lem-ncurses; };
            lem-sdl2 = { type = "app"; program = lem-sdl2; };
            lem-webview = { type = "app"; program = lem-webview; };
            default = { type = "app"; program = lem-ncurses; };
          };

          devShells.lem-repl = pkgs.mkShell {
            packages = [ pkgs.sbcl ] ++ lemReplNativeLibs;
            shellHook = ''
              export LEM_SOURCE_DIR="$PWD/"
              ${lemReplEnvSetup}
              export LEM_INIT=$(mktemp)
              cat > "$LEM_INIT" << 'INITEOF'
              ${lispInitCode}
              INITEOF
              lem-sbcl() { sbcl --load "$LEM_INIT" "$@"; }
              export -f lem-sbcl
              echo "  lem-sbcl                            # SBCL with lem libs"
              echo "  (asdf:load-system \"lem-ncurses\")  # load a frontend"
              echo "  (lem:lem)                           # start lem"
            '';
          };

          devShells.default = pkgs.mkShell {
            packages =
              (with pkgs; [
                sbcl
                sbclPackages.qlot-cli
                gnumake
                pkg-config
                nodejs_22
                ncurses
                SDL2
                SDL2_ttf
                SDL2_image
                openssl
                perl538Packages.PLS
                clojure
                clojure-lsp
                leiningen
                babashka
                nixfmt-rfc-style
                direnv
              ])
              ++ treeSitterNativeLibs
              ++ treeSitterGrammars
              ++ pkgs.lib.optionals pkgs.stdenv.isLinux (with pkgs; [ webkitgtk_4_1 gtk3 ]);

            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (
              (with pkgs; [ ncurses SDL2 SDL2_ttf SDL2_image openssl ])
              ++ treeSitterNativeLibs
              ++ treeSitterGrammars
              ++ pkgs.lib.optionals pkgs.stdenv.isLinux (with pkgs; [ webkitgtk_4_1 gtk3 ])
            );

            shellHook = ''
              if [ -f "$HOME/lem-project/tree-sitter-cl/c-wrapper/libts-wrapper.so" ]; then
                export LD_LIBRARY_PATH="$HOME/lem-project/tree-sitter-cl/c-wrapper:$LD_LIBRARY_PATH"
              fi
              echo "  SBCL: $(sbcl --version)"
              echo "  qlot install"
              echo "  make ncurses"
            '';
          };
        };
    };
}