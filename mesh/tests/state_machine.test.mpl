from Packages.StateMachine import PortfolioSignal, PortfolioState, transition

describe("portfolio state machine") do
  test("opens in order, exits perp first, and fails closed") do
    case transition(Idle, OpportunityFound) do
      Ok(candidate) -> do
        assert(candidate == Candidate)
        case transition(candidate, OpenApproved) do
          Ok(opening_spot) -> assert(opening_spot == OpeningSpot)
          Err(error) -> assert(false)
        end
      end
      Err(error) -> assert(false)
    end

    case transition(OpeningSpot, SpotFilled) do
      Ok(opening_perp) -> do
        assert(opening_perp == OpeningPerp)
        case transition(opening_perp, PerpFilled) do
          Ok(hedged) -> do
            assert(hedged == Hedged)
            case transition(hedged, ExitRequired) do
              Ok(exiting) -> assert(exiting == ExitingPerp)
              Err(error) -> assert(false)
            end
          end
          Err(error) -> assert(false)
        end
      end
      Err(error) -> assert(false)
    end

    case transition(OpeningPerp, Fault) do
      Ok(emergency) -> assert(emergency == EmergencyFlatten)
      Err(error) -> assert(false)
    end

    case transition(Idle, PerpFilled) do
      Ok(next) -> assert(false)
      Err(error) -> assert(error == "invalid portfolio transition")
    end
  end
end
