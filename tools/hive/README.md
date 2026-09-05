# Hive fixture checkout

The Hive gitlink uses the public upstream commit `c37a9a26873ea74a084d59f035d57cb1fe20a0eb`.
The previous local-only commit could not be fetched by CI. The ZEVM RPC smoke
already creates its own client registration from `zevm-client` templates.

`consensus-prague.patch` preserves the additional Prague fork fixture mapping
from that local commit. Apply it explicitly in a disposable Hive checkout when
running the consensus simulator. It is not needed by the RPC compatibility
suite and is not a claim of Prague consensus qualification.
