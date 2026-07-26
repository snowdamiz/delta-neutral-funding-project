pub type PortfolioState do
  Bootstrapping
  Reconciling
  Idle
  Candidate
  OpeningSpot
  OpeningPerp
  Hedged
  Rebalancing
  ExitingPerp
  ExitingSpot
  EmergencyFlatten
  Paused
end deriving(Eq, Display, Json)

pub type PortfolioSignal do
  ReconciledFlat
  OpportunityFound
  OpportunityLost
  OpenApproved
  SpotFilled
  PerpFilled
  DeltaBreached
  Rebalanced
  ExitRequired
  PerpClosed
  SpotClosed
  Fault
  PauseRequested
  ResumeRequested
end deriving(Eq, Display, Json)

fn invalid() -> PortfolioState ! String do
  Err("invalid portfolio transition")
end

pub fn transition(state :: PortfolioState, signal :: PortfolioSignal) -> PortfolioState ! String do
  case state do
    Bootstrapping -> case signal do
      ReconciledFlat -> Ok(Idle)
      Fault -> Ok(Paused)
      _ -> invalid()
    end
    Reconciling -> case signal do
      ReconciledFlat -> Ok(Idle)
      Fault -> Ok(Paused)
      _ -> invalid()
    end
    Idle -> case signal do
      OpportunityFound -> Ok(Candidate)
      PauseRequested -> Ok(Paused)
      Fault -> Ok(Paused)
      _ -> invalid()
    end
    Candidate -> case signal do
      OpportunityLost -> Ok(Idle)
      OpenApproved -> Ok(OpeningSpot)
      PauseRequested -> Ok(Paused)
      Fault -> Ok(Paused)
      _ -> invalid()
    end
    OpeningSpot -> case signal do
      SpotFilled -> Ok(OpeningPerp)
      Fault -> Ok(EmergencyFlatten)
      _ -> invalid()
    end
    OpeningPerp -> case signal do
      PerpFilled -> Ok(Hedged)
      Fault -> Ok(EmergencyFlatten)
      _ -> invalid()
    end
    Hedged -> case signal do
      DeltaBreached -> Ok(Rebalancing)
      ExitRequired -> Ok(ExitingPerp)
      PauseRequested -> Ok(Paused)
      Fault -> Ok(EmergencyFlatten)
      _ -> invalid()
    end
    Rebalancing -> case signal do
      Rebalanced -> Ok(Hedged)
      Fault -> Ok(EmergencyFlatten)
      _ -> invalid()
    end
    ExitingPerp -> case signal do
      PerpClosed -> Ok(ExitingSpot)
      Fault -> Ok(EmergencyFlatten)
      _ -> invalid()
    end
    ExitingSpot -> case signal do
      SpotClosed -> Ok(Idle)
      Fault -> Ok(EmergencyFlatten)
      _ -> invalid()
    end
    EmergencyFlatten -> case signal do
      ReconciledFlat -> Ok(Reconciling)
      _ -> invalid()
    end
    Paused -> case signal do
      ResumeRequested -> Ok(Reconciling)
      _ -> invalid()
    end
  end
end

pub fn state_name(state :: PortfolioState) -> String do
  case state do
    Bootstrapping -> "bootstrapping"
    Reconciling -> "reconciling"
    Idle -> "idle"
    Candidate -> "candidate"
    OpeningSpot -> "opening_spot"
    OpeningPerp -> "opening_perp"
    Hedged -> "hedged"
    Rebalancing -> "rebalancing"
    ExitingPerp -> "exiting_perp"
    ExitingSpot -> "exiting_spot"
    EmergencyFlatten -> "emergency_flatten"
    Paused -> "paused"
  end
end
