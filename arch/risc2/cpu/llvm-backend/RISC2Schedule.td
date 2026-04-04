// RISC2 Scheduling Model (minimal - no latency modelling for now)

def RISC2SchedModel : SchedMachineModel {
  let IssueWidth = 1;
  let MicroOpBufferSize = 0;  // in-order
  let LoadLatency = 3;
  let MispredictPenalty = 4;
  let CompleteModel = 0;
}
