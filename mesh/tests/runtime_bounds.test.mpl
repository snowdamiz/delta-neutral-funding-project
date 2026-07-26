fn flood(channel :: Int, value :: Int, last :: Int) -> Int do
  if value > last do
    value - 1
  else
    let _sent = Channel.try_send(channel, value)
    channel |> flood(value + 1, last)
  end
end

describe("bounded runtime delivery") do
  test("coalesces replaceable snapshots under deterministic overload") do
    case Channel.bounded(8, :latest_only) do
      Err(error) -> assert(false)
      Ok(channel) -> do
        assert((channel |> flood(1, 10000)) == 10000)
        assert(Channel.depth(channel) == 1)
        assert(Channel.dropped(channel) == 9999)
        case Channel.recv(channel, 0) do
          Ok(value) -> assert(value == 10000)
          Err(error) -> assert(false)
        end
      end
    end
  end

  test("rejects critical work instead of growing past capacity") do
    case Channel.bounded(2, :reject_newest) do
      Err(error) -> assert(false)
      Ok(channel) -> do
        let _first = Channel.try_send(channel, 1)
        let _second = Channel.try_send(channel, 2)
        case Channel.try_send(channel, 3) do
          Ok(value) -> assert(false)
          Err(error) -> assert(error == "channel full")
        end
        assert(Channel.depth(channel) == 2)
        assert(Channel.dropped(channel) == 1)
      end
    end
  end
end
