{ pkgs, lib, config, inputs, ... }:

{
  # https://devenv.sh/basics/
  env.GREET = "devenv";

  # Shared source of truth for benchmark config — consumed by the justfile.
  env.SYSTEM_CA_BUNDLE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  env.CDP_ENDPOINT = "https://ml-a995e882-1c8.apps.hgx-ocp.kcloud-dev.comops.cloudera.com/namespaces/serving-default/endpoints/epgptoss120b/v1";
  env.CDP_MODEL = "openai/gpt-oss-120b";

  # https://devenv.sh/packages/
  packages = with pkgs; [
    cacert
    docker
    docker-compose
    git
    just
    openssl
  ];

  # https://devenv.sh/languages/
  # languages.rust.enable = true;

  languages.python = {
    enable = true;
    package = pkgs.python312;
    uv.enable = true;
  };


  # https://devenv.sh/processes/
  # processes.dev.exec = "${lib.getExe pkgs.watchexec} -n -- ls -la";

  # https://devenv.sh/services/
  # services.postgres.enable = true;

  # https://devenv.sh/scripts/
  scripts.hello.exec = ''
    echo hello from $GREET
  '';

  # Shim `docker` to host `podman` so tools that shell out to `docker`
  # (e.g. harbor) work without Docker being installed.
  # Unset LD_LIBRARY_PATH so Nix gcc libs don't contaminate system podman
  # on Linux (glibc version mismatch).
  scripts.docker.exec = ''exec env -u LD_LIBRARY_PATH podman "$@"'';

  # https://devenv.sh/basics/
  enterShell = ''
    hello         # Run scripts directly
    git --version # Use packages

    # Point docker clients at the podman socket so `docker compose`
    # (via the docker shim) connects to podman.
    # On Linux podman runs natively; on macOS/Windows it needs a machine.
    if command -v podman >/dev/null 2>&1; then
      if [[ "$(uname)" == "Linux" ]]; then
        sock="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
      else
        sock=$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null || true)
      fi
      if [ -n "$sock" ] && [ -S "$sock" ]; then
        export DOCKER_HOST="unix://$sock"
      fi
    fi
  '';

  # https://devenv.sh/tasks/
  # tasks = {
  #   "myproj:setup".exec = "mytool build";
  #   "devenv:enterShell".after = [ "myproj:setup" ];
  # };

  # https://devenv.sh/tests/
  enterTest = ''
    echo "Running tests"
    git --version | grep --color=auto "${pkgs.git.version}"
  '';

  # https://devenv.sh/git-hooks/
  # git-hooks.hooks.shellcheck.enable = true;

  # See full reference at https://devenv.sh/reference/options/
}
