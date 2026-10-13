import Config

# `mix run` starts the worker; the tests and the reporting tasks
# (`mix shipyard.list`, `mix shipyard.wait`) start none.
config :shipyard, worker: config_env() != :test
