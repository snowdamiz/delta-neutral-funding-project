from Packages.Replay import run_replay

fn valid_replay_args(args :: List<String>) -> Bool do
  List.length(args) == 6 && List.get(args, 1) == "replay" && List.get(args, 2) == "--bundle" && List.get(args, 4) == "--config"
end

pub fn run_replay_command(
  args :: List<String>,
  mesh_commit :: String
) -> String ! String do
  if valid_replay_args(args) == false do
    return Err("usage: funding-collector replay --bundle <path> --config <path>")
  end
  Ok(Json.encode(
    (((List.get(args, 3) |> File.read) ? |2> run_replay(
      (List.get(args, 5) |> File.read) ?,
      mesh_commit
    ))) ?
  ))
end
