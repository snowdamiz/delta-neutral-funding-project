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
    case Channel.bounded_bytes(8, 64, :latest_only) do
      Err(error) -> assert(false)
      Ok(channel) -> do
        assert((channel |> flood(1, 10000)) == 10000)
        assert(Channel.depth(channel) == 1)
        assert(Channel.byte_depth(channel) == 8)
        assert(Channel.dropped(channel) == 9999)
        case Channel.recv(channel, 0) do
          Ok(value) -> assert(value == 10000)
          Err(error) -> assert(false)
        end
      end
    end
  end

  test("rejects critical work instead of growing past capacity") do
    case Channel.bounded_bytes(2, 16, :reject_newest) do
      Err(error) -> assert(false)
      Ok(channel) -> do
        let _ = channel |> Channel.try_send(1)
        let _ = channel |> Channel.try_send(2)
        case channel |> Channel.try_send(3) do
          Ok(value) -> assert(false)
          Err(error) -> assert(error == "channel full")
        end
        assert(Channel.depth(channel) == 2)
        assert(Channel.byte_depth(channel) == 16)
        assert(Channel.dropped(channel) == 1)
      end
    end
  end
end
