from Api.Routes import handle_build, handle_capabilities, handle_event, handle_health, handle_metrics, handle_opportunities, handle_status

pub fn build_router() do
  HTTP.router()
    |> HTTP.on_get("/v1/health", handle_health)
    |> HTTP.on_get("/v1/build", handle_build)
    |> HTTP.on_get("/v1/capabilities", handle_capabilities)
    |> HTTP.on_get("/v1/status", handle_status)
    |> HTTP.on_get("/v1/opportunities", handle_opportunities)
    |> HTTP.on_get("/metrics", handle_metrics)
    |> HTTP.on_post("/v1/events", handle_event)
end

