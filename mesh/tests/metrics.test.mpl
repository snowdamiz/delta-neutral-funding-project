from Packages.Metrics import escape_label_value

describe("Prometheus metrics") do
  test("escapes label values") do
    assert(escape_label_value("a\\b\"c\nd") == "a\\\\b\\\"c\\nd")
  end
end
