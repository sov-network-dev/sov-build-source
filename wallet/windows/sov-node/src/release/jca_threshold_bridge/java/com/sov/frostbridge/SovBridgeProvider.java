package com.sov.frostbridge;

import java.security.Provider;

public class SovBridgeProvider extends Provider {
    public SovBridgeProvider() {
        super("SovBridge", "1.0", "SOV threshold-ceremony JCA bridge (PoC) — gap-1 evidence");
        put("KeyStore.SOVBRIDGE", "com.sov.frostbridge.SovKeyStoreSpi");
        put("Signature.SHA384withRSA", "com.sov.frostbridge.SovRsaSignatureSha384");
        put("Signature.SHA512withRSA", "com.sov.frostbridge.SovRsaSignatureSha512");
    }
}
