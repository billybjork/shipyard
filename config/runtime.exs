import Config

# The push topic is Billy's alone and is the push's only access control
# (Shipyard.Notify). The tests never read it, so no test can push.
if config_env() != :test do
  topic = String.trim(System.get_env("NTFY_TOPIC", ""))
  config :shipyard, ntfy_topic: if(topic != "", do: topic)
end
