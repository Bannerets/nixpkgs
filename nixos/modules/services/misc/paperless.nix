{ config, pkgs, lib, ... }:

with lib;
let
  cfg = config.services.paperless;
  pkg = cfg.package;

  defaultUser = "paperless";

  # Don't start a redis instance if the user sets a custom redis connection
  enableRedis = !hasAttr "PAPERLESS_REDIS" cfg.extraConfig;
  redisServer = config.services.redis.servers.paperless;

  env = {
    PAPERLESS_DATA_DIR = cfg.dataDir;
    PAPERLESS_MEDIA_ROOT = cfg.mediaDir;
    PAPERLESS_CONSUMPTION_DIR = cfg.consumptionDir;
    GUNICORN_CMD_ARGS = "--bind=${cfg.address}:${toString cfg.port}";
  } // (
    lib.mapAttrs (_: toString) cfg.extraConfig
  ) // (optionalAttrs enableRedis {
    PAPERLESS_REDIS = "unix://${redisServer.unixSocket}";
  });

  manage = let
    setupEnv = lib.concatStringsSep "\n" (mapAttrsToList (name: val: "export ${name}=\"${val}\"") env);
  in pkgs.writeShellScript "manage" ''
    ${setupEnv}
    exec ${pkg}/bin/paperless-ngx "$@"
  '';

  # Secure the services
  defaultServiceConfig = {
    TemporaryFileSystem = "/:ro";
    BindReadOnlyPaths = [
      "/nix/store"
      "-/etc/resolv.conf"
      "-/etc/nsswitch.conf"
      "-/etc/hosts"
      "-/etc/localtime"
      "-/run/postgresql"
    ] ++ (optional enableRedis redisServer.unixSocket);
    BindPaths = [
      cfg.consumptionDir
      cfg.dataDir
      cfg.mediaDir
    ];
    CapabilityBoundingSet = "";
    # ProtectClock adds DeviceAllow=char-rtc r
    DeviceAllow = "";
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateMounts = true;
    PrivateNetwork = true;
    PrivateTmp = true;
    PrivateUsers = true;
    ProtectClock = true;
    # Breaks if the home dir of the user is in /home
    # Also does not add much value in combination with the TemporaryFileSystem.
    # ProtectHome = true;
    ProtectHostname = true;
    # Would re-mount paths ignored by temporary root
    #ProtectSystem = "strict";
    ProtectControlGroups = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectProc = "invisible";
    # Don't restrict ProcSubset because django-q requires read access to /proc/stat
    # to query CPU and memory information.
    # Note that /proc only contains processes of user `paperless`, so this is safe.
    # ProcSubset = "pid";
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SupplementaryGroups = optional enableRedis redisServer.user;
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" "~@privileged @resources @setuid @keyring" ];
    # Does not work well with the temporary root
    #UMask = "0066";
  };
