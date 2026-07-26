from Runtime.Registry import accepted_events, rejected_events

pub fn render() -> String do
  "# HELP funding_collector_events_total Protocol events handled by result.\n# TYPE funding_collector_events_total counter\nfunding_collector_events_total{result=\"accepted\"} ${accepted_events()}\nfunding_collector_events_total{result=\"rejected\"} ${rejected_events()}\n# HELP funding_collector_build_info Pinned build information.\n# TYPE funding_collector_build_info gauge\nfunding_collector_build_info{mode=\"paper\",schema_version=\"1\"} 1\n"
end

