fn emit(level :: String, event :: String, fields :: String) do
  let timestamp_ms = DateTime.utc_now() |> DateTime.to_unix_ms
  println("{\"timestampMs\":\"${timestamp_ms}\",\"level\":\"${level}\",\"event\":\"${event}\",\"fields\":${fields}}")
end

pub fn info(event :: String, fields :: String) do
  emit("info", event, fields)
end

pub fn warn(event :: String, fields :: String) do
  emit("warn", event, fields)
end

pub fn error(event :: String, fields :: String) do
  emit("error", event, fields)
end
