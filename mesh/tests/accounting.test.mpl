from Packages.Accounting import DirectUnstakeProcess, DirectUnstakeState, advance_direct_unstake, complete_direct_unstake, realized_funding_usd, record_direct_unstake_funding, start_direct_unstake
from Packages.Finance import Lamports, RatePpm, TokenAtoms, UsdMicros

fn advance_to_withdrawable(requested :: DirectUnstakeProcess) -> DirectUnstakeProcess ! String do
  ((requested
    |> advance_direct_unstake(900, false)) ?
    |> advance_direct_unstake(900, false)) ?
    |> advance_direct_unstake(901, false)
end

describe("paper accounting") do
  test("settles realized funding from the held short with its signed venue rate") do
    case realized_funding_usd(
      Lamports { atoms : 2000000000 },
      UsdMicros { atoms : 150000000 },
      RatePpm { atoms : 250 }
    ) do
      Ok(received) -> assert(received.atoms == 75000)
      Err(error) -> assert(false)
    end

    case realized_funding_usd(
      Lamports { atoms : 2000000000 },
      UsdMicros { atoms : 150000000 },
      RatePpm { atoms : -100 }
    ) do
      Ok(paid) -> assert(paid.atoms == -30000)
      Err(error) -> assert(false)
    end
  end
end

describe("direct-unstake counterfactual") do
  test("keeps a separate cost-complete projection through the epoch wait") do
    case start_direct_unstake(
      TokenAtoms { atoms : 2000000000 },
      Lamports { atoms : 1250000000 },
      UsdMicros { atoms : 150000000 },
      Lamports { atoms : 2000000000 },
      RatePpm { atoms : 250 },
      900,
      RatePpm { atoms : 1000 },
      UsdMicros { atoms : 20000 },
      48,
      UsdMicros { atoms : 500000 },
      UsdMicros { atoms : 1000000 },
      UsdMicros { atoms : 250000 }
    ) do
      Ok(requested) -> do
        assert(requested.state == Requested)
        assert(requested.requested_epoch == 900)
        assert(requested.available_epoch == 901)
        assert(requested.projection.protocol_redemption_lamports.atoms == 2500000000)
        assert(requested.projection.withdrawal_fee_lamports.atoms == 2500000)
        assert(requested.projection.net_redemption_lamports.atoms == 2497500000)
        assert(requested.projection.cooldown_funding_usd_micros.atoms == 3600000)
        assert(requested.projection.net_usd_micros.atoms == 376455000)

        case requested
          |> record_direct_unstake_funding(UsdMicros { atoms : -75000 }) do
          Ok(accrued) -> do
            assert(accrued.projection.cooldown_funding_usd_micros.atoms == 3525000)
            assert(accrued.projection.net_usd_micros.atoms == 376380000)
          end
          Err(error) -> assert(false)
        end

        case requested |> advance_to_withdrawable do
          Ok(withdrawable) -> do
            assert(withdrawable.state == Withdrawable)
            case withdrawable |> advance_direct_unstake(901, false) do
              Ok(missed) -> do
                assert(missed.state == Withdrawable)
                case missed |> complete_direct_unstake(false) do
                  Ok(withdrawn) -> assert(withdrawn.state == Withdrawn)
                  Err(error) -> assert(false)
                end
              end
              Err(error) -> assert(false)
            end
          end
          Err(error) -> assert(false)
        end

        case requested |> advance_direct_unstake(900, true) do
          Ok(failed) -> assert(failed.state == Failed)
          Err(error) -> assert(false)
        end
      end
      Err(error) -> assert(false)
    end

    case start_direct_unstake(
      TokenAtoms { atoms : 2000000000 },
      Lamports { atoms : 1234567890 },
      UsdMicros { atoms : 150000000 },
      Lamports { atoms : 2467333332 },
      RatePpm { atoms : 0 },
      900,
      RatePpm { atoms : 1000 },
      UsdMicros { atoms : 0 },
      0,
      UsdMicros { atoms : 0 },
      UsdMicros { atoms : 0 },
      UsdMicros { atoms : 0 }
    ) do
      Ok(rounded) -> assert(rounded.projection.net_usd_micros.atoms == 369999997)
      Err(error) -> assert(false)
    end
  end
end
