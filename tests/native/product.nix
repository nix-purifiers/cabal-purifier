# SPDX-License-Identifier: MIT
{
  selector = "purifier-foreign-proof:flib:answer";
  abi = "c";
  exports = [
    "purifier_answer"
    "purifier_init"
    "purifier_term"
  ];
  runtime = {
    kind = "ghc";
    lifecycle = "process-once";
    threading = "single-foreign-thread";
    init = "purifier_init";
    term = "purifier_term";
  };
}