in
{
  meta.maintainers = with maintainers; [ earvstedt Flakebi ];

  imports = [
    (mkRenamedOptionModule [ "services" "paperless-ng" ] [ "services" "paperless" ])
  ];

  options.services.paperless = {
    enable = mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable Paperless.

        When started, the Paperless database is automatically created if it doesn't
        exist and updated if the Paperless package has changed.
        Both tasks are achieved by running a Django migration.

        A script to manage the Paperless instance (by wrapping Django's manage.py) is linked to
        <literal>''${dataDir}/paperless-manage</literal>.
      '';
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/paperless";
      description = "Directory to store the Paperless data.";
    };

    mediaDir = mkOption {
      type = types.str;
      default = "${cfg.dataDir}/media";
      defaultText = literalExpression ''"''${dataDir}/media"'';
      description = "Directory to store the Paperless documents.";
    };

    consumptionDir = mkOption {
      type = types.str;
      default = "${cfg.dataDir}/consume";
      defaultText = literalExpression ''"''${dataDir}/consume"'';
      description = "Directory from which new documents are imported.";
    };

    consumptionDirIsPublic = mkOption {
      type = types.bool;
      default = false;
      description = "Whether all users can write to the consumption dir.";
    };

    passwordFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/keys/paperless-password";
      description = ''
        A file containing the superuser password.

        A superuser is required to access the web interface.
        If unset, you can create a superuser manually by running
        <literal>''${dataDir}/paperless-manage createsuperuser</literal>.

        The default superuser name is <literal>admin</literal>. To change it, set
        option <option>extraConfig.PAPERLESS_ADMIN_USER</option>.
        WARNING: When changing the superuser name after the initial setup, the old superuser
        will continue to exist.

        To disable login for the web interface, set the following:
        <literal>extraConfig.PAPERLESS_AUTO_LOGIN_USERNAME = "admin";</literal>.
        WARNING: Only use this on a trusted system without internet access to Paperless.
      '';
    };

    address = mkOption {
      type = types.str;
      default = "localhost";
      description = "Web interface address.";
    };

    port = mkOption {
      type = types.port;
      default = 28981;
      description = "Web interface port.";
    };

    extraConfig = mkOption {
      type = types.attrs;
      default = {};
      description = ''
        Extra paperless config options.

        See <link xlink:href="https://paperless-ngx.readthedocs.io/en/latest/configuration.html">the documentation</link>
        for available options.
      '';
      example = {
        PAPERLESS_OCR_LANGUAGE = "deu+eng";
        PAPERLESS_DBHOST = "/run/postgresql";
      };
    };

    user = mkOption {
      type = types.str;
      default = defaultUser;
      description = "User under which Paperless runs.";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.paperless-ngx;
      defaultText = literalExpression "pkgs.paperless-ngx";
      description = "The Paperless package to use.";
    };
  };

  config = mkIf cfg.enable {
    services.redis.servers.paperless.enable = mkIf enableRedis true;

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' - ${cfg.user} ${config.users.users.${cfg.user}.group} - -"
      "d '${cfg.mediaDir}' - ${cfg.user} ${config.users.users.${cfg.user}.group} - -"
      (if cfg.consumptionDirIsPublic then
        "d '${cfg.consumptionDir}' 777 - - - -"
      else
        "d '${cfg.consumptionDir}' - ${cfg.user} ${config.users.users.${cfg.user}.group} - -"
      )
    ];

    systemd.services.paperless-scheduler = {
      description = "Paperless scheduler";
      serviceConfig = defaultServiceConfig // {
        User = cfg.user;
        ExecStart = "${pkg}/bin/paperless-ngx qcluster";
        Restart = "on-failure";
        # The `mbind` syscall is needed for running the classifier.
        SystemCallFilter = defaultServiceConfig.SystemCallFilter ++ [ "mbind" ];
        # Needs to talk to mail server for automated import rules
        PrivateNetwork = false;
      };
      environment = env;
      wantedBy = [ "multi-user.target" ];
      wants = [ "paperless-consumer.service" "paperless-web.service" ];

      preStart = ''
        ln -sf ${manage} ${cfg.dataDir}/paperless-manage

        # Auto-migrate on first run or if the package has changed
        versionFile="${cfg.dataDir}/src-version"
        if [[ $(cat "$versionFile" 2>/dev/null) != ${pkg} ]]; then
          ${pkg}/bin/paperless-ngx migrate
          echo ${pkg} > "$versionFile"
        fi
      ''
      + optionalString (cfg.passwordFile != null) ''
        export PAPERLESS_ADMIN_USER="''${PAPERLESS_ADMIN_USER:-admin}"
        export PAPERLESS_ADMIN_PASSWORD=$(cat "${cfg.dataDir}/superuser-password")
        superuserState="$PAPERLESS_ADMIN_USER:$PAPERLESS_ADMIN_PASSWORD"
        superuserStateFile="${cfg.dataDir}/superuser-state"

        if [[ $(cat "$superuserStateFile" 2>/dev/null) != $superuserState ]]; then
          ${pkg}/bin/paperless-ngx manage_superuser
          echo "$superuserState" > "$superuserStateFile"
        fi
      '';
    } // optionalAttrs enableRedis {
      after = [ "redis-paperless.service" ];
    };

    # Reading the user-provided password file requires root access
    systemd.services.paperless-copy-password = mkIf (cfg.passwordFile != null) {
      requiredBy = [ "paperless-scheduler.service" ];
      before = [ "paperless-scheduler.service" ];
      serviceConfig = {
        ExecStart = ''
          ${pkgs.coreutils}/bin/install --mode 600 --owner '${cfg.user}' --compare \
            '${cfg.passwordFile}' '${cfg.dataDir}/superuser-password'
        '';
        Type = "oneshot";
      };
    };

    systemd.services.paperless-consumer = {
      description = "Paperless document consumer";
      serviceConfig = defaultServiceConfig // {
        User = cfg.user;
        ExecStart = "${pkg}/bin/paperless-ngx document_consumer";
        Restart = "on-failure";
      };
      environment = env;
      # Bind to `paperless-scheduler` so that the consumer never runs
      # during migrations
      bindsTo = [ "paperless-scheduler.service" ];
      after = [ "paperless-scheduler.service" ];
    };

    systemd.services.paperless-web = {
      description = "Paperless web server";
      serviceConfig = defaultServiceConfig // {
        User = cfg.user;
        ExecStart = ''
          ${pkgs.python3Packages.gunicorn}/bin/gunicorn \
            -c ${pkg}/lib/paperless-ngx/gunicorn.conf.py paperless.asgi:application
        '';
        Restart = "on-failure";

        # gunicorn needs setuid, liblapack needs mbind
        SystemCallFilter = defaultServiceConfig.SystemCallFilter ++ [ "@setuid mbind" ];
        # Needs to serve web page
        PrivateNetwork = false;
      } // lib.optionalAttrs (cfg.port < 1024) {
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      };
      environment = env // {
        PATH = mkForce pkg.path;
        PYTHONPATH = "${pkg.pythonPath}:${pkg}/lib/paperless-ngx/src";
      };
      # Allow the web interface to access the private /tmp directory of the server.
      # This is required to support uploading files via the web interface.
      unitConfig.JoinsNamespaceOf = "paperless-scheduler.service";
      # Bind to `paperless-scheduler` so that the web server never runs
      # during migrations
      bindsTo = [ "paperless-scheduler.service" ];
      after = [ "paperless-scheduler.service" ];
    };

    users = optionalAttrs (cfg.user == defaultUser) {
      users.${defaultUser} = {
        group = defaultUser;
        uid = config.ids.uids.paperless;
        home = cfg.dataDir;
      };

      groups.${defaultUser} = {
        gid = config.ids.gids.paperless;
      };
    };
  };
}
