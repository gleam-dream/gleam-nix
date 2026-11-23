{
  lib,
  writeText,
  postgresql,
}:
# A service is { name; nativeBuildInputs; start; stop; log; env; }. The check
# runs `start` and `stop` with $SERVICE_STATE, a fresh directory, and
# $SERVICE_PORT, a free port, set for that run. `env` maps variable names to
# shell words expanded after start with those two variables; `log` is the file
# the check prints when it fails.
{
  postgresql =
    {
      package ? postgresql,
      name ? "postgresql",
      # SQL run by the superuser `postgres` once the server accepts connections.
      init ? "",
      env ? {
        PGHOST = "127.0.0.1";
        PGPORT = "$SERVICE_PORT";
        PGUSER = "postgres";
      },
      # Further names for the same server, such as a connection URL.
      aliases ? { },
    }:
    let
      initFile = writeText "${name}-init.sql" init;
      redefined = builtins.filter (alias: env ? ${alias}) (lib.attrNames aliases);
    in
    if redefined != [ ] then
      throw "gleam-nix: service ${name} aliases names it already sets: ${lib.concatStringsSep ", " redefined}."
    else
      {
        inherit name;
        nativeBuildInputs = [ package ];
        env = env // aliases;
        log = "$SERVICE_STATE/postgresql.log";
        start = ''
          initdb --pgdata="$SERVICE_STATE/data" --username=postgres --auth=trust \
            --no-locale --encoding=UTF8 > "$SERVICE_STATE/initdb.log"
          pg_ctl --pgdata="$SERVICE_STATE/data" --log="$SERVICE_STATE/postgresql.log" --wait \
            --options="-h 127.0.0.1 -p $SERVICE_PORT -k $SERVICE_STATE -c fsync=off" start > /dev/null
          psql --host=127.0.0.1 --port="$SERVICE_PORT" --username=postgres --dbname=postgres \
            --quiet --set=ON_ERROR_STOP=1 --file=${initFile}
        '';
        stop = ''
          pg_ctl --pgdata="$SERVICE_STATE/data" --mode=fast --wait stop > /dev/null
        '';
      };
}
