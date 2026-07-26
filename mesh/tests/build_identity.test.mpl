from Packages.BuildIdentity import code_commit, mesh_commit

describe("compiled build identity") do
  test("exposes nonempty application and Mesh revisions") do
    assert(String.length(code_commit()) > 0)
    assert(String.length(mesh_commit()) > 0)
  end
end
