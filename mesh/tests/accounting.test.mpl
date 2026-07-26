from Packages.Accounting import realized_funding_usd
from Packages.Finance import Lamports, RatePpm, UsdMicros

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
