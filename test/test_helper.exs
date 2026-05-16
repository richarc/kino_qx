# Excluded by default — these tests hit real third-party services and
# require credentials in environment variables. Run locally before
# every Hex publish:
#
#   mix test --include portal_live   # against test.qxquantum.com
#   mix test --include ibm_live      # against a real IBM Quantum account
#   mix test --include ibm_live --include ibm_submit
#                                    # dispatches a REAL job (IBM bills
#                                    # per shot); also needs
#                                    # IBM_QUANTUM_SUBMIT=1
#
ExUnit.start(exclude: [:ibm_live, :portal_live, :ibm_submit])
