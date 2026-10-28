import Config

# `mix run` starts the worker; the tests and the reporting tasks
# (`mix shipyard.list`, `mix shipyard.wait`) start none.
config :shipyard, worker: config_env() != :test

# Where the worker reports its status (Shipyard.Status): its controlling
# terminal, a Rex tab when `bin/shipyard start` opens one. The tests report
# nowhere.
config :shipyard, status: if(config_env() != :test, do: "/dev/tty")
