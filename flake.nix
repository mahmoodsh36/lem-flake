{
  description = "lem flake";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:nixos/nixpkgs/release-25.11";
    cltpt = {
      url = "github:mahmoodsh36/cltpt";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lem = {
      # url = "github:mahmoodsh36/lem/organ-mode";
      url = "github:mahmoodsh36/lem";
      flake = false;
    };
    micros = {
      url = "github:lem-project/micros";
      flake = false;
    };
    jsonrpc = {
      url = "github:cxxxr/jsonrpc";
      flake = false;
    };
    async-process = {
      url = "github:lem-project/async-process";
      flake = false;
    };
    lem-mailbox = {
      url = "github:lem-project/lem-mailbox";
      flake = false;
    };
    organ-mode = {
      url = "github:mahmoodsh36/organ-mode";
      flake = false;
    };
    tree-sitter-cl = {
      url = "github:lem-project/tree-sitter-cl";
      flake = false;
    };
    cl-webview = {
      url = "github:lem-project/webview";
      flake = false;
    };
    webview-upstream = {
      url = "github:webview/webview";
      flake = false;
    };
  };

  outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } {
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

          # common monkey-patches for ASDF/SBCL build process
          lispMonkeyPatches = ''
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
          '';

          asdfPathHelpers = ''
            (defun nix-cl-user::normalize-existing-directory (path)
              (when (and path
                         (not (string= path ""))
                         (probe-file path))
                (namestring
                 (uiop:ensure-directory-pathname (truename path)))))

            (defun nix-cl-user::collect-paths-from-spec (spec)
              (let ((paths))
                (labels ((add-path (path)
                           (let ((normalized (nix-cl-user::normalize-existing-directory path)))
                             (when normalized
                               (pushnew normalized paths :test #'string=)))))
                  (when (and spec (not (string= spec "")))
                    (cond
                      ((uiop:directory-exists-p spec)
                       (add-path spec))
                      ((probe-file spec)
                       (with-open-file (f spec :if-does-not-exist nil)
                         (when f
                           (loop for line = (read-line f nil nil)
                                 while line
                                 do (add-path line)))))
                      (t
                       (dolist (path (uiop:split-string spec :separator '(#\newline #\space)))
                         (add-path path)))))
                  (nreverse paths))))

            (defun nix-cl-user::register-central-registry-paths (paths)
              (dolist (path paths)
                (pushnew (pathname path) asdf:*central-registry* :test #'equal)))

            (defun nix-cl-user::register-central-registry-spec (spec)
              (nix-cl-user::register-central-registry-paths
               (nix-cl-user::collect-paths-from-spec spec)))

            (defun nix-cl-user::register-source-registry-tree (path)
              (let ((normalized (nix-cl-user::normalize-existing-directory path)))
                (when normalized
                  (asdf:initialize-source-registry
                   `(:source-registry
                     (:tree ,(pathname normalized))
                     :inherit-configuration)))))
          '';

          # helper to generate the Lisp build script used by all variants
          mkBuildScript =
            {
              entryPoint ? "lem:main",
              faslTranslationPaths ? [ "/nix/store" ],
            }:
            let
              faslTranslationForms = pkgs.lib.concatMapStringsSep "\n" (path: ''
                (#p"${path}/**/*.*"
                 ,(merge-pathnames "fasl-cache${path}/**/*.*" (uiop:getcwd)))'')
                faslTranslationPaths;
            in
            pkgs.writeText "build-lem.lisp" ''
              (defpackage :nix-cl-user (:use :cl))
              (in-package :nix-cl-user)

              ;; load ASDF
              (load "${lem-base.asdfFasl}/asdf.${lem-base.faslExt}")

              ${asdfPathHelpers}

              ${pkgs.lib.optionalString (faslTranslationPaths != []) ''
                ;; redirect selected read-only source trees to a local fasl-cache directory
                (asdf:initialize-output-translations
                  `(:output-translations
                    ${faslTranslationForms}
                    :inherit-configuration))
              ''}

              ;; add extension paths (like organ-mode) to the registry
              (nix-cl-user::register-central-registry-spec (uiop:getenv "LEM_EXTENSION_PATHS"))

              ;; load systems
              (mapcar #'asdf:load-system (uiop:split-string (uiop:getenv "systems")))

              ;; runtime hook: configure ASDF for runtime
              ;; - redirect FASL output to user cache
              ;; - register all loaded systems as immutable so ASDF won't recompile them
              ;;   (recompilation reloads buffer.lisp which redefines make-buffer-point
              ;;    back to the default that returns plain POINT instead of CURSOR,
              ;;    causing cursor-mark to fail on buffers created during recompilation)
              (defun nix-cl-user::configure-asdf-for-runtime ()
                (nix-cl-user::register-central-registry-spec
                 (uiop:getenv "LEM_EXTENSION_PATHS"))
                (asdf:initialize-output-translations
                  `(:output-translations
                    (t (,(merge-pathnames ".cache/lem-fasl/" (user-homedir-pathname)) :**/ :*.*.*))
                    :inherit-configuration))
                ;; mark all currently loaded systems as immutable so ASDF
                ;; won't try to recompile them when init.lisp loads extensions
                (dolist (system (asdf:already-loaded-systems))
                  (asdf:register-immutable-system system)))
              (pushnew 'nix-cl-user::configure-asdf-for-runtime uiop:*image-restore-hook*)

              ;; dump image
              (setf uiop:*image-entry-point* #'${entryPoint})
              (uiop:dump-image "lem" :executable t :compression t)
            '';

          micros = mkSimpleASDFSystem {
            name = "micros";
            src = inputs.micros;
          };

          lem-mailbox = mkSimpleASDFSystem {
            name = "lem-mailbox";
            src = inputs.lem-mailbox;
            lispLibs = with lisp.pkgs; [
              bordeaux-threads
              bt-semaphore
              queues
              queues_dot_simple-cqueue
            ];
          };

          jsonrpc = lisp.buildASDFSystem {
            pname = "jsonrpc";
            version = "unstable";
            src = inputs.jsonrpc;
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

          async-process-native = pkgs.stdenv.mkDerivation {
            pname = "async-process-native";
            version = "unstable";
            src = inputs.async-process;
            nativeBuildInputs = with pkgs; [
              libtool
              libffi.dev
              automake
              autoconf
              pkg-config
            ];
            buildPhase = "make PREFIX=$out";
          };

          async-process = lisp.buildASDFSystem {
            pname = "async-process";
            version = "unstable";
            src = inputs.async-process;
            systems = [ "async-process" ];
            lispLibs = [ lisp.pkgs.cffi ];
            nativeLibs = [ async-process-native ];
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
            src = "${inputs.tree-sitter-cl}/c-wrapper";
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
            src = inputs.tree-sitter-cl;
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
            src = inputs.cl-webview;
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
                    -DFETCHCONTENT_SOURCE_DIR_WEBVIEW=${inputs.webview-upstream}
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
            src = inputs.cl-webview // { name = "cl-webview"; };
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
              inputs.cltpt.packages.${pkgs.stdenv.system}.cltpt-lib
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
              rove
            ]);

          ncursesLispLibs = with lisp.pkgs; [ cl-charms cl-setlocale ];

          extensionPaths = pkgs.writeText "extension-paths" (toString inputs.organ-mode);

          lem-base = lisp.buildASDFSystem {
            pname = "lem-base";
            version = "unstable";
            src = inputs.lem // { name = "lem"; };
            nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
            lispLibs = commonLispLibs;
            postPatch = ''
              sed -i '1i(pushnew :nix-build *features*)' lem.asd
            '';
            LEM_EXTENSION_PATHS = toString inputs.organ-mode;
            buildScript = mkBuildScript {
              entryPoint = "lem:main";
              faslTranslationPaths = [ (toString inputs.organ-mode) ];
            };
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

          mkWebviewInstallPhase =
            binaryName:
            ''
              runHook preInstall
              mkdir -p $out/bin
              install lem $out/bin/${binaryName}
              wrapProgram $out/bin/${binaryName} \
                --set LEM_EXTENSION_PATHS "${inputs.organ-mode}" \
                --prefix LD_LIBRARY_PATH : "$LD_LIBRARY_PATH:${treeSitterLibPath}" \
                --prefix DYLD_LIBRARY_PATH : "$DYLD_LIBRARY_PATH"
            ''
            + pkgs.lib.optionalString pkgs.stdenv.isLinux ''
              wrapProgram $out/bin/${binaryName} \
                --set FONTCONFIG_FILE "${pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; }}" \
                --prefix XDG_DATA_DIRS : "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}" \
                --prefix XDG_DATA_DIRS : "${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}"
            ''
            + ''
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

          lem-webview-lib = lisp.buildASDFSystem {
            pname = "lem-webview-lib";
            version = "unstable";
            src = inputs.lem // { name = "lem-patched"; };

            # lem-webview and lem-tree-sitter are the key systems
            systems = [ "lem-webview" "lem-tree-sitter" ];

            # dependencies required by these systems
            lispLibs = commonLispLibs ++ [ cl-webview ] ++ (with lisp.pkgs; [
              float-features
              command-line-arguments
              iterate
              trivial-types
            ]);

            nativeLibs = [ c-webview ]
              ++ treeSitterNativeLibs
              ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
                 pkgs.webkitgtk_4_1
                 pkgs.webkitgtk_6_0
                 pkgs.gtk3
                 pkgs.stdenv.cc.cc.lib  # provides libstdc++.so.6
               ];

            # skip fixupPhase on darwin (patchelf not needed/available)
            fixupPhase = pkgs.lib.optionalString pkgs.stdenv.isDarwin "";
            dontFixup = pkgs.stdenv.isDarwin;

            # patch steps for the prebuilt webview build
            postPatch = ''
              # add :nix-build features
              sed -i '1i(pushnew :nix-build *features*)' lem.asd

              # add organ-mode path manually to ASDF registry so it can be found during build
              sed -i '1i(pushnew (pathname "${inputs.organ-mode}/") asdf:*central-registry* :test #'\'''equal)' lem.asd

              # monkey-patch compile-file* to allow #. and suppress errors
              cat > configure-asdf.lisp <<EOF
              (defpackage :nix-build-config (:use :cl))
              (in-package :nix-build-config)

              ${lispMonkeyPatches}
              EOF
              sed -i '1i(load "configure-asdf.lisp")' lem.asd
            '' + (
                if pkgs.stdenv.isLinux
                then ''sed -i 's/fontName:"Monospace"/fontName:"DejaVu Sans Mono"/' frontends/server/frontend/dist/assets/index.js''
                else ''sed -i 's/fontName:"Monospace"/fontName:"Menlo"/' frontends/server/frontend/dist/assets/index.js''
              );
            LEM_EXTENSION_PATHS = toString inputs.organ-mode;
          };

          lem-webview = lem-webview-lib.overrideLispAttrs (o: {
            pname = "lem-webview";
            meta.mainProgram = "lem-webview";
            LEM_EXTENSION_PATHS = toString inputs.organ-mode;

            # build a dumped executable while reusing prebuilt store FASLs for packaged
            # dependencies. only organ-mode's source tree gets a local writable FASL cache
            # because lem/extensions depends on it directly.
            buildScript = mkBuildScript {
              entryPoint = "lem-webview:main";
              faslTranslationPaths = [ (toString inputs.organ-mode) ];
            };

            nativeBuildInputs = (o.nativeBuildInputs or []) ++ [ pkgs.makeBinaryWrapper ];

            installPhase = mkWebviewInstallPhase "lem-webview";
          });

          lem-webview-app =
            let
              desktopItem = pkgs.makeDesktopItem {
                name = "lem";
                exec = "lem-webview";
                icon = "lem";
                desktopName = "Lem";
                genericName = "Text Editor";
                categories = [ "Development" "TextEditor" ];
              };
            in
            pkgs.stdenv.mkDerivation {
              pname = "lem-webview-app";
              version = "unstable";
              nativeBuildInputs = pkgs.lib.optional pkgs.stdenv.hostPlatform.isDarwin pkgs.desktopToDarwinBundle;
              buildInputs = [ lem-webview ];
              dontUnpack = true;
              installPhase = ''
                runHook preInstall
                mkdir -p $out/bin
                ln -s ${lem-webview}/bin/lem-webview $out/bin/lem-webview
                mkdir -p $out/share/applications
                cp -r ${desktopItem}/share/applications/* $out/share/applications/
                runHook postInstall
              '';
              meta.mainProgram = "lem-webview";
            };

          allLispLibs = commonLispLibs ++ ncursesLispLibs ++ [ cl-webview lem-ncurses ] ++ (with lisp.pkgs; [
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
            [ pkgs.ncurses pkgs.openssl c-webview async-process-native ]
            ++ treeSitterNativeLibs
            ++ treeSitterGrammars
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.webkitgtk_4_1 pkgs.gtk3 pkgs.stdenv.cc.cc.lib ];

          asdfFaslPath = "${lem-base.asdfFasl}/asdf.${lem-base.faslExt}";

          lispInitCode = ''
            (defpackage :nix-cl-user (:use :cl))
            (in-package :nix-cl-user)

            (load "${asdfFaslPath}")
            (pushnew :nix-build *features*)

            ${asdfPathHelpers}

            (defun nix-cl-user::collect-runtime-source-paths ()
              (remove-duplicates
               (append
                (nix-cl-user::collect-paths-from-spec (uiop:getenv "LEM_SOURCE_DIR"))
                (nix-cl-user::collect-paths-from-spec (uiop:getenv "LEM_EXTENSION_PATHS")))
               :test #'string=))

            (defun nix-cl-user::configure-runtime-output-translations ()
              (let ((source-paths (nix-cl-user::collect-runtime-source-paths)))
                (asdf:initialize-output-translations
                 `(:output-translations
                   ,@(mapcar
                      (lambda (path)
                        (list
                         (pathname (concatenate 'string path "**/*.*"))
                         (merge-pathnames
                          (concatenate 'string ".cache/lem-fasl" path "**/*.*")
                          (user-homedir-pathname))))
                      source-paths)
                   (#p"/nix/store/**/*.*" #p"/nix/store/**/*.*")
                   :ignore-inherited-configuration))))

            (defun nix-cl-user::configure-runtime-central-registries ()
              (nix-cl-user::register-central-registry-spec (uiop:getenv "LEM_EXTENSION_PATHS"))
              (nix-cl-user::register-central-registry-spec (uiop:getenv "LEM_LIB_PATHS")))

            (defun nix-cl-user::configure-runtime-source-registries ()
              (nix-cl-user::register-source-registry-tree (uiop:getenv "LEM_SOURCE_DIR")))

            (nix-cl-user::configure-runtime-output-translations)

            ;; monkey-patch compile-file* to allow #. and suppress errors
            ${lispMonkeyPatches}

            (nix-cl-user::configure-runtime-central-registries)
            (nix-cl-user::configure-runtime-source-registries)
          '';

          lemReplEnvSetup = ''
            export LEM_LIB_PATHS="${lispLibPaths}"
            export LEM_SOURCE_DIR="''${LEM_SOURCE_DIR:-${inputs.lem}/}"
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

          organ-mode-tests-runner = pkgs.writeShellScriptBin "organ-mode-tests" ''
            exec ${lem-repl-bin}/bin/lem-repl --load "${inputs.organ-mode}/run-tests.lisp" "$@"
          '';
        in {
          overlayAttrs = { inherit lem-ncurses lem-sdl2 lem-webview lem-webview-lib lem-webview-app; };

          packages = {
            inherit lem-ncurses lem-sdl2 lem-webview lem-webview-lib lem-webview-app cl-webview;
            lem-repl = lem-repl-bin;
            organ-mode-tests = organ-mode-tests-runner;
            default = lem-ncurses;
          };

          apps = {
            lem-ncurses = { type = "app"; program = lem-ncurses; };
            lem-sdl2 = { type = "app"; program = lem-sdl2; };
            lem-webview = { type = "app"; program = lem-webview; };
            lem-webview-app = { type = "app"; program = lem-webview-app; };
            organ-mode-tests = { type = "app"; program = organ-mode-tests-runner; };
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