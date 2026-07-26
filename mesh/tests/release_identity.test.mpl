from Packages.Storage import release_identity_matches

describe("paper soak release identity") do
  test("accepts only the pinned application, Mesh, and config identity") do
    assert(release_identity_matches(
      "app-a",
      "mesh-a",
      "config-a",
      "app-a",
      "mesh-a",
      "config-a"
    ))
    assert(release_identity_matches(
      "app-a",
      "mesh-a",
      "config-a",
      "app-b",
      "mesh-a",
      "config-a"
    ) == false)
    assert(release_identity_matches(
      "app-a",
      "mesh-a",
      "config-a",
      "app-a",
      "mesh-b",
      "config-a"
    ) == false)
    assert(release_identity_matches(
      "app-a",
      "mesh-a",
      "config-a",
      "app-a",
      "mesh-a",
      "config-b"
    ) == false)
  end
end
