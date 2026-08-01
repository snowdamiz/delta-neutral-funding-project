from Packages.Metrics import build_metric, escape_label_value

describe("Prometheus metrics") do
  test("escapes label values") do
    assert(escape_label_value("a\\b\"c\nd") == "a\\\\b\\\"c\\nd")
  end

  test("reports the current database schema") do
    assert(String.contains(build_metric("app", "mesh"), "schema_version=\"45\""))
  end
end
